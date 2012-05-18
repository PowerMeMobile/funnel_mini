-module(funnel_conf).

-compile({no_auto_import, [get/1]}).

-export([init/0, get/1, set/2]).

-type key() :: 'smpp_server_addr' | 'smpp_server_port' | 'smpp_server_system_id' |
               'session_init_time' | 'enquire_link_time' | 'inactivity_time' | 'response_time' |
               'batch_max_size' | 'batch_max_wait' |
               'file_log_dir' | 'file_log_size' | 'file_log_rotations' | 'file_log_level' |
               'console_log_level' | 'log_smpp_pdus' | 'bulk_threshold' |
               'reject_source_ton_npi' | 'correct_source_ton_npi' | 'concat_max_wait' |
               'cutoff_validity_period' | 'deliver_sm_window_size' | 'throttle_group_seconds' |
               'backend_response_time' | 'max_stop_time'.

-type value() :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} |
                 non_neg_integer() | string() | boolean() | 'infinity' |
                 'debug' | 'info' | 'warn' | 'error' | 'fatal' | 'none'.

-record(funnel_conf, {key :: key(), value :: value()}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec init() -> 'ok'.
init() ->
    case mnesia:create_table(funnel_conf,
            [{attributes, record_info(fields, funnel_conf)}, {disc_copies, [node()]}]) of
        {atomic, ok}                             -> ok;
        {aborted, {already_exists, funnel_conf}} -> ok
    end,
    ok = mnesia:wait_for_tables([funnel_conf], infinity).

-spec get(key()) -> value().
get(Key) ->
    case mnesia:dirty_read(funnel_conf, Key) of
        [#funnel_conf{value = Value}] -> Value;
        []                            -> default(Key)
    end.

-spec set(key(), value()) -> 'ok'.
set(Key, Value) ->
    mnesia:transaction(
        fun() -> mnesia:write(#funnel_conf{key = Key, value = Value}) end
    ),
    log4erl:info("funnel: setting updated [~p: ~p]", [Key, Value]),
    ok.

%% -------------------------------------------------------------------------
%% Default configuration values.
%% -------------------------------------------------------------------------

default(smpp_server_addr)      -> default_addr();
default(smpp_server_port)      -> 2775;
default(smpp_server_system_id) -> "Funnel";
default(session_init_time)     -> 10000;
default(enquire_link_time)     -> 60000;
default(inactivity_time)       -> infinity;
default(response_time)         -> 60000;
default(batch_max_size)        -> 100000;
default(batch_max_wait)        -> 5000;
default(file_log_dir)          -> "log";
default(file_log_size)         -> 5000000;
default(file_log_rotations)    -> 4;
default(file_log_level)        -> info;
default(console_log_level)     -> debug;
default(log_smpp_pdus)         -> false;
default(smpp_pdu_log_dir)      -> "log/smpp";
default(strip_leading_zero)    -> false;
default(country_code)          -> "999";
default(bulk_threshold)        -> 100;
default(reject_source_ton_npi) -> false;
default(correct_source_ton_npi)-> false;
default(concat_max_wait)       -> 60000;
default(cutoff_validity_period)-> false;
default(deliver_sm_window_size)-> 1;
default(throttle_group_seconds)-> 3;
default(backend_response_time) -> 1000;
default(max_stop_time)         -> 120000.

default_addr() ->
    {ok, Host} = inet:gethostname(),
    {ok, Addr} = inet:getaddr(Host, inet),
    Addr.
