-module(fun_events_handler).

-export([
    handle_event/2
]).

-include_lib("alley_common/include/logging.hrl").

%% ===================================================================
%% API
%% ===================================================================

-spec handle_event(binary(), binary()) -> ok | {error, any()}.
handle_event(<<"text/plain">>, <<"BlacklistChanged">>) ->
    ?log_info("Got BlacklistChanged event", []),
    alley_services_blacklist:update();
handle_event(<<"text/plain">>, <<"CustomerChanged:", EventInfo/binary>>) ->
    [CustomerUuid, CustomerId] = binary:split(EventInfo, <<":">>),
    ?log_info("Got CustomerChanged event: CustomerUuuid:~p CustomerId:~p",
        [CustomerUuid, CustomerId]),
    ok;
handle_event(ContentType, Payload) ->
    ?log_warn("Got unexpected event: ~p ~p", [ContentType, Payload]),
    ok.

%% ===================================================================
%% Internal
%% ===================================================================
