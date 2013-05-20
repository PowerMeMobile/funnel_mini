-module(temp_fun_cache).

-behaviour(gen_server).

%% API exports
-export([start_link/0]).
-export([store/2, fetch/1, delete/1]).

%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

-record(st, {}).

%% -------------------------------------------------------------------------
%% API functions
%% -------------------------------------------------------------------------

-spec start_link() -> {'ok', pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec store(any(), any()) -> 'ok'.
store(Key, Value) ->
    gen_server:call(?MODULE, {store, Key, Value}, infinity).

-spec fetch(any()) -> {'ok', any()} | 'not_found'.
fetch(Key) ->
    gen_server:call(?MODULE, {fetch, Key}, infinity).

-spec delete(any()) -> 'ok'.
delete(Key) ->
    gen_server:call(?MODULE, {delete, Key}, infinity).

%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    lager:info("cache: initializing"),
    {ok, cache} = dets:open_file(cache, [{file, "data/cache.dets"}]),
    {ok, #st{}}.

terminate(Reason, _St) ->
    dets:close(cache),
    lager:info("cache: terminated (~w)", [Reason]).

handle_call({store, Key, Value}, _From, St) ->
    ok = dets:insert(cache, {Key, Value}),
    {reply, ok, St};

handle_call({fetch, Key}, _From, St) ->
    case dets:lookup(cache, Key) of
        [] ->
            {reply, not_found, St};
        [{Key, Value}] ->
            {reply, {ok, Value}, St}
    end;

handle_call({delete, Key}, _From, St) ->
    dets:delete(cache, Key),
    {reply, ok, St};

handle_call(Request, _From, St) ->
    {stop, {unexpected_call, Request}, St}.

handle_cast(Request, St) ->
    {stop, {unexpected_cast, Request}, St}.

handle_info(Info, St) ->
    {stop, {unexpected_info, Info}, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.
