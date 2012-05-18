-module(fun_binary_tests).

-include_lib("eunit/include/eunit.hrl").

split_empty_test() ->
    ?assertEqual([], fun_binary:split(<<>>, 10)).

split_nonempty_test() ->
    B = <<1,2,3,4,5,6>>,
    ?assertEqual([<<1>>, <<2>>, <<3>>, <<4>>, <<5>>, <<6>>],
                 fun_binary:split(B, 1)),
    ?assertEqual([<<1,2>>, <<3,4>>, <<5,6>>], fun_binary:split(B, 2)),
    ?assertEqual([<<1,2,3>>, <<4,5,6>>], fun_binary:split(B, 3)),
    ?assertEqual([<<1,2,3,4>>, <<5,6>>], fun_binary:split(B, 4)),
    ?assertEqual([<<1,2,3,4,5>>, <<6>>], fun_binary:split(B, 5)),
    ?assertEqual([<<1,2,3,4,5,6>>], fun_binary:split(B, 6)),
    ?assertEqual([<<1,2,3,4,5,6>>], fun_binary:split(B, 7)).
