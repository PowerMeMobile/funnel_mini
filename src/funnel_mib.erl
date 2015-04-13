-module(funnel_mib).

-export([send_coldstart_notification/0]).

-export([throughput/3,
         conns_bound/1,
         conn_table/3,
         settings/2,
         settings/3]).

-define(CONN_TABLE_COLUMNS, 14).

%% -------------------------------------------------------------------------
%% notifications
%% -------------------------------------------------------------------------

send_coldstart_notification() ->
    snmpa:send_notification(snmp_master_agent, coldStart, no_receiver,
                            "coldStart", []).

%% -------------------------------------------------------------------------
%% throughputSent01
%% throughputSent05
%% throughputSent10
%% throughputRecd01
%% throughputRecd05
%% throughputRecd10
%% -------------------------------------------------------------------------

throughput(get, Direction, Minutes) ->
    Now = calendar:universal_time(),
    Then = calendar:datetime_to_gregorian_seconds(Now) - Minutes * 60,
    Start = fun_time:utc_str(calendar:gregorian_seconds_to_datetime(Then)),
    Counters = lists:flatten(
        [ Cs || {Period, Cs} <- fun_throughput:slices(), Period >= Start ]
    ),
    {value, lists:sum([ C || {_, D, C} <- Counters, D =:= Direction ])}.

%% -------------------------------------------------------------------------
%% connsBound
%% -------------------------------------------------------------------------

conns_bound(get) ->
    {value, length(fun_smpp_server:connections())}.

%% -------------------------------------------------------------------------
%% connTable
%% -------------------------------------------------------------------------

conn_table(get, RowIndex, Cols) ->
    case get_row(RowIndex, fun_smpp_server:connections()) of
        {ok, Row} ->
            get_cols(
                Cols,
                complete_connections_row(Row, fun_throughput:slices()),
                ?CONN_TABLE_COLUMNS
            );
        Error ->
            Error
    end;

conn_table(get_next, RowIndex, Cols) ->
    Conns = fun_smpp_server:connections(),
    case get_next_row(RowIndex, Conns) of
        {ok, Row} ->
            get_next_cols(
                Cols,
                complete_connections_row(Row, fun_throughput:slices()),
                ?CONN_TABLE_COLUMNS
            );
        endOfTable ->
            case get_next_row([], Conns) of
                {ok, Row} ->
                    get_next_cols(
                        [ Col + 1 || Col <- Cols ],
                        complete_connections_row(Row, fun_throughput:slices()),
                        ?CONN_TABLE_COLUMNS
                    );
                endOfTable ->
                    [ endOfTable || _ <- Cols ]
            end
    end.

%% -------------------------------------------------------------------------
%% settingsSMPPServerAddr
%% settingsSMPPServerPort
%% settingsSMPPServerSystemId
%% settingsSessionInitTime
%% settingsEnquireLinkTime
%% settingsInactivityTime
%% settingsResponseTime
%% settingsBatchMaxSize
%% settingsBatchMaxWait
%% settingsFileLogDir
%% settingsFileLogSize
%% settingsFileLogRotations
%% settingsFileLogLevel
%% settingsConsoleLogLevel
%% settingsLogSMPPPdus
%% settingsSMPPPduLogDir
%% settingsStripLeadingZero
%% settingsCountryCode
%% settingsBulkThreshold
%% settingsRejectSourceTonNpi
%% settingsCorrectSourceTonNpi
%% settingsConcatMaxWait
%% settingsCutoffValidityPeriod
%% settingsDeliverSMWindowSize
%% settingsThrottleGroupSeconds
%% settingsBackendResponseTime
%% settingsMaxStopTime
%% -------------------------------------------------------------------------

settings(get, Key) when Key =:= smpp_server_addr ->
    {value, tuple_to_list(funnel_conf:get(Key))};
settings(get, Key) when Key =:= session_init_time;
                        Key =:= enquire_link_time;
                        Key =:= inactivity_time;
                        Key =:= response_time;
                        Key =:= backend_response_time ->
    {value, case funnel_conf:get(Key) of infinity -> 0; N -> N end};
settings(get, Key) ->
    {value, funnel_conf:get(Key)}.

settings(set, Value, Key) when Key =:= smpp_server_addr ->
    funnel_conf:set(Key, list_to_tuple(Value)),
    noError;
settings(set, Value, Key) when Key =:= session_init_time;
                               Key =:= enquire_link_time;
                               Key =:= inactivity_time;
                               Key =:= response_time;
                               Key =:= backend_response_time ->
    funnel_conf:set(Key, case Value of 0 -> infinity; N -> N end),
    noError;
settings(set, Value, Key) when Key =:= deliver_sm_window_size;
                               Key =:= throttle_group_seconds ->
    true = Value > 0,
    funnel_conf:set(Key, Value),
    noError;
settings(set, Value, Key) when Key =:= file_log_level;
                               Key =:= console_log_level ->
    funnel_conf:set(Key,
        case Value of
            0 -> debug;
            1 -> info;
            2 -> warn;
            3 -> error;
            4 -> fatal;
            5 -> none
        end),
    noError;
settings(set, Value, Key) when Key =:= log_smpp_pdus;
                               Key =:= strip_leading_zero;
                               Key =:= reject_source_ton_npi;
                               Key =:= correct_source_ton_npi;
                               Key =:= cutoff_validity_period ->
    funnel_conf:set(Key, case Value of 0 -> false; 1 -> true end),
    noError;
settings(set, Value, Key) ->
    funnel_conf:set(Key, Value),
    noError.

%% -------------------------------------------------------------------------
%% private helpers
%% -------------------------------------------------------------------------

complete_connections_row(
        {Id, UUID, ConnectedAt, Type, Addr, CustomerId, UserId, _NodePid}, Slices) ->
    DateTime = snmp:universal_time_to_date_and_time(ConnectedAt),
    ErrorCount = length(fun_errors:lookup(UUID)),
    TP =
        fun(Direction, Minutes) ->
                gtw_throughput(Slices, UUID, Direction, Minutes)
        end,
    {
        Id,          % connId
        UUID,        % connUUID
        DateTime,    % connConnectedAt
        Type,        % connType
        Addr,        % connAddr
        CustomerId,  % connCustomerId
        UserId,      % connUserId
        ErrorCount,  % connErrorCount
        TP(out, 1),  % connSent01
        TP(out, 5),  % connSent05
        TP(out, 10), % connSent10
        TP(in, 1),   % connRecd01
        TP(in, 5),   % connRecd05
        TP(in, 10)   % connRecd10
    }.

gtw_throughput(Slices, UUID, Direction, Minutes) ->
    Now = calendar:universal_time(),
    Then = calendar:datetime_to_gregorian_seconds(Now) - Minutes * 60,
    Start = fun_time:utc_str(calendar:gregorian_seconds_to_datetime(Then)),
    Counters = lists:flatten(
        [ Cs || {Period, Cs} <- Slices, Period >= Start ]
    ),
    lists:sum(
        [ C || {CnId, Dir, C} <- Counters, CnId =:= UUID, Dir =:= Direction ]
    ).

%% -------------------------------------------------------------------------
%% private instrumental functions
%% -------------------------------------------------------------------------

get_row([Id], Rows) ->
    case lists:keyfind(Id, 1, Rows) of
        false ->
            {noValue, noSuchInstance};
        Row ->
            {ok, Row}
    end.

get_cols([Col|Cols], Row, NumCols) when Col < 2 orelse Col > NumCols ->
    [{noValue, noSuchInstance}|get_cols(Cols, Row, NumCols)];
get_cols([Col|Cols], Row, NumCols) ->
    [{value, element(Col, Row)}|get_cols(Cols, Row, NumCols)];
get_cols([], _Row, _NumCols) ->
    [].

get_next_row([], []) ->
    endOfTable;
get_next_row([], Rows) ->
    {ok, hd(lists:sort(Rows))};
get_next_row([Id], Rows) ->
    case [ R || R <- lists:sort(Rows), element(1, R) > Id ] of
        [] ->
            endOfTable;
        Rs ->
            {ok, hd(Rs)}
    end.

get_next_cols([Col|Cols], Row, NumCols) when Col < 2 ->
    [{[2, element(1, Row)], element(2, Row)}|get_next_cols(Cols, Row, NumCols)];
get_next_cols([Col|Cols], Row, NumCols) when Col > NumCols ->
    [endOfTable|get_next_cols(Cols, Row, NumCols)];
get_next_cols([Col|Cols], Row, NumCols) ->
    [{[Col, element(1, Row)], element(Col, Row)}|get_next_cols(Cols, Row, NumCols)];
get_next_cols([], _Row, _NumCols) ->
    [].
