-module(fun_time_tests).

-include_lib("eunit/include/eunit.hrl").

milliseconds_test() ->
    Seconds = fun_time:milliseconds(),
    ?assert(is_integer(Seconds)),
    ?assert(Seconds > 0).

utc_str1_test() ->
    Time = calendar:universal_time(),
    ?assertEqual(fun_time:utc_str(Time), fun_time:utc_str()).

utc_str2_test() ->
    T1 = {{2001, 1, 2}, {3, 4, 5}},
    ?assertEqual("010102030405", fun_time:utc_str(T1)),
    T2 = {{2010, 10, 22}, {12, 40, 5}},
    ?assertEqual("101022124005", fun_time:utc_str(T2)).
