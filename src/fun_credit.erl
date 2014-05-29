-module(fun_credit).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API exports
-export([
    start_link/0,
    request_credit/2
]).

%% Service API
-export([
    fetch_all/0
]).

%% gen_server exports
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").

-type customer_id() :: string().

-define(SYNC_INTERVAL, (1000 * 60 * 1)).

-record(st, {
    reserve_credit :: float(),
    timer_ref :: reference()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec request_credit(customer_id(), float()) ->
    {allowed, float()} | {denied, float()}.
request_credit(CustomerId, Credit) ->
    gen_server:call(?MODULE, {request_credit, CustomerId, Credit}).

%% ===================================================================
%% Service API
%% ===================================================================

-spec fetch_all() -> [{customer_id(), float()}].
fetch_all() ->
    dets:foldl(fun(I, Acc) -> [I | Acc] end, [], ?MODULE).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    process_flag(trap_exit, true),
    DetsOpts = [{ram_file, true}, {file, "data/credit.dets"}],
    {ok, ?MODULE} = dets:open_file(?MODULE, DetsOpts),
    {ok, ReserveCredit} = application:get_env(reserve_credit),
    TimerRef = erlang:start_timer(?SYNC_INTERVAL, self(), sync),
    ?log_info("Credit: started", []),
    {ok, #st{
        reserve_credit = ReserveCredit,
        timer_ref = TimerRef
    }}.

handle_call({request_credit, CustomerId, CreditRequested}, _From, St = #st{
    reserve_credit = ReserveCredit
}) ->
    Reply = request_local_credit(CustomerId, CreditRequested, ReserveCredit),
    {reply, Reply, St};

handle_call(Request, _From, St) ->
    {stop, {unexpected_call, Request}, St}.

handle_cast(Request, St) ->
    {stop, {unexpected_cast, Request}, St}.

handle_info({timeout, TimerRef, sync}, #st{timer_ref = TimerRef} = St) ->
    ok = dets:sync(?MODULE),
    TimerRef2 = erlang:start_timer(?SYNC_INTERVAL, self(), sync),
    {noreply, St#st{timer_ref = TimerRef2}};
handle_info({'EXIT', _Pid, Reason}, St) ->
    {stop, Reason, St};
handle_info(Info, St) ->
    {stop, {unexpected_info, Info}, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

terminate(Reason, #st{timer_ref = TimerRef}) ->
    dets:sync(?MODULE),
    dets:close(?MODULE),
    erlang:cancel_timer(TimerRef),
    ?log_info("Credit: terminated (~p)", [Reason]).

%% ===================================================================
%% Internal
%% ===================================================================

request_local_credit(CustomerId, CreditRequested, ReserveCredit) ->
    case dets:lookup(?MODULE, CustomerId) of
        [] ->
            case alley_services_api:request_credit(CustomerId, ReserveCredit) of
                {allowed, _} ->
                    LocalCreditLeft = ReserveCredit - CreditRequested,
                    ok = dets:insert(?MODULE, {CustomerId, LocalCreditLeft}),
                    {allowed, LocalCreditLeft};
                {denied, RemoteCreditLeft} when RemoteCreditLeft >= CreditRequested ->
                    case alley_services_api:request_credit(CustomerId, RemoteCreditLeft) of
                        {allowed, _} ->
                            LocalCreditLeft = RemoteCreditLeft - CreditRequested,
                            ok = dets:insert(?MODULE, {CustomerId, LocalCreditLeft}),
                            {allowed, LocalCreditLeft};
                        {denied, _} ->
                            {denied, 0}
                    end;
                {denied, _} ->
                    {denied, 0}
            end;
        [{_, CreditReserved}] when CreditReserved >= CreditRequested ->
            LocalCreditLeft = CreditReserved - CreditRequested,
            ok = dets:insert(?MODULE, {CustomerId, LocalCreditLeft}),
            {allowed, LocalCreditLeft};
        [{_, CreditReserved}] ->
            case alley_services_api:request_credit(CustomerId, ReserveCredit) of
                {allowed, _CreditLeft} ->
                    LocalCreditLeft = ReserveCredit + CreditReserved - CreditRequested,
                    ok = dets:insert(?MODULE, {CustomerId, LocalCreditLeft}),
                    {allowed, LocalCreditLeft};
                {denied, RemoteCreditLeft} when RemoteCreditLeft + CreditReserved >= CreditRequested ->
                    case alley_services_api:request_credit(CustomerId, RemoteCreditLeft) of
                        {allowed, _} ->
                            LocalCreditLeft = RemoteCreditLeft + CreditReserved - CreditRequested,
                            ok = dets:insert(?MODULE, {CustomerId, LocalCreditLeft}),
                            {allowed, LocalCreditLeft};
                        {denied, _} ->
                            {denied, 0}
                    end;
                {denied, _} ->
                    {denied, 0}
            end
    end.
