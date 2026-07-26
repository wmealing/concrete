%% Top-level supervisor: pg scope, component registry. Asset manifest
%% lookups (concrete_assets) are stateless disk reads, not a supervised
%% process.
-module(concrete_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% A live rebar3 shell recompile purges old module code, which can
    %% kill several of these children at once as part of the reload --
    %% not an actual failure. The default intensity (5 per 10s) is tuned
    %% for real crash loops and gets exhausted by a couple of dev-time
    %% recompiles, taking the whole supervision tree down. Widen it so
    %% routine recompiling doesn't trip max_restart_intensity.
    SupFlags = #{strategy => one_for_one, intensity => 50, period => 10},
    Children = [
        #{id => concrete_pg,
          start => {pg, start_link, [concrete_pubsub]},
          restart => permanent, shutdown => 5000, type => worker, modules => [pg]},
        #{id => concrete_registry,
          start => {concrete_registry, start_link, []},
          restart => permanent, shutdown => 5000, type => worker, modules => [concrete_registry]}
    ],
    {ok, {SupFlags, Children}}.
