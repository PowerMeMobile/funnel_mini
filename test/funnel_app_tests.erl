-module(funnel_app_tests).

-include_lib("eunit/include/eunit.hrl").

get_env1_test() ->
    ?assertError(_, funnel_app:get_env(key1)),
    application:set_env(funnel_mini, key1, "exists"),
    ?assertEqual("exists", funnel_app:get_env(key1)).
