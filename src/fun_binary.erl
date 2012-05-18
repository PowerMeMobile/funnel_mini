-module(fun_binary).


-export([split/2]).


-spec split/2 :: (Binary :: binary(), Size :: pos_integer()) -> [binary()].

split(Binary, Size) when Size > 0 ->
    split(Binary, Size, []).


%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------


split(Binary, Size, Acc) ->
    case size(Binary) of
	0 ->
	    lists:reverse(Acc);
	N when N =< Size ->
	    lists:reverse(Acc, [Binary]);
	_ ->
	    {Bin1, Bin2} = erlang:split_binary(Binary, Size),
	    split(Bin2, Size, [Bin1|Acc])
    end.
