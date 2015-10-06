-module(fun_smpp_server).

-include_lib("oserl/include/oserl.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_dto/include/FunnelAsn.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include("otp_records.hrl").

-behaviour(gen_server).

%% API exports
-export([start_link/0,
         stop/0,
         handle_accept/2,
         handle_bind/2,
         node_terminated/5,
         connections/0,
		 notify_backend_connection_up/5]).

%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

-record(node, {id               :: pos_integer(),
               uuid             :: string(),
               pid              :: pid(),
               addr             :: string(),
               connected_at     :: calendar:datetime(),
               customer_id      :: string(),
               user_id          :: string(),
               password         :: string(),
               type             :: 'transmitter' | 'receiver' | 'transceiver',
               state = accepted :: 'accepted' | 'bound',
               bind_ref         :: reference()}).

-record(st, {amqp_chan           :: pid(),
             is_stopping = false :: boolean(),
             stopper_from        :: {pid(), reference()},
             lsock               :: port(),
             smpp_node           :: pid(),
             last_node_id = 0    :: non_neg_integer(),
             nodes = []          :: [#node{}]}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec start_link() -> {'ok', pid()} | 'ignore' | {'error', any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec stop() -> 'ok'.
stop() ->
    gen_server:call(?MODULE, stop, infinity).

-spec handle_accept(pid(), string()) ->
    {'true', string(), {{_,_,_},{_,_,_}}} | 'false'.
handle_accept(Node, Addr) ->
    gen_server:call(?MODULE, {handle_accept, Node, Addr}, infinity).

-spec handle_bind(pid(), tuple()) ->
    {'ok', list(), list()} | {'error', integer()}.
handle_bind(Node, {_Addr, _Type, _CustomerId, _UserId, _Password} = Details) ->
    Timeout = funnel_conf:get(session_init_time) - 100,
    gen_server:call(?MODULE, {handle_bind, Node, Details}, Timeout).

-spec node_terminated/5 ::
    (string(), non_neg_integer(), non_neg_integer(), list(), atom()) -> no_return().
node_terminated(UUID, MsgsReceived, MsgsSent, Errors, Reason) ->
    gen_server:cast(?MODULE,
                    {node_terminated, UUID, MsgsReceived, MsgsSent, Errors, Reason}).

-spec connections() -> list().
connections() ->
    gen_server:call(?MODULE, connections, infinity).

-spec notify_backend_connection_up/5 ::
	(string(), string(), string(), atom(), calendar:datetime()) -> ok.
notify_backend_connection_up(ConnUUID, CustomerId, UserId, Type, ConnectedAt) ->
	gen_server:cast(?MODULE, {notify_connection_up,
									ConnUUID,
									CustomerId,
									UserId,
									Type,
									ConnectedAt}).

%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    Addr = funnel_conf:get(smpp_server_addr),
    Port = funnel_conf:get(smpp_server_port),
    ?log_info("Server: initializing (addr: ~s, port: ~w)",
        [inet_parse:ntoa(Addr), Port]),
    case smpp_session:listen([{addr, Addr}, {port, Port}]) of
        {ok, LSock} ->
            Chan = fun_amqp_pool:open_channel(),
            erlang:monitor(process, Chan),
            Control = funnel_app:get_env(queue_server_control),
            ok = fun_amqp:queue_declare(Chan, Control, false, true, true),
            {ok, _CTag} = fun_amqp:basic_consume(Chan, Control, true),
            {ok, Node} = fun_smpp_node:start_link(LSock),
            catch(notify_backend_server_up(Chan)),
            {ok, #st{
                amqp_chan   = Chan,
                lsock       = LSock,
                smpp_node   = Node
            }};
        {error, Reason} ->
            ?log_error("Server: failed to start (~p)", [Reason]),
            {stop, Reason}
    end.

terminate(Reason, St) ->
    catch(notify_backend_server_down(St#st.amqp_chan)),
    fun_amqp_pool:close_channel(St#st.amqp_chan),
    fun_smpp_node:stop(St#st.smpp_node),
    timer:sleep(100),
    gen_tcp:close(St#st.lsock),
    ?log_info("Server: terminated (~p)", [Reason]).

handle_call(stop, From, St) ->
    ?log_info("Server: stopping", []),
    erlang:start_timer(funnel_conf:get(max_stop_time), self(), stop),
    Nodes = bound_nodes(St#st.nodes),
    [ fun_smpp_node:unbind(Pid) || #node{pid = Pid} <- Nodes ],
    case Nodes of
        [] -> {stop, normal, ok, St};
        _  -> {noreply, St#st{is_stopping = true, stopper_from = From}}
    end;

handle_call({handle_accept, Pid, Addr}, _From, St) ->
    MaxConns = funnel_app:get_env(max_connections),
    if
        St#st.is_stopping ->
            {reply, false, St};
        length(St#st.nodes) >= MaxConns ->
            ?log_warn(
                "Server: rejected connection (ip: ~s) (too many connections)",
                [Addr]
            ),
            {reply, false, St};
        true ->
            UUID = binary_to_list(uuid:unparse(uuid:generate())),
            ?log_info("Server: accepted connection (ip: ~s, uuid: ~s)", [Addr, UUID]),
            {ok, Node} = fun_smpp_node:start_link(St#st.lsock),
            ConnectedAt = calendar:local_time(),
            {reply, {true, UUID, ConnectedAt}, St#st{
                smpp_node    = Node,
                last_node_id = St#st.last_node_id + 1,
                nodes = [
                    #node{
                        id           = St#st.last_node_id + 1,
                        uuid         = UUID,
                        pid          = Pid,
                        addr         = Addr,
                        connected_at = ConnectedAt
                    }|St#st.nodes
                ]
            }}
    end;

handle_call({handle_bind, _Pid, {Addr, Type, CustomerId, UserId, Password}},
        _From, #st{is_stopping = true} = St) ->
    ?log_warn(
        "Server: denied bind "
        "(addr: ~s, customer: ~s, user: ~s, password: ~s, type: ~s) (~s)",
        [Addr, CustomerId, UserId, Password, Type, "server is stopping"]
    ),
    {reply, {error, ?ESME_RBINDFAIL}, St};

handle_call({handle_bind, Pid, {Addr, Type, CustomerId, UserId, Password}},
            {Pid, Ref}, St) ->
    case allow_another_bind(CustomerId, UserId, Type, Pid, St) of
        true ->
            ?log_info(
                "Server: requesting backend auth "
                "(addr: ~s, customer: ~s, user: ~s, password: ~s, type: ~s)",
                [Addr, CustomerId, UserId, Password, Type]
            ),
            {value, Node, Nodes} = lists:keytake(Pid, #node.pid, St#st.nodes),
            Node2 = Node#node{
                bind_ref    = Ref,
                customer_id = CustomerId,
                user_id     = UserId,
                password    = Password,
                type        = Type
            },
            case alley_services_auth:authenticate(
                    list_to_binary(CustomerId), list_to_binary(UserId),
                    list_to_binary(Password), Type) of
                {ok, Response} ->
                    handle_bind_response(Response, Node2, St#st{nodes = [Node2|Nodes]});
                {error, Error} ->
                    ?log_error(
                        "Server: bind failed with: ~p"
                        "(customer: ~s, user: ~s, password: ~s, type: ~s)",
                        [Error, CustomerId, UserId, Password, Type]
                    ),
                    {noreply, St}
            end;
        false ->
            ?log_warn(
                "Server: denied bind "
                "(addr: ~s, customer: ~s, user: ~s, password: ~s, type: ~s) (~s)",
                [Addr, CustomerId, UserId, Password, Type, "already bound"]
            ),
            {reply, {error, ?ESME_RALYBND}, St}
    end;

handle_call(connections, _From, St) ->
    Reply = lists:map(
        fun(#node{
                id           = ID,
                uuid         = UUID,
                pid          = NodePid,
                connected_at = ConnectedAt,
                type         = Type,
                addr         = Addr,
                customer_id  = CustomerId,
                user_id      = UserId
            }) ->
                {ID, UUID, ConnectedAt, Type, Addr, CustomerId, UserId, NodePid}
        end, bound_nodes(St#st.nodes)
    ),
    {reply, Reply, St}.

handle_cast({notify_connection_up,
					ConnID,
					CustomerId,
					UserId,
					Type,
					ConnectedAt}, St) ->
    ConnectionUpEvent = #'ConnectionUpEvent'{
        connectionId = ConnID,
        customerId   = CustomerId,
        userId       = UserId,
        type         = Type,
        connectedAt  = fun_time:utc_str(ConnectedAt),
        timestamp    = fun_time:utc_str()
    },
    {ok, Payload} =
        'FunnelAsn':encode('ConnectionUpEvent', ConnectionUpEvent),
    RoutingKey = funnel_app:get_env(queue_backend_events),
    Props = #'P_basic'{
        content_type = <<"ConnectionUpEvent">>,
        message_id   = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, RoutingKey, Payload, Props),
	{noreply, St};

handle_cast({node_terminated, UUID, MsgsReceived, MsgsSent, Errors, Reason}, St) ->
    Node = lists:keyfind(UUID, #node.uuid, St#st.nodes),
    ?log_info(
        "Server: connection terminated "
        "(ip: ~s, uuid: ~s, customer: ~s, user: ~s, reason: ~s)",
        [Node#node.addr, UUID, Node#node.customer_id, Node#node.user_id, Reason]
    ),
    notify_backend_connection_down(St#st.amqp_chan,
        UUID,
        Node#node.customer_id, Node#node.user_id,
        Node#node.type,
        Node#node.connected_at,
        MsgsReceived, MsgsSent,
        Errors,
        Reason
    ),
    {noreply, St}.

handle_info({#'basic.deliver'{}, Content}, St) ->
    #amqp_msg{payload = Payload, props = Props} = Content,
    handle_basic_deliver(Props#'P_basic'.content_type, Payload, Props, St);

handle_info(#'EXIT'{pid = Pid}, #st{lsock = Pid} = St) ->
    {stop, lsock_closed, St};

handle_info(#'EXIT'{pid = Pid}, #st{smpp_node = Pid} = St) ->
    {ok, Node} = fun_smpp_node:start_link(St#st.lsock),
    {noreply, St#st{smpp_node = Node}};

handle_info(#'DOWN'{pid = Pid}, #st{amqp_chan = Pid} = St) ->
    {stop, amqp_closed, St};

handle_info(#'EXIT'{pid = Pid}, St) ->
    Node = lists:keyfind(Pid, #node.pid, St#st.nodes),
    if
        Node =/= false andalso Node#node.state =:= accepted ->
            ?log_info(
                "Server: connection terminated (ip: ~s, uuid: ~s), not bound",
                [Node#node.addr, Node#node.uuid]
            );
        true ->
            % it's not a node, or it was a bound node, and hence
            % had been logged in node_terminated.
            ignore
    end,
    Nodes = lists:keydelete(Pid, #node.pid, St#st.nodes),
    Bound = bound_nodes(Nodes),
    if
        St#st.is_stopping andalso length(Bound) =:= 0 ->
            gen_server:reply(St#st.stopper_from, ok),
            {stop, normal, St#st{nodes = Nodes}};
        true ->
            {noreply, St#st{nodes = Nodes}}
    end;

handle_info(#timeout{msg = stop}, St) ->
    gen_server:reply(St#st.stopper_from, ok),
    {stop, normal, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% -------------------------------------------------------------------------
%% private helpers
%% -------------------------------------------------------------------------

bound_nodes(Nodes) ->
    [ N || #node{state = bound} = N <- Nodes ].

allow_another_bind(CustomerId, UserId, Type, Pid, St) ->
    UserNodes = lists:filter(
        fun(#node{customer_id = CstId, user_id = UsrId, pid = P}) ->
                CstId =:= CustomerId andalso UsrId =:= UserId andalso P =/= Pid
        end, St#st.nodes
    ),
    case Type of
        transceiver ->
            % transceiver. no other connections by user may exits.
            length(UserNodes) =:= 0;
        _ ->
            % receiver or transmitter. same type or transceiver not allowed.
            not lists:any(
                fun(#node{type = T}) ->
                        T =:= Type orelse T =:= transceiver
                end, UserNodes
            )
    end.

%% -------------------------------------------------------------------------
%% amqp helpers
%% -------------------------------------------------------------------------

handle_bind_response(#auth_resp_v2{result = #auth_error_v2{code = Error}}, Node, St) ->
    case lists:keytake(Node#node.uuid, #node.uuid, St#st.nodes) of
        {value, _Node, Nodes} ->
             ?log_warn(
                "Server: denied bind "
                 "(addr: ~s, customer: ~s, user: ~s, password: ~s, type: ~s) (~s)",
                 [Node#node.addr, Node#node.customer_id, Node#node.user_id,
                  Node#node.password, Node#node.type, Error]
            ),
            Node2 = Node#node{
                bind_ref = undefined,
                customer_id = undefined,
                user_id = undefined,
                password = undefined,
                type = undefined
            },
            {reply, {error, ?ESME_RBINDFAIL}, St#st{nodes = [Node2|Nodes]}};
        _ ->
            {noreply, St}
    end;
handle_bind_response(#auth_resp_v2{result = #auth_customer_v2{} = Customer}, Node, St) ->
    case lists:keytake(Node#node.uuid, #node.uuid, St#st.nodes) of
        {value, _Node, Nodes} ->
            #node{addr = Addr, customer_id = CustomerId, user_id = UserId, uuid = _ConnUUID,
                  password = Password, type = Type, connected_at = _ConnectedAt} = Node,
            #auth_customer_v2{customer_uuid = UUID, priority = Priority, rps = Rps,
                        allowed_sources = Allowed, default_source = Source,
                        networks = Networks, providers = Providers,
                        default_provider_id = DefaultProvId,
                        receipts_allowed = ReceptsAllowed,
                        no_retry = NoRetry, default_validity = DefaultValidity,
                        max_validity = MaxValidity, pay_type = PayType,
                        features = Features} = Customer,
            ?log_info(
                "Server: granted bind "
                "(addr: ~s, customer: ~s, user: ~s, password: ~s, type: ~s, rps: ~w, pay type: ~w)",
                [Addr, CustomerId, UserId, Password, Type, Rps, PayType]
            ),
            case Rps of
                undefined -> fun_throttle:unset_rps(CustomerId);
                _         -> fun_throttle:set_rps(CustomerId, Rps)
            end,
            Src = case Source of
                      #addr{addr = A, ton = T, npi = N} ->
                          {A, T, N};
                      undefined ->
                          undefined
                  end,
            SysId = funnel_conf:get(smpp_server_system_id),
            Allowed2 = [ bstr:lower(Ad) || #addr{addr = Ad} <- Allowed ],
            Reply = {ok, [{system_id, SysId}],
                         [{uuid, UUID},
                          {priority, Priority},
                          {allowed_sources, Allowed2},
                          {default_source, Src},
                          {networks, Networks},
                          {providers, Providers},
                          {default_provider_id, DefaultProvId},
                          {receipts_allowed, ReceptsAllowed},
                          {no_retry, NoRetry},
                          {default_validity, DefaultValidity},
                          {max_validity, MaxValidity},
                          {pay_type, PayType},
                          {features, Features}]
                    },
            Node2 = Node#node{
                state = bound,
                bind_ref = undefined
            },
            {reply, Reply, St#st{nodes = [Node2|Nodes]}};
        _ ->
            {noreply, St}
    end.

handle_basic_deliver(<<"DisconnectRequest">>, Payload, Props, St) ->
    {ok, DisconnectRequest} = 'FunnelAsn':decode('DisconnectRequest', Payload),
    #'DisconnectRequest'{
        customerId   = CustomerId,
        userId       = UserId,
        connectionId = ConnectionId
    } = DisconnectRequest,
    UserNodes =
        [ N || #node{customer_id = CId, user_id = UId} = N <- St#st.nodes,
            CId =:= CustomerId, UId =:= UserId ],
    Nodes =
        case ConnectionId of
            asn1_NOVALUE ->
                UserNodes;
            _ ->
                case lists:keyfind(ConnectionId, #node.uuid, UserNodes) of
                    false -> [];
                    N     -> [N]
                end
        end,
    lists:foreach(
        fun(#node{uuid = UUID, pid = Pid}) ->
            fun_smpp_node:unbind(Pid),
            ?log_info(
                "Server: unbinding a client "
                "(uuid: ~s, customer: ~s, user: ~s)",
                [UUID, CustomerId, UserId]
            )
        end, Nodes
    ),
    Response = #'DisconnectResponse'{},
    {ok, RespPayload} = 'FunnelAsn':encode('DisconnectResponse', Response),
    #'P_basic'{message_id = MsgId, reply_to = ReplyTo} = Props,
    RespProps = #'P_basic'{
        content_type   = <<"DisconnectResponse">>,
        correlation_id = MsgId,
        message_id     = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, ReplyTo, RespPayload, RespProps),
    {noreply, St};

handle_basic_deliver(<<"ConnectionsRequest">>, _Payload, Props, St) ->
    ?log_debug("Server: got connections request", []),
    Connections =
        [
            try
                {In, Out} = fun_throughput:totals(N#node.uuid),
                Errors =
                    lists:map(
                        fun({TS, Error}) ->
                                #'Error'{errorCode = Error, timestamp = TS}
                        end, fun_errors:lookup(N#node.uuid)
                    ),
                #'Connection'{connectionId = N#node.uuid,
                              remoteIp = N#node.addr,
                              customerId = N#node.customer_id,
                              userId = N#node.user_id,
                              connectedAt = fun_time:utc_str(N#node.connected_at),
                              type = N#node.type,
                              msgsReceived = Out,
                              msgsSent = In,
                              errors = Errors}
            catch
                _:_ -> []
            end || #node{state = bound} = N <- St#st.nodes ],
    ConnectionsResponse = #'ConnectionsResponse'{
        connections = lists:keysort(
            #node.connected_at, lists:flatten(Connections)
        )
    },
    {ok, RespPayload} =
        'FunnelAsn':encode('ConnectionsResponse', ConnectionsResponse),
    #'P_basic'{message_id = MsgId, reply_to = ReplyTo} = Props,
    RespProps = #'P_basic'{
        content_type   = <<"ConnectionsResponse">>,
        correlation_id = MsgId,
        message_id     = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, ReplyTo, RespPayload, RespProps),
    {noreply, St};

handle_basic_deliver(<<"ThroughputRequest">>, _Payload, Props, St) ->
    ?log_debug("Server: got throughput request", []),
    Slices = lists:map(
        fun({PeriodStart, Counters}) ->
                #'Slice'{
                    periodStart = PeriodStart,
                    counters    =
                        lists:map(
                            fun({ConnectionId, Direction, Count}) ->
                                    #'Counter'{
                                        connectionId = ConnectionId,
                                        direction    = Direction,
                                        count        = Count
                                    }
                            end, Counters
                        )
                }
        end, fun_throughput:slices()
    ),
    Response = #'ThroughputResponse'{slices = Slices},
    {ok, RespPayload} = 'FunnelAsn':encode('ThroughputResponse', Response),
    #'P_basic'{message_id = MsgId, reply_to = ReplyTo} = Props,
    RespProps = #'P_basic'{
        content_type   = <<"ThroughputResponse">>,
        correlation_id = MsgId,
        message_id     = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, ReplyTo, RespPayload, RespProps),
    {noreply, St};

handle_basic_deliver(<<"ConnectionsReqV1">>, ReqBin, Props, St) ->
    {ok, Req = #connections_req_v1{req_id = ReqId}} =
        adto:decode(#connections_req_v1{}, ReqBin),
    ?log_debug("Server: got ~p", [Req]),
    Conns = [build_connection_v1(N) || #node{state = bound} = N <- St#st.nodes],
    Resp = #connections_resp_v1{
        req_id = ReqId,
        connections = lists:keysort(#connection_v1.connected_at, Conns)
    },
    {ok, RespBin} = adto:encode(Resp),
    #'P_basic'{message_id = MsgId, reply_to = ReplyTo} = Props,
    RespProps = #'P_basic'{
        content_type   = <<"ConnectionsRespV1">>,
        correlation_id = MsgId,
        message_id     = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, ReplyTo, RespBin, RespProps),
    {noreply, St};

handle_basic_deliver(<<"DisconnectReqV1">>, ReqBin, Props, St) ->
    {ok, Req = #disconnect_req_v1{req_id = ReqId}} =
        adto:decode(#disconnect_req_v1{}, ReqBin),
    ?log_debug("Server: got ~p", [Req]),
    #disconnect_req_v1{
        customer_id   = CustomerId,
        user_id       = UserId,
        bind_type     = BindType,
        connection_id = ConnectionId
    } = Req,
    ChkCust = fun(undefined, _) -> true;
                 (CID, N) -> N#node.customer_id =:= binary_to_list(CID)
              end,
    ChkUser = fun(undefined, _) -> true;
                 (UID, N) -> N#node.user_id =:= binary_to_list(UID)
              end,
    ChkType = fun(undefined, _) -> true;
                 (Type, N) when is_atom(Type) ->
                    N#node.type =:= Type;
                 (Types, N) when is_list(Types) ->
                    lists:member(N#node.type, Types)
              end,
    ChkConn = fun(undefined, _) -> true;
                 (CID, N) when is_binary(CID) ->
                    N#node.uuid =:= binary_to_list(CID);
                 (CIDs, N) when is_list(CIDs) ->
                    lists:member(list_to_binary(N#node.uuid), CIDs)
              end,
    Nodes = [
        N || N <- St#st.nodes,
        ChkCust(CustomerId, N) andalso
        ChkUser(UserId, N) andalso
        ChkType(BindType, N) andalso
        ChkConn(ConnectionId, N)
    ],
    lists:foreach(
        fun(#node{uuid = UUID, pid = Pid, customer_id = CID, user_id = UID}) ->
            fun_smpp_node:unbind(Pid),
            ?log_info(
                "Server: unbinding a client "
                "(uuid: ~s, customer: ~s, user: ~s)",
                [UUID, CID, UID]
            )
        end, Nodes
    ),
    Resp = #disconnect_resp_v1{
        req_id = ReqId
    },
    {ok, RespBin} = adto:encode(Resp),
    #'P_basic'{message_id = MsgId, reply_to = ReplyTo} = Props,
    RespProps = #'P_basic'{
        content_type   = <<"DisconnectRespV1">>,
        correlation_id = MsgId,
        message_id     = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, ReplyTo, RespBin, RespProps),
    {noreply, St};

handle_basic_deliver(<<"ThroughputReqV1">>, ReqBin, Props, St) ->
    {ok, Req = #throughput_req_v1{req_id = ReqId}} =
        adto:decode(#throughput_req_v1{}, ReqBin),
    ?log_debug("Server: got ~p", [Req]),
    Slices = lists:map(
        fun({PeriodStart, Counters}) ->
            #throughput_slice_v1{
                period_start = ac_datetime:utc_string_to_timestamp(PeriodStart),
                counters = lists:map(fun({ConnectionId, Direction, Count}) ->
                    #throughput_counter_v1{
                        connection_id = list_to_binary(ConnectionId),
                        direction = Direction,
                        count = Count
                    }
                end, Counters)
            }
        end, fun_throughput:slices()
    ),
    Resp = #throughput_resp_v1{
        req_id = ReqId,
        slices = Slices
    },
    {ok, RespBin} = adto:encode(Resp),
    #'P_basic'{message_id = MsgId, reply_to = ReplyTo} = Props,
    RespProps = #'P_basic'{
        content_type   = <<"ThroughputRespV1">>,
        correlation_id = MsgId,
        message_id     = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, ReplyTo, RespBin, RespProps),
    {noreply, St}.

build_connection_v1(Node) ->
    {In, Out} = fun_throughput:totals(Node#node.uuid),
    Errors = lists:map(fun({TS, Error}) ->
        #connection_error_v1{
            error_code = Error,
            timestamp = ac_datetime:utc_string_to_timestamp(TS)
        }
        end, fun_errors:lookup(Node#node.uuid)),
    ConnectedAtUTC =
        case calendar:local_time_to_universal_time_dst(Node#node.connected_at) of
            [_DstDateTimeUTC, DateTimeUTC] ->
                DateTimeUTC;
            [DateTimeUTC] ->
                DateTimeUTC
        end,
    {ok, RemoteIP} = inet:parse_address(Node#node.addr),
    #connection_v1{
        connection_id = list_to_binary(Node#node.uuid),
        remote_ip = RemoteIP,
        customer_id = list_to_binary(Node#node.customer_id),
        user_id = list_to_binary(Node#node.user_id),
        connected_at = ac_datetime:datetime_to_timestamp(ConnectedAtUTC),
        bind_type = Node#node.type,
        msgs_received = Out,
        msgs_sent = In,
        errors = Errors
    }.

notify_backend_server_up(Chan) ->
    ServerUpEvent = #'ServerUpEvent'{
        timestamp = fun_time:utc_str()
    },
    {ok, Payload} = 'FunnelAsn':encode('ServerUpEvent', ServerUpEvent),
    RoutingKey = funnel_app:get_env(queue_backend_events),
    Props = #'P_basic'{
        content_type = <<"ServerUpEvent">>,
        message_id   = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(Chan, RoutingKey, Payload, Props).

notify_backend_server_down(Chan) ->
    ServerDownEvent = #'ServerDownEvent'{
        timestamp = fun_time:utc_str()
    },
    {ok, Payload} = 'FunnelAsn':encode('ServerDownEvent', ServerDownEvent),
    RoutingKey = funnel_app:get_env(queue_backend_events),
    Props = #'P_basic'{
        content_type = <<"ServerDownEvent">>,
        message_id   = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(Chan, RoutingKey, Payload, Props).

%% notify_backend_connection_up(Chan, UUID, CustomerId, UserId, Type, ConnectedAt) ->
%%     ConnectionUpEvent = #'ConnectionUpEvent'{
%%         connectionId = UUID,
%%         customerId   = CustomerId,
%%         userId       = UserId,
%%         type         = Type,
%%         connectedAt  = fun_time:utc_str(ConnectedAt),
%%         timestamp    = fun_time:utc_str()
%%     },
%%     {ok, Payload} =
%%         'FunnelAsn':encode('ConnectionUpEvent', ConnectionUpEvent),
%%     RoutingKey = funnel_app:get_env(queue_backend_events),
%%     Props = #'P_basic'{
%%         content_type = <<"ConnectionUpEvent">>,
%%         message_id   = uuid:unparse(uuid:generate())
%%     },
%%     fun_amqp:basic_publish(Chan, RoutingKey, Payload, Props).

notify_backend_connection_down(Chan, UUID, CustomerId, UserId, Type,
        ConnectedAt, MsgsReceived, MsgsSent, Errors, Reason) ->
    ConnectionDownEvent = #'ConnectionDownEvent'{
        connectionId = UUID,
        customerId   = CustomerId,
        userId       = UserId,
        type         = Type,
        connectedAt  = fun_time:utc_str(ConnectedAt),
        msgsReceived = MsgsReceived,
        msgsSent     = MsgsSent,
        errors       =
            lists:map(
                fun({TS, Error}) ->
                    #'Error'{errorCode = Error, timestamp = TS}
                end, Errors
            ),
        reason       = Reason,
        timestamp    = fun_time:utc_str()
    },
    {ok, Payload} =
        'FunnelAsn':encode('ConnectionDownEvent', ConnectionDownEvent),
    RoutingKey = funnel_app:get_env(queue_backend_events),
    Props = #'P_basic'{
        content_type = <<"ConnectionDownEvent">>,
        message_id   = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(Chan, RoutingKey, Payload, Props).
