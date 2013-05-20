-module(fun_amqp_pool).

-include("otp_records.hrl").

-behaviour(gen_server).

%% API exports
-export([start_link/0,
         open_channel/0,
         close_channel/1]).

%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

-record(st, {amqp_conn :: pid(), amqp_chans :: ets:tid()}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec start_link() -> {'ok', pid()} | 'ignore' | {'error', any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec open_channel() -> pid().
open_channel() ->
    gen_server:call(?MODULE, open_channel, infinity).

-spec close_channel(pid()) -> no_return().
close_channel(Chan) ->
    gen_server:cast(?MODULE, {close_channel, Chan}).

%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    lager:info("amqp pool: initializing"),
    case fun_amqp:connection_start() of
        {ok, Conn} ->
            link(Conn),
            {ok, #st{amqp_conn = Conn, amqp_chans = ets:new(amqp_chans, [])}};
        {error, Reason} ->
            lager:error("amqp pool: failed to start (~p)", [Reason]),
            {stop, Reason}
    end.

terminate(Reason, St) ->
    [ fun_amqp:channel_close(Pid) ||
        {_Ref, Pid} <- ets:tab2list(St#st.amqp_chans) ],
    ets:delete(St#st.amqp_chans),
    fun_amqp:connection_close(St#st.amqp_conn),
    lager:info("amqp pool: terminated (~p)", [Reason]).

handle_call(open_channel, {Pid, _Tag}, St) ->
    case fun_amqp:channel_open(St#st.amqp_conn) of
        {ok, Chan} ->
            Ref = monitor(process, Pid),
            ets:insert(St#st.amqp_chans, {Ref, Chan}),
            {reply, Chan, St};
        {error, Reason} ->
            {stop, Reason, St}
    end.

handle_cast({close_channel, Chan}, St) ->
    case ets:match(St#st.amqp_chans, {'$1', Chan}) of
        [[Ref]] ->
            demonitor(Ref),
            fun_amqp:channel_close(Chan),
            ets:delete(St#st.amqp_chans, Ref);
        [] ->
            ignore
    end,
    {noreply, St}.

handle_info(#'EXIT'{pid = Pid}, #st{amqp_conn = Pid} = St) ->
    {stop, amqp_down, St};

handle_info(#'DOWN'{ref = Ref}, St) ->
    case ets:lookup(St#st.amqp_chans, Ref) of
        [{_, Chan}] ->
            fun_amqp:channel_close(Chan),
            ets:delete(St#st.amqp_chans, Ref);
        [] ->
            ignore
    end,
    {noreply, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.
