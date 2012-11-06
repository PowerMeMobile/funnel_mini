-module(funnel_billy_session).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([get_session_id/0]).

%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3]).

-define(RECONNECT_TIMEOUT, 10000).

-record(st, {session_id}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_session_id() ->
    gen_server:call(?MODULE, get_session_id, infinity).

%% -------------------------------------------------------------------------
%% gen_server callbacks
%% -------------------------------------------------------------------------

init([]) ->
    P = fun(Prop) -> {ok, Value} = application:get_env(billy_client, Prop), Value end,
    case billy_client:start_session(P(host), P(port), P(username), P(password)) of
        {ok, SessionId} ->
            {ok, #st{session_id = SessionId}};
        {error, econnrefused} ->
            {ok, #st{}, ?RECONNECT_TIMEOUT};
        {error, invalid_credentials} ->
            {error, invalid_credentials}
    end.

terminate(_Reason, #st{session_id = undefined}) ->
    ok;
terminate(_Reason, #st{session_id = SessionId}) ->
    billy_client:stop_session(SessionId).

handle_call(get_session_id, _From, #st{session_id = undefined} = St) ->
    % return the error and timeout instantly.
    {reply, {error, no_session}, St, 0};

handle_call(get_session_id, _From, #st{session_id = SessionId} = St) ->
    {reply, {ok, SessionId}, St};

handle_call(Request, _From, St) ->
    {stop, {unexpected_call, Request}, St}.

handle_cast(Request, St) ->
    {stop, {unexpected_cast, Request}, St}.

handle_info(timeout, St) ->
    {stop, no_session, St};

handle_info(Info, St) ->
    {stop, {unexpected_info, Info}, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.
