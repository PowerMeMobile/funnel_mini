-module(fun_test_client).


-include("otp_records.hrl").
-include_lib("oserl/include/oserl.hrl").


-behaviour(gen_server).
-behaviour(gen_esme_session).


%% client exports
-export([start/0,
         stop/1,
         connect/2,
         bind/3,
         unbind/1,
         submit_sm/2,
         submit_multi/2]).


%% gen_server exports
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


%% gen_esme_session exports
-export([handle_accept/2,
         handle_alert_notification/2,
         handle_outbind/2,
         handle_resp/3,
         handle_operation/2,
         handle_enquire_link/2,
         handle_unbind/2,
         handle_closed/2]).


-record(st, {esme_session :: pid(),
             smpp_log_mgr :: pid(),
             req_tab      :: ets:tid()}).


%% -------------------------------------------------------------------------
%% Client API
%% -------------------------------------------------------------------------


-spec start/0 :: () -> {'ok', pid()}.

start() ->
    gen_server:start(?MODULE, [], []).


-spec stop/1 :: (pid()) -> no_return().

stop(Client) ->
    gen_server:cast(Client, stop).


%% addr, port, local_ip, enquire_link_time, inactivity_time, response_time, window_size
-spec connect/2 :: (pid(), list()) -> 'ok' | {'error', any()}.

connect(Client, Args) ->
    gen_server:call(Client, {connect, Args}, infinity).


%% system_id, password, system_type, addr_ton, addr_npi, address_range
-spec bind/3 :: (pid(), atom(), list()) -> 'ok' | {'error', any()}.

bind(Client, Type, Params) ->
    case gen_server:call(Client, {bind, Type, Params}, infinity) of
        {ok, _}         -> ok;
        {error, Reason} -> {error, Reason}
    end.


-spec unbind/1 :: (pid()) -> 'ok' | {'error', any()}.

unbind(Client) ->
    try gen_server:call(Client, unbind, infinity) of
        {ok, _}          -> ok;
        {error, Reason}  -> {error, Reason}
    catch
        exit:{noproc, _} -> {error, noproc};
        exit:_           -> {error, exited}
    end.


-spec submit_sm/2 :: (pid(), list()) -> {'ok', list()} | {'error', integer()}.

submit_sm(Client, Params) ->
    gen_server:call(Client, {submit_sm, Params}, infinity).


-spec submit_multi/2 :: (pid(), list()) -> {'ok', list()} | {'error', integer()}.

submit_multi(Client, Params) ->
    gen_server:call(Client, {submit_multi, Params}, infinity).


%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------


init([]) ->
    process_flag(trap_exit, true),
    {ok, SmppLogMgr} = smpp_log_mgr:start_link(),
    {ok, #st{smpp_log_mgr = SmppLogMgr, req_tab = ets:new(req_tab, [])}}.


terminate(_Reason, St) ->
    try
        gen_esme_session:stop(St#st.esme_session),
        smpp_log_mgr:stop(St#st.smpp_log_mgr),
        ets:delete(St#st.req_tab)
    catch
        _:_ -> ignore
    end.


handle_call({connect, Args}, _From, St) ->
    Timers = ?TIMERS(
        ?SESSION_INIT_TIME,
        proplists:get_value(enquire_link_time, Args, ?ENQUIRE_LINK_TIME),
        proplists:get_value(inactivity_time, Args, ?INACTIVITY_TIME),
        proplists:get_value(response_time, Args, ?RESPONSE_TIME)
    ),
    LocalIp =
        case proplists:get_value(local_ip, Args) of
            undefined -> undefined;
            IpStr     -> {ok, Ip} = inet_parse:address(IpStr), Ip
        end,
    Args1 = [{ip, LocalIp}, {log, St#st.smpp_log_mgr}, {timers, Timers}|Args],
    case gen_esme_session:start_link(?MODULE, Args1) of
        {ok, Session} ->
            {reply, ok, St#st{esme_session = Session}};
        {error, Reason} ->
            {reply, {error, Reason}, St}
    end;


handle_call({bind, Type, Params}, From, St) ->
    Fun =
        case Type of
            transmitter -> bind_transmitter;
            receiver    -> bind_receiver;
            transceiver -> bind_transceiver
        end,
    Ref = gen_esme_session:Fun(St#st.esme_session, Params),
    ets:insert(St#st.req_tab, {Ref, From}),
    % we do not reply here. reply will be delivered from handle_resp
    {noreply, St};


handle_call(unbind, From, St) ->
    Ref = gen_esme_session:unbind(St#st.esme_session),
    ets:insert(St#st.req_tab, {Ref, From}),
    % we do not reply here. reply will be delivered from handle_resp
    {noreply, St};


%% handle submit_sm/submit_multi calls.
handle_call({Cmd, Params}, From, St) ->
    Ref = gen_esme_session:Cmd(St#st.esme_session, Params),
    ets:insert(St#st.req_tab, {Ref, From}),
    {noreply, St}.


handle_cast(stop, St) ->
    {stop, normal, St};


handle_cast({handle_resp, Resp, Ref}, St) ->
    [{_, From}] = ets:lookup(St#st.req_tab, Ref),
    ets:delete(St#st.req_tab, Ref),
    case Resp of
        {ok, {_CmdId, _Status, _SeqNum, Body}} ->
            gen_server:reply(From, {ok, Body});
        {error, {command_status, Status}} ->
            gen_server:reply(From, {error, Status})
    end,
    {noreply, St};


handle_cast({handle_deliver_sm, SeqNum, Params}, St) ->
    lager:debug("test client: got deliver_sm (params: ~p)", [Params]),
    Reply = {ok, []},
    gen_esme_session:reply(St#st.esme_session, {SeqNum, Reply}),
    {noreply, St};


handle_cast({handle_closed, Reason}, St) ->
    {stop, {closed, Reason}, St};


handle_cast(handle_unbind, St) ->
    {stop, unbound, St}.


handle_info(#'EXIT'{pid = Pid, reason = Reason}, #st{esme_session = Pid} = St) ->
    {stop, {session_exit, Reason}, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.


%% -------------------------------------------------------------------------
%% gen_esme_session callback functions
%% -------------------------------------------------------------------------


%% only needed for listening clients that support outbind
handle_accept(_Client, _Addr) ->
    {error, forbidden}.


%% we do not use data_sm and thus never set delivery_pending flag
handle_alert_notification(_Client, _Pdu) ->
    ok.


%% we do not provide outbind support
handle_outbind(_Client, _Pdu) ->
    ok.


%% Delivers an async repsonse to the request with Ref.
handle_resp(Client, Resp, Ref) ->
    gen_server:cast(Client, {handle_resp, Resp, Ref}).


%% Handle SMSC-issued deliver_sm operation.
handle_operation(Client, {deliver_sm, {_CmdId, _Status, SeqNum, Body}}) ->
    gen_server:cast(Client, {handle_deliver_sm, SeqNum, Body}),
    noreply;


%% Return ?ESME_RINVCMDID error for any other operation.
handle_operation(_Client, {_Cmd, _Pdu}) ->
    {error, ?ESME_RINVCMDID}.


%% Forwards enquire_link operations (from the peer MC) to the callback module.
handle_enquire_link(_Client, _Pdu) ->
    ok.


%% Handle SMSC-issued unbind.
handle_unbind(Client, _Pdu) ->
    gen_server:cast(Client, handle_unbind).


%% Notify Client of the Reason before stopping the session.
handle_closed(Client, Reason) ->
    gen_server:cast(Client, {handle_closed, Reason}).
