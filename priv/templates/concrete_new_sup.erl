-module({{name}}_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% Widened from the OTP default (5 per 10s): a live rebar3 shell
    %% recompile purges old module code, which can kill several children
    %% at once as part of the reload, not an actual crash loop -- the
    %% tighter default gets exhausted by routine dev-time recompiling.
    {ok, {#{strategy => one_for_one, intensity => 50, period => 10}, []}}.
