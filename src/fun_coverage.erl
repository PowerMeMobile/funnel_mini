-module(fun_coverage).

-include("types.hrl").
-include("FunnelAsn.hrl").

-ifdef(TEST).
-compile(export_all).
-endif.

-export([fill_coverage_tab/2, which_network/2]).

-define(TON_UNKNOWN,       0).
-define(TON_INTERNATIONAL, 1).
-define(TON_NATIONAL,      2).
-define(TON_ALPHANUMERIC,  5).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec fill_coverage_tab([#'Network'{}], ets:tid()) -> ets:tid().
fill_coverage_tab(Networks, Tab) ->
    FlatNetworks = flatten_networks(Networks),
    lists:foreach(fun(NetworkTuple) -> ets:insert(Tab, NetworkTuple) end,
                  FlatNetworks),
    PrefixLens = lists:usort([ length(P) || {P, _, _, _} <- FlatNetworks ]),
    ets:insert(Tab, {prefix_lens, PrefixLens}),
    Tab.

-spec which_network(full_addr(), ets:tid()) -> {string(), string(), string()} | 'undefined'.
which_network({_, Ton, _} = Addr, Tab) ->
    StripZero = funnel_conf:get(strip_leading_zero),
    CountryCode = funnel_conf:get(country_code),
    [{_, PrefixLens}] = ets:lookup(Tab, prefix_lens),
    Proper = to_international(Addr, StripZero, CountryCode),
    case try_match_network(Proper, prefixes(Proper, PrefixLens), Tab) of
        undefined when Ton =:= ?TON_UNKNOWN ->
            try_match_network(CountryCode ++ Proper,
                              prefixes(CountryCode ++ Proper, PrefixLens),
                              Tab);
        Other ->
            Other
    end.

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

prefixes(Digits, PrefixLens) ->
    [ lists:sublist(Digits, L) || L <- PrefixLens, L < length(Digits) ].

flatten_networks(Networks) ->
    lists:flatmap(fun(#'Network'{id = Id, countryCode = Code,
                                 numbersLen = NumLen, prefixes = Prefixes,
                                 providerId = Provider}) ->
                      [ {Code ++ P, NumLen, Id, Provider} || P <- Prefixes ]
                  end,
                  Networks).

to_international({"+" ++ Rest, _Ton, _Npi}, _, _) ->
    strip_non_digits(Rest);
to_international({"00" ++ Rest, _Ton, _Npi}, _, _) ->
    strip_non_digits(Rest);
to_international({"0" ++ Rest, _Ton, _Npi}, true, CountryCode) ->
    CountryCode ++ strip_non_digits(Rest);
to_international({Number, ?TON_INTERNATIONAL, _Npi}, _, _) ->
    strip_non_digits(Number);
to_international({Number, ?TON_NATIONAL, _Npi}, _, CountryCode) ->
    CountryCode ++ strip_non_digits(Number);
to_international({Number, _Ton, _Npi}, _, _) ->
    strip_non_digits(Number).

strip_non_digits(Number) ->
    [ D || D <- Number, D >= $0, D =< $9 ].

try_match_network(_Number, [], _Tab) ->
    undefined;
try_match_network(Number, [P|Ps], Tab) ->
    case ets:lookup(Tab, P) of
        [{P, NumLen, Id, ProviderId}] when NumLen =:= 0 orelse NumLen =:= length(Number) ->
            {Id, Number, ProviderId};
        _ ->
            try_match_network(Number, Ps, Tab)
    end.
