-module(fun_throttle).

-behaviour(gen_server).

%% client exports
-export([start_link/0,
         set_rps/2,
         unset_rps/1,
         is_allowed/1]).

%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

-record(st, {period             :: {integer(), integer(), integer()},
             total_used = 0     :: non_neg_integer(),
             total_max          :: pos_integer(),
             customers_used_tab :: ets:tid(),
             customers_max_tab  :: ets:tid()}).

%% -------------------------------------------------------------------------
%% Client API
%% -------------------------------------------------------------------------

-spec start_link() -> {'ok', pid()} | {'error', any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec is_allowed(string()) -> boolean().
is_allowed(CustomerId) ->
    gen_server:call(?MODULE, {is_allowed, CustomerId}, infinity).

-spec set_rps(string(), pos_integer()) -> 'ok'.
set_rps(CustomerId, Rps) ->
    gen_server:cast(?MODULE, {set_rps, CustomerId, Rps}).

-spec unset_rps(string()) -> 'ok'.
unset_rps(CustomerId) ->
    gen_server:cast(?MODULE, {unset_rps, CustomerId}).

%% -------------------------------------------------------------------------
%% gen_server callbacks
%% -------------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    log4erl:info("throttle: initializing"),
    {ok, #st{
        total_used         = 0,
        total_max          = funnel_app:get_env(rps),
        customers_used_tab = ets:new(customers_tab, []),
        customers_max_tab  = ets:new(customers_tab, [])
    }}.


terminate(Reason, _St) ->
    log4erl:info("throttle: terminated (~W)", [Reason, 20]).

handle_call({is_allowed, CustomerId}, _From, St) ->
    G = funnel_conf:get(throttle_group_seconds),
    {Hour, Minute, Second} = time(),
    Period = {Hour, Minute, Second div G},
    {TotalUsed, TotalLeft} =
        case St#st.period of
            Period ->
                {St#st.total_used, St#st.total_max * G - St#st.total_used};
            _  ->
                ets:delete_all_objects(St#st.customers_used_tab),
                {0, St#st.total_max * G}
        end,
    CustomerMax  = customer_max(CustomerId, St),
    CustomerUsed = customer_used(CustomerId, St),
    CustomerLeft = erlang:max(0, CustomerMax * G - CustomerUsed),
    if
        TotalLeft =< 0 ->
            {reply, false, St};
        CustomerLeft =< 0 ->
            {reply, false, St};
        true ->
            ets:insert(St#st.customers_used_tab, {CustomerId, CustomerUsed + 1}),
            {reply, true, St#st{period = Period, total_used = TotalUsed + 1}}
    end.

handle_cast({set_rps, CustomerId, Rps}, St) ->
    ets:insert(St#st.customers_max_tab, {CustomerId, Rps}),
    {noreply, St};

handle_cast({unset_rps, CustomerId}, St) ->
    ets:delete(St#st.customers_max_tab, CustomerId),
    {noreply, St}.

handle_info(Info, St) ->
    {stop, {unexpected_info, Info}, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

customer_max(CustomerId, St) ->
    case ets:lookup(St#st.customers_max_tab, CustomerId) of
        [{_, Max}] -> Max;
        _          -> St#st.total_max
    end.

customer_used(CustomerId, St) ->
    case ets:lookup(St#st.customers_used_tab, CustomerId) of
        [{_, Used}] -> Used;
        _           -> 0
    end.
