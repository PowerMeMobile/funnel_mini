-module(funnel_sup).

-behaviour(supervisor).

%% API exports
-export([start_link/0]).

%% suprevisor exports
-export([init/1]).

-define(CHILD(Mod, Restart, Shutdown),
    {Mod, {Mod, start_link, []}, Restart, Shutdown, worker, [Mod]}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% -------------------------------------------------------------------------
%% supervisor callback functions
%% -------------------------------------------------------------------------

init([]) ->
    {ok, {{rest_for_one, 5, 30}, [
        ?CHILD(fun_amqp_pool, permanent, 5000),
        ?CHILD(alley_services_auth_cache, permanent, 5000),
        ?CHILD(alley_services_api, permanent, 5000),
        ?CHILD(alley_services_blacklist, permanent, 5000),
        ?CHILD(alley_services_events, permanent, 5000),
        ?CHILD(fun_credit, permanent, 5000),
        ?CHILD(fun_tracker, permanent, 5000),
        ?CHILD(fun_throttle, permanent, 5000),
        ?CHILD(fun_throughput, permanent, 5000),
        ?CHILD(fun_errors, permanent, 5000),
        ?CHILD(fun_batch_cursor, permanent, 5000),
        ?CHILD(fun_smpp_server, transient, 5000)
    ]}}.
