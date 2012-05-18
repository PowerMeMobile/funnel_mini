-module(fun_throughput).


-include("otp_records.hrl").


-behaviour(gen_server).


%% API exports
-export([start_link/0,
         register_connection/2,
         in/1,
         out/1,
         totals/1,
         slices/0]).


%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).


-define(N_SLICES_TO_STORE, 360).


-type counter() :: {{string(), 'in' | 'out'}, pos_integer()}.


-record(slice, {key, counters = [] :: [counter()]}).
-record(st, {slices = []  :: [#slice{}],
             totals_tab   :: ets:tid(),
             monitors_tab :: ets:tid()}).


%% -------------------------------------------------------------------------
%% API functions
%% -------------------------------------------------------------------------


-spec start_link/0 :: () -> {'ok', pid()} | 'ignore' | {'error', any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-spec register_connection/2 :: (string(), pid()) -> 'ok'.

register_connection(ConnectionId, Pid) ->
    gen_server:call(?MODULE, {register_connection, ConnectionId, Pid}, infinity).


-spec in/1 :: (string()) -> 'ok'.

in(ConnectionId) ->
    gen_server:cast(?MODULE, {incr, ConnectionId, in}).


-spec out/1 :: (string()) -> 'ok'.

out(ConnectionId) ->
    gen_server:cast(?MODULE, {incr, ConnectionId, out}).


-spec totals/1 :: (string()) -> {non_neg_integer(), non_neg_integer()}.

totals(ConnectionId) ->
    gen_server:call(?MODULE, {totals, ConnectionId}, infinity).


-spec slices/0 :: () -> list().

slices() ->
    gen_server:call(?MODULE, slices, infinity).


%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------


init([]) ->
    process_flag(trap_exit, true),
    log4erl:info("throughput: initializing"),
    Totals = ets:new(totals_tab, []),
    ets:insert(Totals, {in,  0}),
    ets:insert(Totals, {out, 0}),
    {ok, #st{totals_tab = Totals, monitors_tab = ets:new(monitors_tab, [])}}.


terminate(Reason, St) ->
    ets:delete(St#st.monitors_tab),
    ets:delete(St#st.totals_tab),
    log4erl:info("throughput: terminated (~W)", [Reason, 20]).


handle_call({register_connection, ConnectionId, Pid}, _From, St) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(St#st.monitors_tab, {Ref, ConnectionId}),
    ets:insert(St#st.totals_tab, {{ConnectionId, in},  0}),
    ets:insert(St#st.totals_tab, {{ConnectionId, out}, 0}),
    {reply, ok, St};


handle_call({totals, ConnectionId}, _From, St) ->
    In =
        case ets:lookup(St#st.totals_tab, {ConnectionId, in}) of
            [{_, In_}] -> In_;
            []         -> 0
        end,
    Out =
        case ets:lookup(St#st.totals_tab, {ConnectionId, out}) of
            [{_, Out_}] -> Out_;
            []          -> 0
        end,
    {reply, {In, Out}, St};


handle_call(slices, _From, St) ->
    Reply =
        lists:map(
            fun(#slice{key = Key, counters = Counters}) ->
                    {Y, Mon, D, H, Min, SDiv10} = Key,
                    {
                        fun_time:utc_str({{Y, Mon, D}, {H, Min, SDiv10 * 10}}),
                        lists:map(
                            fun({{ConnectionId, Direction}, Count}) ->
                                    {ConnectionId, Direction, Count}
                            end, lists:sort(Counters)
                        )
                    }
            end, lists:reverse(St#st.slices)
        ),
    {reply, Reply, St}.


handle_cast({incr, ConnectionId, Direction}, St) ->
    Sig = {ConnectionId, Direction},
    ets:update_counter(St#st.totals_tab, Direction, 1),
    ets:update_counter(St#st.totals_tab, Sig, 1),
    Key = key(calendar:universal_time()),
    {H, T} =
        case St#st.slices of
            [#slice{key = Key} = S|Ss] -> {S, Ss};
            Ss                         -> {#slice{key = Key}, Ss}
        end,
    Counters =
        case lists:keytake(Sig, 1, H#slice.counters) of
            {value, {_, N}, Counters_} -> [{Sig, N + 1}|Counters_];
            false                      -> [{Sig, 1}|H#slice.counters]
        end,
    Cutoff =
        if
            length(T) > ?N_SLICES_TO_STORE ->
                lists:sublist(T, ?N_SLICES_TO_STORE);
            true ->
                T
        end,
    {noreply, St#st{slices = [H#slice{counters = Counters}|Cutoff]}}.


handle_info(#'DOWN'{ref = Ref}, St) ->
    [{Ref, ConnectionId}] = ets:lookup(St#st.monitors_tab, Ref),
    ets:delete(St#st.monitors_tab, Ref),
    ets:delete(St#st.totals_tab, {ConnectionId, in}),
    ets:delete(St#st.totals_tab, {ConnectionId, out}),
    {noreply, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.


%% -------------------------------------------------------------------------
%% Private functions
%% -------------------------------------------------------------------------


key({{Y, Mon, D}, {H, Min, S}}) ->
    {Y, Mon, D, H, Min, S div 10}.
