-module(funnel_app).

-behaviour(application).

%% API exports
-export([get_env/1]).
-export([set_debug_level/0]).

%% application callback exports
-export([start/2, prep_stop/1, stop/1, config_change/3]).

-define(APP, funnel_mini).

%% -------------------------------------------------------------------------
%% API functions
%% -------------------------------------------------------------------------

-spec get_env(any()) -> any().
get_env(rps)             -> 10000;
get_env(max_connections) -> 100;
get_env(Key)             -> element(2, application:get_env(?APP, Key)).

-spec set_debug_level() -> ok.
set_debug_level() ->
	lager:set_loglevel(lager_console_backend, debug).

%% -------------------------------------------------------------------------
%% application callback functions
%% -------------------------------------------------------------------------

start(normal, _StartArgs) ->
    ok = funnel_conf:init(),
    ok = load_mibs(),
    lager:info("funnel: starting up"),
    funnel_mib:send_coldstart_notification(),
    funnel_sup:start_link().

%% This function is called when ?APP application is about to be stopped,
%% before shutting down the processes of the application.
prep_stop(St) ->
    lager:info("funnel: stopping"),
    fun_smpp_server:stop(),
    St.

%% Perform necessary cleaning up *after* ?APP application has stopped.
stop(_St) ->
    unload_mibs(),
    lager:info("funnel: stopped").

config_change(_Changed, _New, _Removed) ->
    ok.

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

load_mibs() ->
    ok = otp_mib:load(snmp_master_agent),
    ok = os_mon_mib:load(snmp_master_agent),
    ok = snmpa:load_mibs(snmp_master_agent, [funnel_mib()]).

unload_mibs() ->
    snmpa:unload_mibs(snmp_master_agent, [funnel_mib()]),
    os_mon_mib:unload(snmp_master_agent),
    otp_mib:unload(snmp_master_agent).

funnel_mib() ->
    filename:join(code:priv_dir(?APP), "mibs/FUNNEL-MIB").
