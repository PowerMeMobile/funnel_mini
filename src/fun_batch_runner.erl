-module(fun_batch_runner).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("alley_dto/include/FunnelAsn.hrl").
-include("otp_records.hrl").

-behaviour(gen_server2).

%% API exports
-export([start_link/1, stop/1]).

%% gen_server2 exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         prioritise_cast/2]).

-record(st, {amqp_chan :: pid(), node :: pid(), version :: 16#33 | 16#34 | 16#50}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec start_link(list()) -> {'ok', pid()} | 'ignore' | {'error', any()}.
start_link(Params) ->
    gen_server2:start_link(?MODULE, Params, []).

-spec stop(pid()) -> 'ok'.
stop(Pid) ->
    gen_server2:cast(Pid, stop).

%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------

init(Params) ->
    process_flag(trap_exit, true),
    log4erl:debug("runner: initializing"),
    ConnId = proplists:get_value(connection_id, Params),
    Chan = fun_amqp_pool:open_channel(),
    monitor(process, Chan),
    ok = fun_amqp:basic_qos(Chan, 1),
    Prefix = funnel_app:get_env(queue_nodes_prefix),
    Queue = list_to_binary([Prefix, lists:concat([".", string:to_lower(ConnId)])]),
    ok = fun_amqp:queue_declare(Chan, Queue, false, true, true),
    {ok, _CTag} = fun_amqp:basic_consume(Chan, Queue, false),
    {ok, #st{amqp_chan = Chan,
             node = proplists:get_value(node, Params),
             version = proplists:get_value(version, Params)}}.

terminate(Reason, St) ->
    log4erl:debug("runner: terminated (~W)", [Reason, 20]),
    fun_amqp_pool:close_channel(St#st.amqp_chan).

handle_call(Request, _From, St) ->
    {stop, {unexpected_call, Request}, St}.

handle_cast(stop, St) ->
    {stop, normal, St}.

%% receive an gunzip payload if needed.
handle_info({#'basic.deliver'{delivery_tag = Tag},
        #amqp_msg{payload = Payload, props = Props}}, St) ->
    try handle_basic_deliver(Payload, Props, Tag, St) of
        ok ->
            {noreply, St};
        error ->
            {stop, error, St}
    catch
        _:Reason ->
            log4erl:error("runner: rejected a batch (~W)", [Reason, 20]),
            fun_amqp:basic_reject(St#st.amqp_chan, Tag, false),
            {noreply, St}
    end;

handle_info(#'DOWN'{pid = Pid}, #st{amqp_chan = Pid} = St) ->
    {stop, amqp_down, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

prioritise_cast(Msg, _St) ->
    case Msg of
        stop -> 9;
        _    -> 0
    end.

%% -------------------------------------------------------------------------
%% handle basic_deliver
%% -------------------------------------------------------------------------

handle_basic_deliver(Payload, Props, Tag, St) ->
    Gunzipped =
        case Props#'P_basic'.content_encoding of
            <<"gzip">> -> zlib:gunzip(Payload);
            _          -> Payload
        end,
    Type =
        case Props#'P_basic'.content_type of
            <<"OutgoingBatch">> -> generic;
            <<"ReceiptBatch">>  -> receipts
        end,
    {ID, AllItems} =
        case Type of
            generic ->
                {ok, Str} = 'FunnelAsn':outgoing_batch_id(Gunzipped),
                {ok, #'OutgoingBatch'{messages = {'OutgoingBatch_messages', Its}}} =
                    'FunnelAsn':outgoing_batch_messages(Gunzipped),
                {Str, Its};
            receipts ->
                {ok, Str} = 'FunnelAsn':receipt_batch_id(Gunzipped),
                {ok, #'ReceiptBatch'{receipts = {'ReceiptBatch_receipts', Its}}} =
                    'FunnelAsn':receipt_batch_messages(Gunzipped),
                {Str, Its}
        end,
    log4erl:debug("got batch (type: ~s, id: ~s)", [Type, ID]),
    MsgId   = Props#'P_basic'.message_id,
    ReplyTo = Props#'P_basic'.reply_to,
    Done = fun_batch_cursor:read(ID),
    Items = lists:nthtail(Done, AllItems),
    case make_requests(Type, ID, Done, Items, St) of
        ok ->
            respond_and_ack(ID, Tag, MsgId, ReplyTo, St),
            ok;
        error ->
            error
    end.

%% -------------------------------------------------------------------------
%% execute request
%% -------------------------------------------------------------------------

make_requests(Type, ID, Done, Items, St) ->
    Reqs = lists:flatten([ make_request(Type, Item, St) || Item <- Items ]),
    case collect_replies(length(Reqs)) of
        ok ->
            fun_batch_cursor:write(ID, Done + length(Items)),
            ok;
        error ->
            error
    end.

collect_replies(0) ->
    ok;
collect_replies(N) ->
    Timeout = funnel_conf:get(response_time),
    receive
        {smpp_node_reply, _} ->
            collect_replies(N - 1)
    after
        Timeout ->
            error
    end.

make_request(generic, Item, St) ->
    {ok, #'OutgoingMessage'{
        source     = Source,
        dest       = Dest,
        message    = Message,
        dataCoding = DataCoding
    }} = 'FunnelAsn':decode('OutgoingMessage', Item),
    #'Addr'{addr = SAddr, ton = STon, npi = SNpi} = Source,
    #'Addr'{addr = DAddr, ton = DTon, npi = DNpi} = Dest,
    CommonParams = [
        {source_addr_ton,  STon},
        {source_addr_npi,  SNpi},
        {source_addr,      SAddr},
        {dest_addr_ton,    DTon},
        {dest_addr_npi,    DNpi},
        {destination_addr, DAddr},
        {data_coding,      int_data_coding(DataCoding)}
    ],
    Msgs = split_msg(encode_msg(list_to_binary(Message), DataCoding), DataCoding),
    lists:map(
        fun(Params) -> fun_smpp_node:deliver_sm(St#st.node, Params) end,
        complete_smpp_parts(CommonParams, Msgs, St#st.version)
    );

make_request(receipts, Item, St) ->
    {ok, #'DeliveryReceipt'{
        messageId    = MessageId,
        submitDate   = SubmitDate,
        doneDate     = DoneDate,
        messageState = State,
        source       = Source,
        dest         = Dest
    }} = 'FunnelAsn':decode('DeliveryReceipt', Item),
    #'Addr'{addr = SAddr, ton = STon, npi = SNpi} = Source,
    #'Addr'{addr = DAddr, ton = DTon, npi = DNpi} = Dest,
    Text = lists:concat([
        "id:",           MessageId,
        " submit date:", lists:sublist(SubmitDate, 10),
        " done date:",   lists:sublist(DoneDate, 10),
        " stat:",        text_state(State)
    ]),
    Params33 = [
        {source_addr_ton,  STon},
        {source_addr_npi,  SNpi},
        {source_addr,      SAddr},
        {dest_addr_ton,    DTon},
        {dest_addr_npi,    DNpi},
        {destination_addr, DAddr},
        {data_coding,      0},
        {short_message,    Text},
        {esm_class,        4}
    ],
    Params =
        case St#st.version of
            16#33 ->
                Params33;
            _ ->
                [
                    {receipted_message_id, MessageId},
                    {message_state,        int_state(State)}
                | Params33 ]
        end,
    [ fun_smpp_node:deliver_sm(St#st.node, Params)].

respond_and_ack(ID, Tag, MsgId, ReplyTo, St) ->
    {ok, Encoded} =
        'FunnelAsn':encode('BatchAck', #'BatchAck'{batchId = ID}),
    RespPayload = list_to_binary(Encoded),
    RespProps = #'P_basic'{
        content_type   = <<"BatchAck">>,
        correlation_id = MsgId,
        message_id     = uuid:unparse(uuid:generate())
    },
    fun_amqp:basic_publish(St#st.amqp_chan, ReplyTo, RespPayload, RespProps),
    fun_amqp:basic_ack(St#st.amqp_chan, Tag).

encode_msg(Msg, {text, gsm0338}) ->
    {_Validity, Encoded} = gsm0338:from_utf8(Msg),
    Encoded;
encode_msg(Msg, {text, ucs2}) ->
    {ok, Encoded} = iconverl:conv("ucs-2be//IGNORE", "utf-8", Msg),
    Encoded;
encode_msg(Msg, {other, _}) ->
    Msg.

int_data_coding({text, gsm0338}) -> 0;
int_data_coding({text, ucs2})    -> 8;
int_data_coding({other, DC})     -> DC.

split_msg(Msg, Enc) ->
    case {size(Msg), Enc} of
        {Size, {text, gsm0338}} when Size > 160 ->
            fun_binary:split(Msg, 153);
        {Size, {text, ucs2}} when Size > 140 ->
            fun_binary:split(Msg, 134);
        {Size, {other, _DC}} when Size > 140 ->
            fun_binary:split(Msg, 134);
        _ ->
            [Msg]
    end.

complete_smpp_parts(Params, [Part], _Interface) ->
    [[{short_message, binary_to_list(Part)}|Params]];

complete_smpp_parts(Params, Parts, Interface) ->
    RefNum = erlang:phash(Parts, 255),
    lists:map(
        fun({Part, Index}) ->
                M = binary_to_list(Part),
                case Interface of
                    16#33 ->
                        SM = [5, 0, 3, RefNum, length(Parts), Index|M],
                        [{short_message, SM}, {esm_class, 64}|Params];
                    _ ->
                        [
                            {short_message,      M},
                            {sar_msg_ref_num,    RefNum},
                            {sar_total_segments, length(Parts)},
                            {sar_segment_seqnum, Index}|
                            Params
                        ]
                end
        end,
        lists:zip(Parts, lists:seq(1, length(Parts)))
    ).

%% -------------------------------------------------------------------------
%% receipt states
%% -------------------------------------------------------------------------

text_state(delivered)     -> "DELIVRD";
text_state(expired)       -> "EXPIRED";
text_state(deleted)       -> "DELETED";
text_state(undeliverable) -> "UNDELIV";
text_state(accepted)      -> "ACCEPTD";
text_state(unknown)       -> "UNKNOWN";
text_state(rejected)      -> "REJECTD".

int_state(delivered)     -> 2;
int_state(expired)       -> 3;
int_state(deleted)       -> 4;
int_state(undeliverable) -> 5;
int_state(accepted)      -> 6;
int_state(unknown)       -> 7;
int_state(rejected)      -> 8.
