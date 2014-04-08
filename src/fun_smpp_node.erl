-module(fun_smpp_node).

-behaviour(gen_server).
-behaviour(gen_mc_session).

%% client exports
-export([start_link/1,
         stop/1,
         unbind/1,
         deliver_sm/2]).

%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

%% gen_mc_session exports
-export([handle_accept/2,
         handle_bind/2,
         handle_closed/2,
         handle_enquire_link/2,
         handle_operation/2,
         handle_resp/3,
         handle_unbind/2]).

-include("otp_records.hrl").
-include("helpers.hrl").
-include_lib("oserl/include/oserl.hrl").
-include_lib("alley_dto/include/FunnelAsn.hrl").

-ifdef(POWER_ALLEY).
-include_lib("billy_client/include/billy_client.hrl").
-endif.

-ifdef(TEST).
-compile(export_all).
-endif.

-define(CLOSE_BATCHES_INTERVAL, 100).

-record(st, {mc_session       :: pid(),
             smpp_log_mgr     :: pid(),
             logger           :: atom(),
             uuid             :: string(),
             customer_uuid    :: string(),
             priority         :: non_neg_integer(),
             receipts_allowed :: boolean(),
             no_retry         :: boolean(),
             default_provider_id :: string(),
             default_validity :: string(),
             max_validity     :: pos_integer(),
             pay_type         :: prepaid | postpaid,
             batch_tab        :: ets:tid(),
             parts_tab        :: ets:tid(),
             coverage_tab     :: ets:tid(),
             req_tab          :: ets:tid(),
             deliver_queue    :: queue(),
             addr             :: string(),
             is_bound = false :: boolean(),
             connected_at     :: {{_,_,_},{_,_,_}},
             customer_id      :: string(),
             user_id          :: string(),
             allowed_sources  :: [string()],
             default_source   :: {string(), integer(), integer()},
             batch_runner     :: pid(),
             providers        :: ets:tid()}).

-define(gv(K, P), proplists:get_value(K, P)).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec start_link(port()) -> {'ok', pid()} | 'ignore' | {'error', any()}.
start_link(LSock) ->
    gen_server:start_link(?MODULE, LSock, []).

-spec stop(pid()) -> no_return().
stop(Node) ->
    gen_server:cast(Node, stop).

-spec unbind(pid()) -> no_return().
unbind(Node) ->
    gen_server:cast(Node, unbind).

-spec deliver_sm(pid(), list()) -> reference().
deliver_sm(Node, Params) ->
    gen_server:call(Node, {deliver_sm, Params}, infinity).

%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------

init(LSock) ->
    process_flag(trap_exit, true),
    lager:debug("node: initializing"),
    {ok, SMPPLogMgr} = smpp_log_mgr:start_link(),
    pmm_smpp_logger_h:sup_add_to_manager(SMPPLogMgr),
    Timers = ?TIMERS(
        funnel_conf:get(session_init_time),
        funnel_conf:get(enquire_link_time),
        funnel_conf:get(inactivity_time),
        funnel_conf:get(response_time)
    ),
    {ok, Session} = gen_mc_session:start_link(?MODULE, [
        {log, SMPPLogMgr}, {lsock, LSock}, {timers, Timers}
    ]),
    {ok, #st{
        smpp_log_mgr = SMPPLogMgr,
        mc_session   = Session,
        batch_tab    = ets:new(batch_tab, []),
        parts_tab    = ets:new(parts_tab, []),
        coverage_tab = ets:new(coverage_tab, []),
        req_tab      = ets:new(req_tab, []),
        deliver_queue = queue:new(),
        providers    = ets:new(providers, [{keypos, #'Provider'.id}])
    }}.

terminate(Reason, St) ->
    Rsn =
        case Reason of
            normal  -> normal;
            closed  -> closed;
            unbound -> unbound;
            _       -> other
        end,
    case St#st.is_bound of
        true ->
            {Received, Sent} = fun_throughput:totals(St#st.uuid),
            fun_smpp_server:node_terminated(
                St#st.uuid, Received, Sent, fun_errors:lookup(St#st.uuid), Rsn);
        false ->
            ignore
    end,
    catch(gen_mc_session:stop(St#st.mc_session)),
    catch(pmm_smpp_logger_h:deactivate(St#st.smpp_log_mgr)),
    catch(smpp_log_mgr:stop(St#st.smpp_log_mgr)),
    fun_batch_runner:stop(St#st.batch_runner),
    [ fun_tracker:close_batch(St#st.customer_id, St#st.user_id, BatchId) ||
        {_, BatchId, _, _} <- ets:tab2list(St#st.batch_tab) ],
    ets:delete(St#st.batch_tab),
    ets:delete(St#st.coverage_tab),
    lager:debug("node: terminated (~p)", [Reason]).

handle_call({handle_accept, Addr}, _From, St) ->
    case fun_smpp_server:handle_accept(self(), Addr) of
        {true, UUID, ConnectedAt} ->
            fun_errors:register_connection(UUID, self()),
            fun_throughput:register_connection(UUID, self()),
            {reply, ok, St#st{uuid = UUID, addr = Addr, connected_at = ConnectedAt}};
        false ->
            {reply, {error, forbidden}, St}
    end;

handle_call({handle_bind, Type, Version, SystemType, SystemId, Password},
            _From, St) ->
    {CustomerId, UserId} = case string:tokens(SystemId, ":") of
                               [C, U] -> {C, U};
                               _      -> {SystemType, SystemId}
                           end,
    try fun_smpp_server:handle_bind(self(), {St#st.addr, Type,
                                             CustomerId, UserId, Password}) of
        {ok, Params, Customer} ->
            lager:debug(
                "node: bound (addr: ~s, customer: ~s, user: ~s, password: ~s, type: ~s)",
                [St#st.addr, CustomerId, UserId, Password, Type]
            ),
            fun_coverage:fill_coverage_tab(?gv(networks, Customer), St#st.coverage_tab),
            fun_tracker:register_user(CustomerId, UserId),
            lists:foreach(fun(Prov) -> ets:insert(St#st.providers, Prov) end,
                          ?gv(providers, Customer)),
            Runner =
                if
                    Type =:= receiver orelse Type =:= transceiver ->
                        {ok, Pid} = fun_batch_runner:start_link([
                            {connection_id, St#st.uuid},
                            {version, Version}, {node, self()}
                        ]),
                        Pid;
                    true ->
                        undefined
                end,
            PduLogName = pdu_log_name(Type, CustomerId, UserId, St#st.uuid),
            case funnel_conf:get(log_smpp_pdus) of
                true ->
                    LogParams = [{base_dir, funnel_conf:get(smpp_pdu_log_dir)},
                                 {base_file_name, PduLogName},
                                 {max_size, funnel_conf:get(file_log_size)}],
                    pmm_smpp_logger_h:activate(St#st.smpp_log_mgr, LogParams);
                false ->
                    ok
            end,
            erlang:start_timer(?CLOSE_BATCHES_INTERVAL, self(), close_batches),
			fun_smpp_server:notify_backend_connection_up(	St#st.uuid,
															CustomerId,
															UserId,
															Type,
															St#st.connected_at),
            {reply, {ok, Params},
             St#st{is_bound  = true,
                   customer_id = CustomerId,
                   customer_uuid = ?gv(uuid, Customer),
                   priority = ?gv(priority, Customer),
                   user_id = UserId,
                   allowed_sources = ?gv(allowed_sources, Customer),
                   default_source = ?gv(default_source, Customer),
                   batch_runner = Runner,
                   receipts_allowed = ?gv(receipts_allowed, Customer),
                   no_retry = ?gv(no_retry, Customer),
                   default_provider_id = ?gv(default_provider_id, Customer),
                   default_validity = ?gv(default_validity, Customer),
                   max_validity = ?gv(max_validity, Customer),
                   pay_type = ?gv(pay_type, Customer)
              }};
        {error, Error} ->
            fun_errors:record(St#st.uuid, Error),
            {reply, {error, Error}, St}
    catch
        _:{timeout, _} ->
            lager:error(
                "node: bind request timed out "
                "(addr: ~s, customer: ~s, user: ~s, password: ~s, type: ~s)",
                [St#st.addr, CustomerId, UserId, Password, Type]
            ),
            fun_errors:record(St#st.uuid, ?ESME_RBINDFAIL),
            {reply, {error, ?ESME_RBINDFAIL}, St}
    end;

handle_call({deliver_sm, Params}, {Pid, _Tag} = From, St) ->
    WindowSize = funnel_conf:get(deliver_sm_window_size),
    case ets:info(St#st.req_tab, size) < WindowSize of
        true ->
            Ref = gen_mc_session:deliver_sm(St#st.mc_session, Params),
            ets:insert(St#st.req_tab, {Ref, deliver_sm, Pid}),
            fun_throughput:out(St#st.uuid),
            {reply, Ref, St};
        false ->
            {noreply,
             St#st{deliver_queue = queue:in({Params, From}, St#st.deliver_queue)}}
    end.

deliver_from_queue(St) ->
    WindowSize = funnel_conf:get(deliver_sm_window_size),
    case ets:info(St#st.req_tab, size) < WindowSize of
        true ->
            case queue:out(St#st.deliver_queue) of
                {empty, _Q1} ->
                    St;
                {{value, {Params, {Pid, _Tag} = From}}, Q2} ->
                    Ref = gen_mc_session:deliver_sm(St#st.mc_session, Params),
                    gen_server:reply(From, Ref),
                    ets:insert(St#st.req_tab, {Ref, deliver_sm, Pid}),
                    fun_throughput:out(St#st.uuid),
                    deliver_from_queue(St#st{deliver_queue = Q2})
            end;
        false ->
            St
    end.

handle_cast({handle_operation, submit_sm, SeqNum, Params}, St) ->
    lager:debug("node: got submit_sm request (~p)", [Params]),
    case handle_submit(SeqNum, Params, St) of
        ok ->
            {noreply, St};
        {error, Error, Details} ->
            gen_mc_session:reply(St#st.mc_session, {SeqNum, {error, Error}}),
            lager:error("node: ~s", [Details]),
            fun_errors:record(St#st.uuid, Error),
            {noreply, St}
    end;

handle_cast({handle_operation, Cmd, SeqNum, _Params}, St) ->
    lager:warning("node: got unsupported request (~s)", [Cmd]),
    fun_errors:record(St#st.uuid, ?ESME_RPROHIBITED),
    Reply = {error, ?ESME_RPROHIBITED},
    gen_mc_session:reply(St#st.mc_session, {SeqNum, Reply}),
    {noreply, St};

handle_cast({handle_resp, Resp, Ref}, St) ->
    [{_, Cmd, Pid}] = ets:lookup(St#st.req_tab, Ref),
    ets:delete(St#st.req_tab, Ref),
    case Cmd of
        unbind ->
            {stop, normal, St};
        deliver_sm ->
            Reply = case Resp of
                        {ok, {_CmdId, _Status, _SeqNum, Body}} ->
                            {ok, Body};
                        {error, {command_status, Status}} ->
                            fun_errors:record(St#st.uuid, Status),
                            {error, Status};
                        {error, Status} ->
                            fun_errors:record(St#st.uuid, Status),
                            {error, Status}
                    end,
            reply(Pid, Reply),
            {noreply, deliver_from_queue(St)}
    end;

handle_cast(stop, St) ->
    lager:debug("node: stopping"),
    {stop, normal, St};

handle_cast(unbind, St) ->
    lager:debug("node: stopping"),
    if
        is_pid(St#st.batch_runner) ->
            fun_batch_runner:stop(St#st.batch_runner),
            % node will stop after batch runner exit and unbind.
            {noreply, St};
        true ->
            Ref = gen_mc_session:unbind(St#st.mc_session),
            ets:insert(St#st.req_tab, {Ref, unbind, self}),
            % node will stop after receiving unbind_resp.
            {noreply, St}
    end;

handle_cast({handle_closed, closed}, St) ->
    {stop, closed, St};

handle_cast({handle_closed, Reason}, St) ->
    {stop, {closed, Reason}, St};

handle_cast(handle_unbind, St) ->
    {stop, unbound, St}.

handle_info(#timeout{msg = close_batches}, St) ->
    erlang:start_timer(?CLOSE_BATCHES_INTERVAL, self(), close_batches),
    TS = fun_time:milliseconds(),
    % cancel concat process for expired parts
    ConcatMaxWait = funnel_conf:get(concat_max_wait),
    {Keys, BatchIds} =
        ets:foldl(fun({Key, FirstInsert, SegsIds}, {Keys, Ids} = Acc) ->
                      if
                          TS >= FirstInsert + ConcatMaxWait ->
                              {[Key|Keys], [ Id || {_SegNum, Id} <- SegsIds ] ++ Ids};
                          true ->
                              Acc
                      end
                  end, {[], []}, St#st.parts_tab),
    lists:foreach(fun(Key) -> ets:delete(St#st.parts_tab, Key) end, Keys),
    lists:foreach(fun({CommonBin, DestBin}) ->
                      Params = unparse_common(CommonBin),
                      {MsgId, RefNum, Addr} = unparse_dest(DestBin),
                      reinsert(Params, MsgId, RefNum,
                               {Addr, ?TON_INTERNATIONAL, ?NPI_ISDN}, St)
                  end, fun_tracker:get_partial_batches(BatchIds)),
    fun_tracker:delete_batches(St#st.customer_id, St#st.user_id, BatchIds),
    % close batches
    BatchMaxWait = funnel_conf:get(batch_max_wait),
    ToClose = ets:foldl(
        fun({FP, BatchId, LastInsert, _Size}, Acc) ->
                if
                    TS >= LastInsert + BatchMaxWait ->
                        [{FP, BatchId}|Acc];
                    true ->
                        Acc
                end
        end, [], St#st.batch_tab
    ),
    [ ets:delete(St#st.batch_tab, FP) || {FP, _BatchId} <- ToClose ],
    [ fun_tracker:close_batch(St#st.customer_id, St#st.user_id, BatchId)
        || {_FP, BatchId} <- ToClose ],
    {noreply, St};

handle_info(#'EXIT'{pid = Pid, reason = Reason}, #st{mc_session = Pid} = St) ->
    {stop, {session_exit, Reason}, St};

handle_info(#'EXIT'{pid = Pid, reason = normal}, #st{batch_runner = Pid} = St) ->
    Ref = gen_mc_session:unbind(St#st.mc_session),
    ets:insert(St#st.req_tab, {Ref, unbind, self}),
    % node will stop after receiving unbind_resp.
    {noreply, St};

handle_info(#'EXIT'{pid = Pid, reason = Reason}, #st{batch_runner = Pid} = St) ->
    {stop, {batch_runner_exit, Reason}, St};

handle_info(#'EXIT'{pid = Pid, reason = Reason}, #st{smpp_log_mgr = Pid} = St) ->
    {stop, {logger_exit, Reason}, St};

handle_info({gen_event_EXIT, _Handler, Reason}, St) ->
    {stop, {logger_exit, Reason}, St}.

%% to avoid compiler warnings.
code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% -------------------------------------------------------------------------
%% gen_mc_session callback functions
%% -------------------------------------------------------------------------

%% Called when a new connection from Addr arrives to a listening session.
%% If 'ok' is returned, then the connection is accepted and the session
%% moves to open state.
handle_accept(Node, Addr) ->
    gen_server:call(Node, {handle_accept, inet_parse:ntoa(Addr)}).

%% Called upon receiving a bind_* request.
%% If {ok, Params} is returned, then session goes to the bound state.
%% If {error, Reason} is returned, the session remains in the open state
%% until session_init_timer or inactivity_timer fires or a successful bind
%% request happens.
handle_bind(Node, {Cmd, {_, _, _, Params}}) ->
    Type = case Cmd of
               bind_transmitter -> transmitter;
               bind_receiver    -> receiver;
               bind_transceiver -> transceiver
           end,
    gen_server:call(Node,
                    {handle_bind, Type, ?gv(interface_version, Params),
                     ?gv(system_type, Params),
                     ?gv(system_id, Params),
                     ?gv(password, Params)},
                    infinity).

%% Deliver an async repsonse to the request with Ref.
handle_resp(Node, Resp, Ref) ->
    ok = gen_server:cast(Node, {handle_resp, Resp, Ref}).

%% Handle ESME-issued operation.
handle_operation(Node, {Cmd, {_, _, SeqNum, Params}}) ->
    gen_server:cast(Node, {handle_operation, Cmd, SeqNum, Params}),
    noreply.

%% Forward enquire_link operations (from the peer MC) to the callback module.
handle_enquire_link(_Node, _Pdu) ->
    ok.

%% Handle ESME-issued unbind.
handle_unbind(Node, _Pdu) ->
    ok = gen_server:cast(Node, handle_unbind).

%% Notify Node of the Reason before stopping the session.
handle_closed(Node, Reason) ->
    ok = gen_server:cast(Node, {handle_closed, Reason}).

%% -------------------------------------------------------------------------
%% Handling submit
%% -------------------------------------------------------------------------

handle_submit(SeqNum, Params, St) ->
    step(throttle, {SeqNum, Params}, St).

step(throttle, {SeqNum, Params}, St) ->
    case fun_throttle:is_allowed(St#st.customer_id) of
        true ->
            step(verify_coverage, {SeqNum, Params}, St);
        false ->
            {error, ?ESME_RTHROTTLED, "throttled"}
    end;

step(verify_coverage, {SeqNum, Params}, St) ->
    case fun_coverage:which_network(dest_addr(Params), St#st.coverage_tab) of
        {NetworkId, DestDigits, NetworkProvderId} ->
            Params1 =
                ?KEYREPLACE3(destination_addr, DestDigits,
                    ?KEYREPLACE3(dest_addr_ton, ?TON_INTERNATIONAL,
                        ?KEYREPLACE3(dest_addr_npi, ?NPI_ISDN, Params))),
            Params2 = case St#st.default_provider_id of
                          undefined -> [{provider_id, NetworkProvderId}|Params1];
                          ID        -> [{provider_id, ID}|Params1]
                      end,
            step(tlv_params, {SeqNum, [{network_id, NetworkId}|Params2]}, St);
        undefined ->
            {error, ?ESME_RINVDSTADR, "invalid destination_addr"}
    end;

step(tlv_params, {SeqNum, Params}, St) ->
    try to_tlv_if_udh(Params) of
        TLVd ->
            step(validate_tlv, {SeqNum, TLVd}, St)
    catch
        _:_ ->
            {error, ?ESME_RINVESMCLASS, "bad udh"}
    end;

step(validate_tlv, {SeqNum, Params}, St) ->
    HasRefNum = ?gv(sar_msg_ref_num, Params) =/= undefined,
    HasTotalSegments = ?gv(sar_total_segments, Params) =/= undefined,
    HasSegmentSeqnum = ?gv(sar_segment_seqnum, Params) =/= undefined,
    All = HasRefNum andalso HasTotalSegments andalso HasSegmentSeqnum,
    Nothing = not (HasRefNum orelse HasTotalSegments orelse HasSegmentSeqnum),
    case All or Nothing of
        true ->
            step(ensure_source, {SeqNum, Params}, St);
        false ->
            {error, ?ESME_RMISSINGTLV, "one or more sar tlv missing"}
    end;

step(ensure_source, {SeqNum, Params}, St) ->
    case lists:keyfind(source_addr, 1, Params) of
        {source_addr, ""} ->
            % empty source_addr -> try replacing with default one.
            case St#st.default_source of
                {A, T, N} ->
                    % use the default one.
                    Replaced =
                        ?KEYREPLACE3(source_addr, A,
                            ?KEYREPLACE3(source_addr_ton, T,
                                ?KEYREPLACE3(source_addr_npi, N, Params)
                            )
                        ),
                    step(validate_source_ton_npi, {SeqNum, Replaced}, St);
                undefined ->
                    % no default one set -> return error.
                    {error, ?ESME_RINVSRCADR, "not allowed source_addr"}
            end;
        {source_addr, Addr} ->
            case lists:member(string:to_lower(Addr), St#st.allowed_sources) of
                true ->
                    step(validate_source_ton_npi, {SeqNum, Params}, St);
                false ->
                    {error, ?ESME_RINVSRCADR, "not allowed source_addr"}
            end
    end;

step(validate_source_ton_npi, {SeqNum, Params}, St) ->
    Addr = ?gv(source_addr, Params),
    Ton0 = ?gv(source_addr_ton, Params),
    Npi0 = ?gv(source_addr_npi, Params),
    AllDigits = lists:all(fun(D) -> D =< $9 andalso D >= $0 end, Addr),
    {Ton, Npi} = case {Ton0, AllDigits, length(Addr)} of
                     {?TON_ALPHANUMERIC, true, Len} when Len < 7 ->
                         {?TON_ABBREVIATED, ?NPI_UNKNOWN};
                     {?TON_ALPHANUMERIC, true, Len} when Len > 6 ->
                         {?TON_INTERNATIONAL, ?NPI_ISDN};
                     _ ->
                         {Ton0, Npi0}
                 end,
    DoReject = funnel_conf:get(reject_source_ton_npi),
    DoCorrect = funnel_conf:get(correct_source_ton_npi),
    if
        Ton0 =/= Ton andalso DoReject ->
            {error, ?ESME_RINVSRCTON, "invalid source_addr_ton"};
        Npi0 =/= Npi andalso DoReject ->
            {error, ?ESME_RINVSRCNPI, "invalid source_addr_npi"};
        (Ton0 =/= Ton orelse Npi0 =/= Npi) andalso DoCorrect ->
            Corrected = ?KEYREPLACE3(source_addr_ton, Ton,
                                     ?KEYREPLACE3(source_addr_npi, Npi, Params)),
            step(ensure_message, {SeqNum, Corrected}, St);
        true ->
            step(ensure_message, {SeqNum, Params}, St)
    end;

step(ensure_message, {SeqNum, Params}, St) ->
    case ?KEYFIND2(short_message, Params) of
        "" ->
            {error, ?ESME_RSUBMITFAIL, "empty short_message"};
        _ ->
            step(verify_message_length, {SeqNum, Params}, St)
    end;

step(verify_message_length, {SeqNum, Params}, St) ->
    IsSegment = ?gv(sar_msg_ref_num, Params) =/= undefined,
    Max = case ?gv(data_coding, Params) of
              DC when DC =:= 0; DC =:= 1; DC =:= 240; DC =:= 16 ->
                  if
                      IsSegment -> 153;
                      true      -> 160
                  end;
              _ ->
                  if
                      IsSegment -> 134;
                      true      -> 140
                  end
          end,
    case length(?gv(short_message, Params)) =< Max of
        true ->
            step(verify_registered_delivery, {SeqNum, Params}, St);
        false ->
            {error, ?ESME_RINVMSGLEN, "short_message too long"}
    end;

step(verify_registered_delivery, {SeqNum, Params}, St) ->
    RD = ?gv(registered_delivery, Params),
    [P] = ets:lookup(St#st.providers, ?gv(provider_id, Params)),
    case (RD =/= 0) andalso not (St#st.receipts_allowed andalso P#'Provider'.receiptsSupported) of
        true ->
            {error, ?ESME_RINVREGDLVFLG, "receipts not allowed"};
        false ->
            step(validate_validity_period, {SeqNum, Params}, St)
    end;

step(validate_validity_period, {SeqNum, Params}, St) ->
    case ?gv(validity_period, Params) of
        "" ->
            Params1 = ?KEYREPLACE3(validity_period, St#st.default_validity, Params),
            step(billy_reserve_or_accept, {SeqNum, Params1}, St);
        VP ->
            Delta = time_delta(VP),
            DoCutoff = funnel_conf:get(cutoff_validity_period),
            if
                Delta < 0 ->
                    {error, ?ESME_RINVEXPIRY, "expired validity_period"};
                Delta > St#st.max_validity andalso DoCutoff ->
                    NewVP = fmt_validity(St#st.max_validity),
                    lager:warn(
                        "node: validity period cut off "
                        "(customer: ~s, user: ~s, orig vp: ~s, new vp: ~s)",
                        [St#st.customer_id, St#st.user_id, VP, NewVP]
                    ),
                    Cutoff = ?KEYREPLACE3(validity_period, NewVP, Params),
                    step(billy_reserve_or_accept, {SeqNum, Cutoff}, St);
                Delta > St#st.max_validity ->
                    {error, ?ESME_RINVEXPIRY, "validity_period too long"};
                true ->
                    step(billy_reserve_or_accept, {SeqNum, Params}, St)
            end
    end;

step(billy_reserve_or_accept, {SeqNum, Params}, St) ->
    case St#st.pay_type of
        postpaid ->
            lager:debug("node: send without billing"),
            step(accept, {SeqNum, Params}, St);
        prepaid ->
            lager:debug("node: send with billing"),
            step(billy_reserve, {SeqNum, Params}, St)
    end;

step(billy_reserve, {SeqNum, Params}, St) ->
    billy_reserve({SeqNum, Params}, St);

step(accept, {SeqNum, Params}, St) ->
    case ?gv(sar_msg_ref_num, Params) of
        undefined ->
            step(take_fingerprints, {SeqNum, Params}, St);
        _ ->
            step(concat_parts, {SeqNum, Params}, St)
    end;

step(concat_parts, {SeqNum, Params}, St) ->
    case open_batch(Params, St) of
        {error, bad_message} ->
            {error, ?ESME_RINVDCS, "bad data coding"};
        BatchId ->
            TS = fun_time:milliseconds(),
            MsgId = next_message_id(St),
            fun_tracker:add_dest(BatchId, MsgId, ?gv(sar_msg_ref_num, Params),
                                 dest_addr(Params)),
            Key = part_key(Params),
            SegNum = ?gv(sar_segment_seqnum, Params),
            case ets:lookup(St#st.parts_tab, Key) of
                [] ->
                    ets:insert(St#st.parts_tab, {Key, TS, [{SegNum, BatchId}]});
                [{_, TS0, Ids}] ->
                    Ids1 = [{SegNum, BatchId}|Ids],
                    case all_parts_arrived(Ids1, ?gv(sar_total_segments, Params)) of
                        true ->
                            ets:delete(St#st.parts_tab, Key),
                            join_batches(Ids1, St);
                        false ->
                            ets:insert(St#st.parts_tab, {Key, TS0, Ids1})
                    end
            end,
            Reply = {ok, [{message_id, MsgId}]},
            gen_mc_session:reply(St#st.mc_session, {SeqNum, Reply}),
            fun_throughput:in(St#st.uuid),
            ok
    end;

step(take_fingerprints, {SeqNum, Params}, St) ->
    FP = take_fingerprints(Params),
    case ets:lookup(St#st.batch_tab, FP) of
        [] ->
            step(open_batch, {SeqNum, Params, FP}, St);
        [{FP, BatchId, _LastInsert, Size}] ->
            step(add_dest, {SeqNum, Params, FP, BatchId, Size}, St)
    end;

step(open_batch, {SeqNum, Params, FP}, St) ->
    case open_batch(Params, St) of
        {error, bad_message} ->
            {error, ?ESME_RINVDCS, "bad data coding"};
        ID ->
            step(add_dest, {SeqNum, Params, FP, ID, 0}, St)
    end;

step(add_dest, {SeqNum, Params, FP, BatchId, Size}, St) ->
    TS = fun_time:milliseconds(),
    MsgId = next_message_id(St),
    fun_tracker:add_dest(BatchId, MsgId, ?KEYFIND3(sar_msg_ref_num, Params, -1),
                         dest_addr(Params)),
    MaxSize = funnel_conf:get(batch_max_size),
    if
        Size + 1 >= MaxSize ->
            ets:delete(St#st.batch_tab, FP),
            fun_tracker:close_batch(St#st.customer_id, St#st.user_id, BatchId);
        true ->
            ets:insert(St#st.batch_tab, {FP, BatchId, TS, Size + 1})
    end,
    Reply = {ok, [{message_id, MsgId}]},
    gen_mc_session:reply(St#st.mc_session, {SeqNum, Reply}),
    fun_throughput:in(St#st.uuid),
    ok.

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

-ifdef(POWER_ALLEY).
billy_reserve({SeqNum, Params}, St) ->
    {ok, SessionId} = funnel_billy_session:get_session_id(),
    case billy_client:reserve(SessionId, ?CLIENT_TYPE_FUNNEL,
            list_to_binary(St#st.customer_uuid), list_to_binary(St#st.user_id),
            ?SERVICE_TYPE_SMS_ON, 1) of
        {accepted, TransactionId} ->
            Result = step(accept, {SeqNum, Params}, St),
            case Result of
                ok            -> billy_client:commit(TransactionId);
                {error, _, _} -> billy_client:rollback(TransactionId)
            end,
            Result;
        {rejected, Reason} ->
            {error, ?ESME_RSUBMITFAIL, io_lib:format("rejected by billy with: ~p", [Reason])}
    end.
-else.
billy_reserve({_SeqNum, _Params}, _St) ->
    {error, ?ESME_RSUBMITFAIL, io_lib:format("prepaid is not supported", [])}.
-endif.

reply(Pid, Reply) ->
    Pid ! {smpp_node_reply, Reply}.

dest_addr(Params) ->
    {
        ?KEYFIND2(destination_addr, Params),
        ?KEYFIND2(dest_addr_ton, Params),
        ?KEYFIND2(dest_addr_npi, Params)
    }.

pdu_log_name(Type, CustomerId, UserId, UUID) ->
    lists:flatten(io_lib:format("~s-cid~s-~s-~s.log",
                                [Type, CustomerId, UserId, UUID])).

to_tlv_if_udh(Params) ->
    {value, {esm_class, EsmClass}, Params_} =
        lists:keytake(esm_class, 1, Params),
    if
        (EsmClass band ?ESM_CLASS_GSM_UDHI) =:= ?ESM_CLASS_GSM_UDHI ->
            {value, {short_message, Body}, Params__} =
                lists:keytake(short_message, 1, Params_),
            {Udh, Rest} = smpp_sm:chop_udh(Body),
            [_, _, RefNum, TotalSegments, SeqNum] = smpp_sm:ie(?IEI_CONCAT, Udh),
            NewEsmClass = EsmClass band (?ESM_CLASS_GSM_UDHI bxor 2#11111111),
            [
                {sar_msg_ref_num,    RefNum},
                {sar_total_segments, TotalSegments},
                {sar_segment_seqnum, SeqNum},
                {short_message,      Rest},
                {esm_class,          NewEsmClass}|
                Params__
            ];
        true ->
            Params
    end.

take_fingerprints(Params) ->
    Keys = [
        data_coding,
        esm_class,
        short_message,
        priority_flag,
        protocol_id,
        registered_delivery,
        validity_period,
        sar_segment_seqnum,
        sar_total_segments,
        service_type,
        source_addr,
        source_addr_npi,
        source_addr_ton,
        network_id,
        provider_id
    ],
    erlang:md5([ V || {K, V} <- Params, lists:member(K, Keys) ]).

%% Convert message text to utf8 if needed and possible.
encode_message(Params) ->
    SM = list_to_binary(?KEYFIND2(short_message, Params)),
    case ?KEYFIND2(data_coding, Params) of
        DC when DC =:= 0; DC =:= 240; DC =:= 16 ->
            {_Validity, Enc} = gsm0338:to_utf8(SM),
            ?KEYREPLACE3(short_message, binary_to_list(Enc), Params);
        3 ->
            {ok, Enc} = iconverl:conv("utf-8//IGNORE", "latin1", SM),
            ?KEYREPLACE3(short_message, binary_to_list(Enc), Params);
        DC when DC =:= 8; DC =:= 24 ->
            {ok, Enc} = iconverl:conv("utf-8//IGNORE", "ucs-2be", SM),
            ?KEYREPLACE3(short_message, binary_to_list(Enc), Params);
        _Other ->
            Params
    end.

open_batch(Params, St) ->
    try encode_message(Params) of
        Encoded ->
            [P] = ets:lookup(St#st.providers, ?gv(provider_id, Params)),
            Extended = [{customer_uuid, St#st.customer_uuid},
                        {no_retry, St#st.no_retry},
                        {priority, St#st.priority},
                        {gateway_id, P#'Provider'.gatewayId},
                        {bulk_gateway_id, P#'Provider'.bulkGatewayId}|Encoded],
            fun_tracker:open_batch(St#st.uuid, St#st.customer_id,
                                   St#st.user_id, Extended)
    catch
        _:_ ->
            {error, bad_message}
    end.

next_message_id(St) ->
    integer_to_list(fun_tracker:next_message_id(St#st.customer_id, St#st.user_id)).

part_key(Params) ->
    {?gv(source_addr, Params), ?gv(destination_addr, Params),
     ?gv(sar_total_segments, Params), ?gv(sar_msg_ref_num, Params)}.

all_parts_arrived(Ids, Total) ->
    lists:all(fun(SN) -> proplists:is_defined(SN, Ids) end, lists:seq(1, Total)).

join_batches(Ids, St) ->
    USorted = lists:ukeysort(1, Ids),
    CommonsDests = fun_tracker:get_partial_batches([ ID || {_, ID} <- USorted ]),
    Commons = [ unparse_common(CommonBin) || {CommonBin, _} <- CommonsDests ],
    Message = join_messages([ ?gv(short_message, C) || C <- Commons ]),
	%% replaced lists:last/1 with erlang:hd/1 to fix
	%% http://extranet.powermemobile.com/issues/17458
    Params = ?KEYREPLACE3(short_message, Message,
                          proplists:delete(sar_segment_seqnum,
                                            proplists:delete(sar_total_segments,
                                                             hd(Commons)))),
    Dests = [ unparse_dest(DestBin) || {_, DestBin} <- CommonsDests ],
    Addr = {element(3, hd(Dests)), ?TON_INTERNATIONAL, ?NPI_ISDN},
    MsgId = string:join([ Id || {Id, _, _} <- Dests ], ":"),
    reinsert(Params, MsgId, -1, Addr, St),
    fun_tracker:delete_batches(St#st.customer_id, St#st.user_id,
                               [ ID || {_, ID} <- Ids ]).

join_messages(Msgs) ->
    lists:flatten([ if is_binary(M) -> binary_to_list(M); true -> M end || M <- Msgs ]).

reinsert(Params, MsgId, RefNum, Addr, St) ->
    FP = take_fingerprints(Params),
    {BatchId, Size} =
        case ets:lookup(St#st.batch_tab, FP) of
            [] ->
                {fun_tracker:open_batch(St#st.uuid, St#st.customer_id,
                                        St#st.user_id, Params),
                 0};
            [{FP, BId, _LastInsert, S}] ->
                {BId, S}
        end,
    TS = fun_time:milliseconds(),
    fun_tracker:add_dest(BatchId, MsgId, RefNum, Addr),
    MaxSize = funnel_conf:get(batch_max_size),
    if
        Size + 1 >= MaxSize ->
            ets:delete(St#st.batch_tab, FP),
            fun_tracker:close_batch(St#st.customer_id, St#st.user_id, BatchId);
        true ->
            ets:insert(St#st.batch_tab, {FP, BatchId, TS, Size + 1})
    end.

time_delta([Y1,Y2,M1,M2,D1,D2,H1,H2,Min1,Min2,S1,S2,_T,N1,N2,P] = VP) ->
    Years = list_to_integer([Y1,Y2]),
    Months = list_to_integer([M1,M2]),
    Days = list_to_integer([D1,D2]),
    Hours = list_to_integer([H1,H2]),
    Minutes = list_to_integer([Min1,Min2]),
    Seconds = list_to_integer([S1,S2]),
    case cl_string:is_atime(VP) of
        true ->
            % absolute time
            Offset = list_to_integer([N1,N2]) * 15 * 60 * case P of $+ -> 1; $- -> -1 end,
            DT = {{2000 + Years, Months, Days}, {Hours, Minutes, Seconds}},
            calendar:datetime_to_gregorian_seconds(DT) - Offset -
                calendar:datetime_to_gregorian_seconds(calendar:universal_time());
        false ->
            % relative time
            (((Years * 365 + Months * 31 + Days) * 24 + Hours) * 60 + Minutes) * 60 + Seconds
    end.

unparse_common(CommonBin) ->
    {ok, {obj, Common}, []} = rfc4627:decode(CommonBin),
    [ {list_to_atom(K), V} || {K, V} <- Common ].

unparse_dest(DestBin) ->
    [MsgId, RefNum, Addr, _, _] = re:split(DestBin, ";", [{return, list}]),
    {MsgId, list_to_integer(RefNum), Addr}.

fmt_validity(SecondsTotal) ->
    MinutesTotal = SecondsTotal div 60,
    HoursTotal = MinutesTotal div 60,
    DaysTotal = HoursTotal div 24,
    MonthsTotal = DaysTotal div 30,
    Years = MonthsTotal div 12,
    Seconds = SecondsTotal rem 60,
    Minutes = MinutesTotal rem 60,
    Hours = HoursTotal rem 24,
    Days = DaysTotal rem 30,
    Months = MonthsTotal rem 12,
    lists:flatten(io_lib:format("~2..0w~2..0w~2..0w~2..0w~2..0w~2..0w000R",
                  [Years, Months, Days, Hours, Minutes, Seconds])).
