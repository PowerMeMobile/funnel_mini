-module(fun_time).

-export([milliseconds/0,
         now_to_milliseconds/1,
         milliseconds_to_now/1,
         utc_str/0,
         utc_str/1]).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec milliseconds() -> pos_integer().
milliseconds() ->
    now_to_milliseconds(os:timestamp()).

-spec now_to_milliseconds(erlang:timestamp()) -> pos_integer().
now_to_milliseconds({MegaSecs, Secs, MicroSecs}) ->
    (MegaSecs * 1000000 + Secs) * 1000 + MicroSecs div 1000.

-spec milliseconds_to_now(pos_integer()) -> erlang:timestamp().
milliseconds_to_now(MS) ->
    Secs = MS div 1000,
    {Secs div 1000000, Secs rem 1000000, (MS rem 1000) * 1000}.

-spec utc_str() -> string().
utc_str() ->
    utc_str(calendar:universal_time()).

-spec utc_str(erlang:timestamp() | calendar:datetime()) -> string().
utc_str({_,_,_} = Now) ->
    utc_str(calendar:now_to_datetime(Now));
utc_str({{Y, Mon, D}, {H, Min, S}}) ->
    lists:concat([pad(Y rem 100), pad(Mon), pad(D), pad(H), pad(Min), pad(S)]).

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

pad(N) when N > 9 ->
    N;
pad(N) ->
    [$0, N + 48].
