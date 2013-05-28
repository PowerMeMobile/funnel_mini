-module(fun_tracker).


-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("alley_dto/include/JustAsn.hrl").
-include_lib("queue_fabric/include/queue_fabric.hrl").
-include("helpers.hrl").
-include("otp_records.hrl").


-behaviour(gen_server2).


%% API exports
-export([start_link/0,
         next_message_id/2,
         register_user/2,
         open_batch/4,
         add_dest/4,
         close_batch/3,
         get_partial_batches/1,
         delete_batches/3]).


%% gen_server2 exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).


%% internal exports
-export([close_batches/3]).


-define(CLOSE_BATCHES_INTERVAL, 500).

-define(TCH_FILE, "data/tokyo/tracker.tch").

-define(TOKYO_USERS,
    <<"users">>).
-define(TOKYO_MESSAGE_ID(CustomerId, UserId),
    list_to_binary(["message_id:", CustomerId, $:, UserId])).
-define(TOKYO_USER_BATCHES(CustomerId, UserId),
    list_to_binary(["user:", CustomerId, $:, UserId, ":batches"])).
-define(TOKYO_BATCH_COMMON(UUID),
    list_to_binary(["batch:", UUID, ":common"])).
-define(TOKYO_BATCH_DESTS(UUID),
    list_to_binary(["batch:", UUID, ":dests"])).

-record(st, {toke                  :: pid(),
             amqp_chan             :: pid(),
             batches_to_close = [] :: list(),
             batch_closer          :: pid()}).

-define(gv(K, P), proplists:get_value(K, P)).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------


-spec start_link/0 :: () -> {'ok', pid()} | 'ignore' | {'error', any()}.

start_link() ->
    gen_server2:start_link({local, ?MODULE}, ?MODULE, [], []).


-spec next_message_id/2 :: (string(), string()) -> pos_integer().

next_message_id(CustomerId, UserId) ->
    gen_server2:call(?MODULE, {next_message_id, CustomerId, UserId}, infinity).


-spec register_user/2 :: (string(), string()) -> 'ok'.

register_user(CustomerId, UserId) ->
    gen_server2:call(?MODULE, {register_user, CustomerId, UserId}, infinity).


-spec open_batch/4 :: (string(), string(), string(), list()) -> binary().

open_batch(ConnectionId, CustomerId, UserId, Params) ->
    Request = {open_batch, ConnectionId, CustomerId, UserId, Params},
    gen_server2:call(?MODULE, Request, infinity).


-spec add_dest(binary(), string(), integer() | 'undefined',
               {string(), integer(), integer()}) -> 'ok'.
add_dest(BatchId, MsgId, RefNum, Dest) ->
    gen_server2:call(?MODULE,
        {add_dest, BatchId, MsgId, RefNum, Dest}, infinity).


-spec close_batch/3 :: (string(), string(), binary()) -> 'ok'.

close_batch(CustomerId, UserId, BatchId) ->
    gen_server2:cast(?MODULE, {close_batch, CustomerId, UserId, BatchId}).

-spec get_partial_batches([binary()]) -> [{binary(), binary()}].
get_partial_batches(BatchIds) ->
    gen_server2:call(?MODULE, {get_partial_batches, BatchIds}, infinity).

-spec delete_batches(string(), string(), [binary()]) -> 'ok'.
delete_batches(CustomerId, UserId, BatchIds) ->
    gen_server2:cast(?MODULE, {delete_batches, CustomerId, UserId, BatchIds}).

%% -------------------------------------------------------------------------
%% gen_server2 callback functions
%% -------------------------------------------------------------------------


init([]) ->
    process_flag(trap_exit, true),
    lager:info("tracker: initializing"),
    {ok, Toke} = toke_drv:start_link(),
    ok = toke_drv:new(Toke),
    ok = toke_drv:set_cache(Toke, 1000),
    case toke_drv:open(Toke, ?TCH_FILE, [read, write, create]) of
        ok ->
            Chan = fun_amqp_pool:open_channel(),
            erlang:monitor(process, Chan),
            ok = fun_amqp:queue_declare(Chan, ?FUNNEL_BATCHES_Q, true, false, false),
            ok = fun_amqp:tx_select(Chan),
            close_all_batches(Toke, Chan),
            erlang:start_timer(?CLOSE_BATCHES_INTERVAL, self(), close_batches),
            {ok, #st{toke = Toke, amqp_chan = Chan}};
        {error_from_tokyo_cabinet, Reason} ->
            lager:error("tracker: ~s", [Reason]),
            toke_drv:delete(Toke),
            toke_drv:stop(Toke),
            {stop, Reason}
    end.


terminate(Reason, St) ->
    toke_drv:close(St#st.toke),
    toke_drv:delete(St#st.toke),
    toke_drv:stop(St#st.toke),
    fun_amqp_pool:close_channel(St#st.amqp_chan),
    lager:info("tracker: terminated (~p)", [Reason]).


handle_call({next_message_id, CustomerId, UserId}, _From, St) ->
    Key = ?TOKYO_MESSAGE_ID(CustomerId, UserId),
    Reply =
        case toke_drv:get(St#st.toke, Key) of
            <<Id:32/native>> when Id < 99999999 ->
                toke_drv:insert(St#st.toke, Key, <<(Id + 1):32/native>>),
                Id + 1;
            _ -> % not_found or >= 999999999
                toke_drv:insert(St#st.toke, Key, <<1:32/native>>),
                1
        end,
    {reply, Reply, St};


handle_call({register_user, CustomerId, UserId}, _From, St) ->
    User  = list_to_binary([CustomerId, $:, UserId]),
    Users =
        case toke_drv:get(St#st.toke, ?TOKYO_USERS) of
            not_found -> [];
            Value     -> re:split(Value, "/", [trim])
        end,
    case lists:member(User, Users) of
        true ->
            ok;
        false ->
            toke_drv:insert_concat(St#st.toke,
                ?TOKYO_USERS, list_to_binary([User, $/])
            )
    end,
    {reply, ok, St};


handle_call({open_batch, ConnectionId, CustomerId, UserId, Params}, _From, St) ->
	%% Replaced uuid:generate/0 which generates (at least on Linux) random v4 UUIDs
	%% with uuid:generate_time/0 which generates v1 UUIDs using MAC address and local time.
	%% These random UUIDs are used in the {ri: 1, imi: 1} index. They are distributed
	%% evenly and are inserted at different parts of the index's B-tree. Over time the index
	%% will grow and it won't fit in RAM. Different parts of the index will be swapped in/out,
	%% and performance will drop severly.
	%% Time based UUIDs are inserted only to the right part of the B-tree and as the index will grow,
	%% only the left unused branches are swapped in to the disk and performance degradation is not
	%% that significant.
	%% See http://extranet.powermemobile.com/issues/20686 for detail.
    UUID = uuid:unparse(uuid:generate_time()),
    Obj = [
        % meta.
        {connection_id, ConnectionId},
        {user_id, UserId},
        lists:keyfind(customer_uuid, 1, Params),
        lists:keyfind(network_id, 1, Params),
        lists:keyfind(provider_id, 1, Params),
        lists:keyfind(gateway_id, 1, Params),
        lists:keyfind(bulk_gateway_id, 1, Params),
        lists:keyfind(priority, 1, Params),
        lists:keyfind(no_retry, 1, Params),
        % data.
        lists:keyfind(service_type, 1, Params),
        lists:keyfind(source_addr_ton, 1, Params),
        lists:keyfind(source_addr_npi, 1, Params),
        lists:keyfind(source_addr, 1, Params),
        lists:keyfind(esm_class, 1, Params),
        lists:keyfind(protocol_id, 1, Params),
        lists:keyfind(priority_flag, 1, Params),
        lists:keyfind(registered_delivery, 1, Params),
        lists:keyfind(validity_period, 1, Params),
        lists:keyfind(data_coding, 1, Params),
        lists:keyfind(short_message, 1, Params),
        {sar_msg_ref_num, ?KEYFIND3(sar_msg_ref_num, Params, -1)},
        {sar_total_segments, ?KEYFIND3(sar_total_segments, Params, -1)},
        {sar_segment_seqnum, ?KEYFIND3(sar_segment_seqnum, Params, -1)}
    ],
    JSON = list_to_binary(rfc4627:encode({obj, Obj})),
    toke_drv:insert_concat(St#st.toke,
        ?TOKYO_USER_BATCHES(CustomerId, UserId), list_to_binary([UUID, $/])
    ),
    toke_drv:insert(St#st.toke, ?TOKYO_BATCH_COMMON(UUID), JSON),
    {reply, UUID, St};

handle_call({add_dest, BatchId, MsgId, RefNum, Dest}, _From, St) ->
    {Addr, Ton, Npi} = Dest,
    Entry = list_to_binary(lists:concat([
        MsgId, ";", RefNum, ";", Addr, ";", Ton, ";", Npi, "/"
    ])),
    toke_drv:insert_concat(St#st.toke, ?TOKYO_BATCH_DESTS(BatchId), Entry),
    {reply, ok, St};

handle_call({get_partial_batches, BatchIds}, _From, St) ->
    {reply,
     lists:map(fun(ID) ->
                   {toke_drv:get(St#st.toke, ?TOKYO_BATCH_COMMON(ID)),
                    toke_drv:get(St#st.toke, ?TOKYO_BATCH_DESTS(ID))}
               end, BatchIds),
     St}.

handle_cast({close_batch, CustomerId, UserId, BatchId}, St) ->
    Batches = [{CustomerId, UserId, BatchId}|St#st.batches_to_close],
    {noreply, St#st{batches_to_close = Batches}};

handle_cast({delete_batches, CustomerId, UserId, BatchIds}, St) ->
    delete_user_batches(St#st.toke, CustomerId, UserId, BatchIds),
    {noreply, St}.

handle_info(#timeout{msg = close_batches}, St) ->
    case St#st.batches_to_close of
        [] ->
            erlang:start_timer(?CLOSE_BATCHES_INTERVAL, self(), close_batches),
            {noreply, St};
        Batches ->
            Pid = proc_lib:spawn_link(
                ?MODULE, close_batches, [St#st.toke, St#st.amqp_chan, Batches]
            ),
            {noreply, St#st{batches_to_close = [], batch_closer = Pid}}
    end;


handle_info(#'EXIT'{pid = Pid, reason = normal}, #st{batch_closer = Pid} = St) ->
    erlang:start_timer(?CLOSE_BATCHES_INTERVAL, self(), close_batches),
    {noreply, St};


%% batch closer exited with abnormal reason.
handle_info(#'EXIT'{pid = Pid}, #st{batch_closer = Pid} = St) ->
    {stop, batch_closer, St};


handle_info(#'DOWN'{pid = Pid}, #st{amqp_chan = Pid} = St) ->
    {stop, amqp_down, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.


%% -------------------------------------------------------------------------
%% Private functions
%% -------------------------------------------------------------------------


close_all_batches(Toke, Chan) ->
    CustomersUsers =
        case toke_drv:get(Toke, ?TOKYO_USERS) of
            not_found ->
                [];
            Value ->
				[ re:split(CU, ":", [{return, list}]) ||
				  CU <- re:split(Value, "/", [trim]) ]
        end,
    Batches = lists:flatmap(
        fun([C, U]) ->
                case toke_drv:get(Toke, ?TOKYO_USER_BATCHES(C, U)) of
                    not_found ->
                        [];
                    BatchesBin ->
                        [ {C, U, B} || B <- re:split(BatchesBin, "/", [trim]) ]
                end
        end, CustomersUsers
    ),
    close_batches(Toke, Chan, Batches),
    toke_drv:delete(Toke, ?TOKYO_USERS).


close_batches(_Toke, _Chan, []) ->
    ok;
close_batches(Toke, Chan, Batches) ->
    [ publish_user_batch(Toke, Chan, BatchId) || {_, _, BatchId} <- Batches ],
    ok = fun_amqp:tx_commit(Chan),
    UsersBatches = lists:foldl(
        fun({CustomerId, UserId, BatchId}, Acc) ->
                Key = {CustomerId, UserId},
                case lists:keytake(Key, 1, Acc) of
                    false ->
                        [{Key, [BatchId]}|Acc];
                    {value, {Key, Ids}, Acc_} ->
                        [{Key, [BatchId|Ids]}|Acc_]
                end
        end, [], Batches
    ),
    [ delete_user_batches(Toke, CustomerId, UserId, BatchIds) ||
        {{CustomerId, UserId}, BatchIds} <- UsersBatches ].


publish_user_batch(Toke, Chan, BatchId) ->
    CommonBin = toke_drv:get(Toke, ?TOKYO_BATCH_COMMON(BatchId)),
    DestsBin  = toke_drv:get(Toke, ?TOKYO_BATCH_DESTS(BatchId)),
    if
        CommonBin =/= not_found andalso DestsBin =/= not_found ->
            {ok, {obj, Common}, []} = rfc4627:decode(CommonBin),
            Dests = lists:usort(re:split(DestsBin, "/", [trim])),
            Total = lists:foldl(fun(DestBin, Acc) ->
                                    MsgId = hd(re:split(DestBin, ";", [trim])),
                                    length(re:split(MsgId, ":", [trim])) + Acc
                                end, 0, Dests),
            GtwId = case Total < funnel_conf:get(bulk_threshold) of
                        true  -> string:to_lower(?gv("gateway_id", Common));
                        false -> string:to_lower(?gv("bulk_gateway_id", Common))
                    end,
            Prio = ?gv("priority", Common),
            Headers = [],
            Basic = #'P_basic'{
                content_type = <<"SmsRequest">>,
                delivery_mode = 2,
                priority = Prio,
                message_id = BatchId,
                headers = [ encode_header(H) || H <- Headers ]
            },
            Payload = encode_batch(Common, Dests, BatchId, GtwId),
			GtwQueue = <<?JUST_GTW_Q_PREFIX/binary, $., (list_to_binary(GtwId))/binary>>,
            ok = fun_amqp:basic_publish(Chan, ?FUNNEL_BATCHES_Q, Payload, Basic),
            ok = fun_amqp:basic_publish(Chan, GtwQueue, Payload, Basic);
        true ->
            ok
    end.

encode_batch(Common, Dests, BatchId, GtwId) ->
	RN = ?gv("sar_msg_ref_num", Common),
    TS = ?gv("sar_total_segments", Common),
    SS = ?gv("sar_segment_seqnum", Common),
    Type = case TS =:= -1 andalso SS =:= -1 of true -> regular; false -> part end,
    {MsgIds, DestAsns} = lists:foldl(
        fun(Bin, {Ids, Asns}) ->
            [MsgId, RefNum, Addr, Ton, Npi] =
                re:split(Bin, ";", [trim]),
            FA = #'FullAddr'{addr = Addr,
                             ton = list_to_integer(binary_to_list(Ton)),
                             npi = list_to_integer(binary_to_list(Npi))},
            case Type of
                regular ->
                    {[MsgId|Ids], [FA|Asns]};
                part ->
                    {[MsgId|Ids],
                     [#'FullAddrAndRefNum'{
                          fullAddr = FA,
                          refNum = list_to_integer(binary_to_list(RefNum))
                      }|Asns]}
            end
        end,
        {[], []},
        Dests
    ),
    ParamsBase = [{registered_delivery, ?gv("registered_delivery", Common) > 0},
                  {service_type, ?gv("service_type", Common)},
                  {no_retry, ?gv("no_retry", Common)},
                  {validity_period, ?gv("validity_period", Common)},
                  {priority_flag, ?gv("priority_flag", Common)},
                  {esm_class, ?gv("esm_class", Common)},
                  {protocol_id, ?gv("protocol_id", Common)}],
    ParamsSar = case Type of
                    regular ->
                        ParamsBase;
                    part ->
                        [{sar_msg_ref_num, RN}, {sar_total_segments, TS}, {sar_segment_seqnum, SS}|ParamsBase]
                end,
    DataCoding = ?gv("data_coding", Common),
    Params = case DataCoding of
                 240 -> [{data_coding, 240}|ParamsSar];
                 _   -> ParamsSar
             end,
    ReqAsn = #'SmsRequest'{
        id = BatchId,
        gatewayId = GtwId,
        customerId = ?gv("customer_uuid", Common),
        userId = ?gv("user_id", Common),
        type = Type,
        message = ?gv("short_message", Common),
        encoding =
            case DataCoding of
                DC when DC =:= 0; DC =:= 1; DC =:= 3; DC =:= 240 ->
                    {text, default};
                8 ->
                    {text, ucs2};
                DC ->
                    {other, DC}
            end,
        params = [ asn_param(P) || P <- Params ],
        sourceAddr = #'FullAddr'{
            addr = ?gv("source_addr", Common),
            ton = ?gv("source_addr_ton", Common),
            npi = ?gv("source_addr_npi", Common)
        },
        destAddrs = {Type, DestAsns},
        messageIds = MsgIds
    },
    {ok, EncodedReq} = 'JustAsn':encode('SmsRequest', ReqAsn),
    list_to_binary(EncodedReq).

delete_user_batches(_Toke, _CustomerId, _UserId, []) ->
    ok;
delete_user_batches(Toke, CustomerId, UserId, BatchIds) ->
    lists:foreach(
        fun(BatchId) ->
                toke_drv:delete(Toke, ?TOKYO_BATCH_COMMON(BatchId)),
                toke_drv:delete(Toke, ?TOKYO_BATCH_DESTS(BatchId))
        end, BatchIds
    ),
    BatchesKey = ?TOKYO_USER_BATCHES(CustomerId, UserId),
    BatchesBin = toke_drv:get(Toke, BatchesKey),
    if
        BatchesBin =/= not_found ->
            Batches = re:split(BatchesBin, "/", [trim]),
            NewBatches = list_to_binary(
                [ [BId, $/] || BId <- Batches, not lists:member(BId, BatchIds) ]
            ),
            if
                NewBatches =:= <<>> ->
                    toke_drv:delete(Toke, BatchesKey);
                true ->
                    toke_drv:insert(Toke, BatchesKey, NewBatches)
            end;
        true ->
            ok
    end.

encode_header({K, V}) ->
    {Type, Val} =
        case V of
            true  -> {longstr, <<"true">>};
            false -> {longstr, <<"false">>};
            Int when is_integer(Int) -> {signedint, Int};
            Str   -> {longstr, Str}
        end,
    {erlang:atom_to_binary(K, latin1), Type, Val}.

asn_param({K, V}) ->
    #'Param'{name = atom_to_list(K),
             value = case V of
                         I when is_integer(I) ->
                             {integer, I};
                         B when is_boolean(B) ->
                             {boolean, B};
                         S ->
                             {string, S}
                     end}.
