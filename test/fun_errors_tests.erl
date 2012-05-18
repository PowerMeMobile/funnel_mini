-module(fun_errors_tests).

-include_lib("eunit/include/eunit.hrl").
-include("helpers.hrl").

-define(UUID, "72e9eae6-4fb3-48c7-8d91-06fe4656594e").

fun_errors_test_() ->
    {setup,
     fun() -> {ok, E} = fun_errors:start_link(), unlink(E), E end,
     [fun() -> ?assertEqual([], fun_errors:lookup(?UUID)) end,
      fun() ->
          ok = fun_errors:register_connection(?UUID, self()),
          ?assertEqual([], fun_errors:lookup(?UUID)),
          fun_errors:record(?UUID, 42),
          Errs1 = fun_errors:lookup(?UUID),
          ?assertEqual(1, length(Errs1)),
          fun_errors:record(?UUID, 37),
          Errs2 = fun_errors:lookup(?UUID),
          ?assertEqual(2, length(Errs2))
      end]}.
