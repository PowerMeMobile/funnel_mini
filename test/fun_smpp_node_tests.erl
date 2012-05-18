-module(fun_smpp_node_tests).

-include_lib("eunit/include/eunit.hrl").

-define(gv(K,P), proplists:get_value(K,P)).

%% not udh, shouldn't do anything.
to_tlv_if_udh_not_udh_test() ->
    Before = [{esm_class, 0}, {short_message, "test"}],
    After = fun_smpp_node:to_tlv_if_udh(Before),
    ?assertEqual(Before, After).

%% udh, should convert to tlv.
to_tlv_if_udh_udh_test() ->
    Before = [{esm_class, 2#01000000}, {short_message, [5,0,3,127,2,1|"test"]}],
    After = fun_smpp_node:to_tlv_if_udh(Before),
    ?assert(Before =/= After),
    ?assertEqual(5, length(After)),
    ?assertEqual("test", ?gv(short_message, After)),
    ?assertEqual(0, ?gv(esm_class, After)),
    ?assertEqual(127, ?gv(sar_msg_ref_num, After)),
    ?assertEqual(2, ?gv(sar_total_segments, After)),
    ?assertEqual(1, ?gv(sar_segment_seqnum, After)).

%% wrongly encoded udh, should fail.
to_tlv_if_udh_bad_test() ->
    Before = [{esm_class, 2#01000000}, {short_message, [5,127,2,1|"test"]}],
    ?assertError(_, fun_smpp_node:to_tlv_if_udh(Before)).

take_fingerprints_test() ->
    Full = [{short_message, "message"},
            {sm_default_msg_id, 0},
            {data_coding, 0},
            {replace_if_present_flag, 0},
            {registered_delivery, 0},
            {validity_period, ""},
            {schedule_delivery_time, ""},
            {priority_flag, 0},
            {protocol_id, 0},
            {esm_class, 0},
            {destination_addr, "33333234"},
            {dest_addr_npi, 1},
            {dest_addr_ton, 1},
            {source_addr, "12313414"},
            {source_addr_npi, 1},
            {source_addr_ton, 1},
            {service_type, ""}],
    FP1 = fun_smpp_node:take_fingerprints(Full),
    ?assert(is_binary(FP1)),
    ?assertEqual(16, size(FP1)),
    Relevant = [{short_message, "message"},
                {data_coding, 0},
                {registered_delivery, 0},
                {priority_flag, 0},
                {protocol_id, 0},
                {esm_class, 0},
                {source_addr, "12313414"},
                {source_addr_npi, 1},
                {source_addr_ton, 1},
                {service_type, ""}],
    FP2 = fun_smpp_node:take_fingerprints(Relevant),
    ?assertEqual(FP1, FP2),
    Changed = lists:keyreplace(short_message, 1, Relevant,
                               {short_message, "message2"}),
    FP3 = fun_smpp_node:take_fingerprints(Changed),
    ?assert(FP2 =/= FP3).

dest_addr_test() ->
    Params = [{destination_addr, "+375 29 676 1221"},
              {dest_addr_npi, 1},
              {dest_addr_ton, 1}],
    ?assertEqual({"+375 29 676 1221", 1, 1}, fun_smpp_node:dest_addr(Params)).
