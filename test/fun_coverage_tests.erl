-module(fun_coverage_tests).

-include_lib("eunit/include/eunit.hrl").
-include("FunnelAsn.hrl").

fun_coverage_test_() ->
    {setup,
     fun() ->
         application:start(mnesia),
         mnesia:create_table(funnel_conf, [{attributes, [key, value]}])
     end,
     [fun test_strip_non_digits/0,
      fun test_to_international_international/0,
      fun test_to_international_other/0,
      fun test_flatten_networks/0,
      fun test_fill_coverage_tab/0,
      fun test_fill_coverage_tab_empty/0,
      fun test_which_network/0]}.

test_strip_non_digits() ->
    ?assertEqual("4031888111",
        fun_coverage:strip_non_digits("(+40) 31 888-111")),
    ?assertEqual("375296761221",
        fun_coverage:strip_non_digits("+375 29 676 1221")),
    ?assertEqual("12345678910",
        fun_coverage:strip_non_digits("12345678910")).

test_to_international_international() ->
    Addr1 = {"+44 29 675643", 1, 1},
    ?assertEqual("4429675643",
        fun_coverage:to_international(Addr1, false, "999")),
    Addr2 = {"00 44 29 675643", 1, 1},
    ?assertEqual("4429675643",
        fun_coverage:to_international(Addr2, false, "999")),
    Addr3 = {"00 259 675643", 0, 1},
    ?assertEqual("259675643",
        fun_coverage:to_international(Addr3, false, "222")),
    Addr4 = {"+ 344 067 5643", 0, 1},
    ?assertEqual("3440675643",
        fun_coverage:to_international(Addr4, false, "333")).

test_to_international_other() ->
    Addr1 = {"067 5643", 0, 1},
    ?assertEqual("0675643",
        fun_coverage:to_international(Addr1, false, "999")),
    Addr2 = {"067 5643", 2, 1},
    ?assertEqual("777675643",
        fun_coverage:to_international(Addr2, true, "777")).

test_flatten_networks() ->
    Networks = [#'Network'{id = "b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe",
                           countryCode = "444",
                           numbersLen = 12,
                           prefixes = ["296", "293"],
                           providerId = "123"},
                #'Network'{id = "d9f043d7-8cb6-4a53-94a8-4789da444f18",
                           countryCode = "555",
                           numbersLen = 13,
                           prefixes = ["2311", "3320"],
                           providerId = "456"}],
    ?assertEqual([{"444293", 12, "b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe", "123"},
                  {"444296", 12, "b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe", "123"},
                  {"5552311", 13, "d9f043d7-8cb6-4a53-94a8-4789da444f18", "456"},
                  {"5553320", 13, "d9f043d7-8cb6-4a53-94a8-4789da444f18", "456"}],
                 lists:sort(fun_coverage:flatten_networks(Networks))).

test_fill_coverage_tab() ->
    Networks = [#'Network'{id = "b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe",
                           countryCode = "444",
                           numbersLen = 12,
                           prefixes = ["296", "293"],
                           providerId = "123"},
                #'Network'{id = "d9f043d7-8cb6-4a53-94a8-4789da444f18",
                           countryCode = "555",
                           numbersLen = 13,
                           prefixes = ["2311", "3320"],
                           providerId = "456"}],
    Tab = ets:new(coverage_tab, []),
    fun_coverage:fill_coverage_tab(Networks, Tab),
    ?assertEqual(5, ets:info(Tab, size)),
    ?assertEqual([{"444296", 12, "b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe", "123"}],
                 ets:lookup(Tab, "444296")),
    ?assertEqual([{"444293", 12, "b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe", "123"}],
                 ets:lookup(Tab, "444293")),
    ?assertEqual([{"5552311", 13, "d9f043d7-8cb6-4a53-94a8-4789da444f18", "456"}],
                 ets:lookup(Tab, "5552311")),
    ?assertEqual([{"5553320", 13, "d9f043d7-8cb6-4a53-94a8-4789da444f18", "456"}],
                 ets:lookup(Tab, "5553320")),
    ?assertEqual([{prefix_lens, [6,7]}], ets:lookup(Tab, prefix_lens)),
    ets:delete(Tab).

test_fill_coverage_tab_empty() ->
    Tab = ets:new(coverage_tab, []),
    fun_coverage:fill_coverage_tab([], Tab),
    ?assertEqual(1, ets:info(Tab, size)),
    ?assertEqual([{prefix_lens, []}], ets:lookup(Tab, prefix_lens)),
    ets:delete(Tab).

test_which_network() ->
    funnel_conf:set(strip_leading_zero, false),
    funnel_conf:set(country_code, "999"),
    Networks = [#'Network'{id = "b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe",
                           countryCode = "444",
                           numbersLen = 12,
                           prefixes = ["296", "293"],
                           providerId = "123"},
                #'Network'{id = "d9f043d7-8cb6-4a53-94a8-4789da444f18",
                           countryCode = "555",
                           numbersLen = 0,
                           prefixes = ["2311", "3320"],
                           providerId = "123"},
                #'Network'{id = "06561b4c-d7b2-4cab-b031-af2a90c31491",
                           countryCode = "999",
                           numbersLen = 12,
                           prefixes = ["011", "083"],
                           providerId = "123"}],
    Tab = ets:new(coverage_tab, []),
    fun_coverage:fill_coverage_tab(Networks, Tab),
    ?assertEqual(undefined,
                 fun_coverage:which_network({"44429611347", 1, 0}, Tab)),
    ?assertEqual({"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe", "444296113477", "123"},
                 fun_coverage:which_network({"444296113477", 1, 0}, Tab)),
    ?assertEqual({"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe", "444293113477", "123"},
                 fun_coverage:which_network({"444293113477", 1, 0}, Tab)),
    ?assertEqual({"d9f043d7-8cb6-4a53-94a8-4789da444f18", "55523113", "123"},
                 fun_coverage:which_network({"55523113", 1, 0}, Tab)),
    ?assertEqual({"d9f043d7-8cb6-4a53-94a8-4789da444f18", "5553320123456", "123"},
                 fun_coverage:which_network({"5553320123456", 1, 0}, Tab)),
    ?assertEqual(undefined,
                 fun_coverage:which_network({"011333333", 1, 0}, Tab)),
    ?assertEqual({"06561b4c-d7b2-4cab-b031-af2a90c31491", "999011333333", "123"},
                 fun_coverage:which_network({"011333333", 0, 0}, Tab)),
    ?assertEqual({"06561b4c-d7b2-4cab-b031-af2a90c31491", "999083333333", "123"},
                 fun_coverage:which_network({"083333333", 2, 0}, Tab)),
    ?assertEqual({"06561b4c-d7b2-4cab-b031-af2a90c31491", "999083333333", "123"},
                 fun_coverage:which_network({"+999083333333", 0, 0}, Tab)),
    ?assertEqual({"06561b4c-d7b2-4cab-b031-af2a90c31491", "999083333333", "123"},
                 fun_coverage:which_network({"00999083333333", 0, 0}, Tab)),
    ?assertEqual({"06561b4c-d7b2-4cab-b031-af2a90c31491", "999083333333", "123"},
                 fun_coverage:which_network({"+999083333333", 1, 0}, Tab)),
    ?assertEqual({"06561b4c-d7b2-4cab-b031-af2a90c31491", "999083333333", "123"},
                 fun_coverage:which_network({"00999083333333", 1, 0}, Tab)),
    ets:delete(Tab).
