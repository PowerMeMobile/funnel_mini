-module(fun_amqp).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([connection_start/0, connection_close/1]).
-export([channel_open/1, channel_close/1]).
-export([queue_declare/5]).
-export([basic_qos/2, basic_consume/3, basic_cancel/2]).
-export([basic_publish/4, basic_ack/2, basic_reject/3]).
-export([tx_select/1, tx_commit/1]).

%% -------------------------------------------------------------------------
%% Connection methods
%% -------------------------------------------------------------------------

-spec connection_start() -> {'ok', pid()} | {'error', any()}.
connection_start() ->
    amqp_connection:start(#amqp_params_network{
        username = funnel_app:get_env(amqp_username),
        password = funnel_app:get_env(amqp_password),
        host = funnel_app:get_env(amqp_host),
        port = funnel_app:get_env(amqp_port),
        virtual_host = funnel_app:get_env(amqp_virtual_host)
    }).

-spec connection_close(pid()) -> 'ok'.
connection_close(Conn) ->
    catch(amqp_connection:close(Conn)),
    ok.

%% -------------------------------------------------------------------------
%% Channel methods
%% -------------------------------------------------------------------------

-spec channel_open(pid()) -> {'ok', pid()} | {'error', any()}.
channel_open(Conn) ->
    amqp_connection:open_channel(Conn).

-spec channel_close(pid()) -> 'ok'.
channel_close(Chan) ->
    catch(amqp_channel:close(Chan)),
    ok.

%% -------------------------------------------------------------------------
%% Queue methods
%% -------------------------------------------------------------------------

-spec queue_declare(pid(), binary(), boolean(), boolean(), boolean()) ->
                    'ok' | {'error', any()}.
queue_declare(Chan, Queue, Durable, Exclusive, AutoDelete) ->
    Method = #'queue.declare'{queue = Queue,
                              durable = Durable,
                              exclusive = Exclusive,
                              auto_delete = AutoDelete},
    try amqp_channel:call(Chan, Method) of
        #'queue.declare_ok'{} -> ok;
        Other                 -> {error, Other}
    catch
        _:Reason -> {error, Reason}
    end.

%% -------------------------------------------------------------------------
%% Basic methods
%% -------------------------------------------------------------------------

-spec basic_qos(pid(), non_neg_integer()) -> 'ok' | {'error', any()}.
basic_qos(Chan, PrefetchCount) ->
    Method = #'basic.qos'{prefetch_count = PrefetchCount},
    try amqp_channel:call(Chan, Method) of
        #'basic.qos_ok'{} -> ok;
        Other             -> {error, Other}
    catch
        _:Reason -> {error, Reason}
    end.

-spec basic_consume(pid(), binary(), boolean()) ->
                    {'ok', binary()} | {'error', any()}.
basic_consume(Chan, Queue, NoAck) ->
    Method = #'basic.consume'{queue = Queue, no_ack = NoAck},
    try
        amqp_channel:subscribe(Chan, Method, self()),
        receive
            #'basic.consume_ok'{consumer_tag = ConsumerTag} ->
                {ok, ConsumerTag}
        after
            10000 -> {error, timeout}
        end
    catch
        _:Reason -> {error, Reason}
    end.

-spec basic_cancel(pid(), binary()) -> 'ok' | {'error', any()}.
basic_cancel(Chan, ConsumerTag) ->
    Method = #'basic.cancel'{consumer_tag = ConsumerTag},
    try
        amqp_channel:call(Chan, Method),
        receive
            #'basic.cancel_ok'{consumer_tag = ConsumerTag} -> ok
        after
            10000 -> {error, timeout}
        end
    catch
        _:Reason -> {error, Reason}
    end.

-spec basic_publish(pid(), binary(), binary(), #'P_basic'{}) ->
                    'ok' | {'error', any()}.
basic_publish(Chan, RoutingKey, Payload, Props) ->
    Method = #'basic.publish'{routing_key = RoutingKey},
    Content = #amqp_msg{payload = Payload, props = Props},
    try amqp_channel:call(Chan, Method, Content) of
        ok    -> ok;
        Other -> {error, Other}
    catch
        _:Reason -> {error, Reason}
    end.

-spec basic_ack(pid(), non_neg_integer()) -> 'ok' | {'error', any()}.
basic_ack(Chan, DeliveryTag) ->
    Method = #'basic.ack'{delivery_tag = DeliveryTag},
    try amqp_channel:call(Chan, Method) of
        ok    -> ok;
        Other -> {error, Other}
    catch
        _:Reason -> {error, Reason}
    end.

-spec basic_reject(pid(), non_neg_integer(), boolean()) ->
    'ok' | {'error', any()}.
basic_reject(Chan, DeliveryTag, Requeue) ->
    Method = #'basic.reject'{delivery_tag = DeliveryTag, requeue = Requeue},
    try amqp_channel:call(Chan, Method) of
        ok    -> ok;
        Other -> {error, Other}
    catch
        _:Reason -> {error, Reason}
    end.

%% -------------------------------------------------------------------------
%% Tx methods
%% -------------------------------------------------------------------------

-spec tx_select(pid()) -> 'ok' | {'error', any()}.
tx_select(Chan) ->
    Method = #'tx.select'{},
    try amqp_channel:call(Chan, Method) of
        #'tx.select_ok'{} -> ok;
        Other             -> {error, Other}
    catch
        _:Reason -> {error, Reason}
    end.

-spec tx_commit(pid()) -> 'ok' | {'error', any()}.
tx_commit(Chan) ->
    Method = #'tx.commit'{},
    try amqp_channel:call(Chan, Method) of
        #'tx.commit_ok'{} -> ok;
        Other             -> {error, Other}
    catch
        _:Reason -> {error, Reason}
    end.
