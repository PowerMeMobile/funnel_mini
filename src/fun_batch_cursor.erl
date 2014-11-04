-module(fun_batch_cursor).

-include_lib("alley_common/include/logging.hrl").
-include("otp_records.hrl").

-behaviour(gen_server).

%% API exports
-export([start_link/0,
         write/2,
         read/1]).

%% gen_server exports
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

-define(GC_INTERVAL, 2 * 60 * 1000).     % perform gc every 2 minutes (in ms).
-define(KEEP_CURSORS_FOR, 48 * 60 * 60). % keep cursors for 2 days (in s).

-record(cursor, {
    uuid,      % batch uuid
    timestamp, % time of last cursor update
    offset     % batch offset
}).

-record(st, {}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec start_link/0 :: () -> {'ok', pid()} | 'ignore' | {'error', any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec write/2 :: (string() | binary(), non_neg_integer()) -> no_return().
write(UUID, Offset) when is_list(UUID) ->
    write(list_to_binary(UUID), Offset);

write(UUID, Offset) when is_binary(UUID) ->
    gen_server:cast(?MODULE, {write, UUID, Offset}).

-spec read/1 :: (string() | binary()) -> non_neg_integer().
read(UUID) when is_list(UUID) ->
    read(list_to_binary(UUID));

read(UUID) when is_binary(UUID) ->
    gen_server:call(?MODULE, {read, UUID}, infinity).

%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    ?log_info("Cursor: initializing", []),
    case mnesia:create_table(cursor,
            [{attributes, record_info(fields, cursor)}, {disc_copies, [node()]}]) of
        {atomic, ok}                        -> ok;
        {aborted, {already_exists, cursor}} -> ok
    end,
    mnesia:wait_for_tables([cursor], infinity),
    erlang:start_timer(0, self(), gc),
    {ok, #st{}}.

terminate(Reason, _St) ->
    ?log_info("Cursor: terminated (~p)", [Reason]).

handle_call({read, UUID}, _From, St) ->
    Reply =
        case mnesia:dirty_read(cursor, UUID) of
            [#cursor{offset = Offset}] -> Offset;
            []                         -> 0
        end,
    {reply, Reply, St}.

handle_cast({write, UUID, Offset}, St) ->
    Cursor = #cursor{uuid = UUID, timestamp = timestamp(), offset = Offset},
    mnesia:dirty_write(cursor, Cursor),
    {noreply, St}.

handle_info(#timeout{msg = gc}, St) ->
    gc(),
    erlang:start_timer(?GC_INTERVAL, self(), gc),
    {noreply, St}.

%% to avoid compiler warnings.
code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

timestamp() ->
    {MegaSecs, Secs, _MicroSecs} = os:timestamp(),
    MegaSecs * 1000000 + Secs.

gc() ->
    TS = timestamp() - ?KEEP_CURSORS_FOR,
    UUIDs = mnesia:dirty_select(
        cursor, [{{cursor, '$1', '$2', '_'}, [{'<', '$2', TS}], ['$1']}]
    ),
    lists:foreach(fun(UUID) -> mnesia:dirty_delete(cursor, UUID) end, UUIDs).
