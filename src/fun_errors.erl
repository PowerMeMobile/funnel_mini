-module(fun_errors).


-include("otp_records.hrl").


-behaviour(gen_server).


%% API exports
-export([start_link/0,
         register_connection/2,
         record/2,
         lookup/1]).


%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).


-define(N_ERRORS_TO_STORE, 1000).


-record(st, {errors_tab :: ets:tid(), monitors_tab :: ets:tid()}).


%% -------------------------------------------------------------------------
%% API functions
%% -------------------------------------------------------------------------


-spec start_link/0 :: () -> {'ok', pid()} | 'ignore' | {'error', any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-spec register_connection/2 :: (string(), pid()) -> 'ok'.

register_connection(ConnectionId, Pid) ->
    gen_server:call(?MODULE, {register_connection, ConnectionId, Pid}, infinity).


-spec record/2 :: (string(), pos_integer()) -> 'ok'.

record(ConnectionId, Error) ->
    TS = fun_time:utc_str(),
    gen_server:cast(?MODULE, {record, ConnectionId, Error, TS}).


-spec lookup/1 :: (string()) -> [{TS :: string(), Error :: pos_integer()}].

lookup(ConnectionId) ->
    gen_server:call(?MODULE, {lookup, ConnectionId}, infinity).


%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------


init([]) ->
    process_flag(trap_exit, true),
    lager:info("Errors: initializing"),
    {ok, #st{
        errors_tab   = ets:new(errors_tab, []),
        monitors_tab = ets:new(monitors_tab, [])
    }}.


terminate(Reason, St) ->
    ets:delete(St#st.monitors_tab),
    ets:delete(St#st.errors_tab),
    lager:info("Errors: terminated (~p)", [Reason]).


handle_call({register_connection, ConnectionId, Pid}, _From, St) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(St#st.monitors_tab, {Ref, ConnectionId}),
    {reply, ok, St};


handle_call({lookup, ConnectionId}, _From, St) ->
    case ets:lookup(St#st.errors_tab, ConnectionId) of
        [{_, Errors}] -> {reply, lists:reverse(Errors), St};
        []            -> {reply, [], St}
    end.


handle_cast({record, ConnectionId, Error, TS}, St) ->
    case ets:lookup(St#st.errors_tab, ConnectionId) of
        [{ConnectionId, Errors_}] ->
            Errors = lists:sublist([{TS, Error}|Errors_], ?N_ERRORS_TO_STORE),
            ets:insert(St#st.errors_tab, {ConnectionId, Errors});
        [] ->
            ets:insert(St#st.errors_tab, {ConnectionId, [{TS, Error}]})
    end,
    {noreply, St}.


handle_info(#'DOWN'{ref = Ref}, St) ->
    [{Ref, ConnectionId}] = ets:lookup(St#st.monitors_tab, Ref),
    ets:delete(St#st.monitors_tab, Ref),
    ets:delete(St#st.errors_tab, ConnectionId),
    {noreply, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.
