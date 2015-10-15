-define(KEYFIND2(Key, List), element(2, lists:keyfind(Key, 1, List))).

-define(KEYFIND3(Key, List, Default),
    case lists:keyfind(Key, 1, List) of
        {Key, Value} -> Value;
        false        -> Default
    end).

-define(KEYREPLACE3(Key, Value, List),
    lists:keyreplace(Key, 1, List, {Key, Value})).

-define(KEYSTORE3(Key, Value, List),
    lists:keystore(Key, 1, List, {Key, Value})).
