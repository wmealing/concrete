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
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{id => concrete_pg,
          start => {pg, start_link, [concrete_pubsub]},
          restart => permanent, shutdown => 5000, type => worker, modules => [pg]},
        #{id => concrete_registry,
          start => {concrete_registry, start_link, []},
          restart => permanent, shutdown => 5000, type => worker, modules => [concrete_registry]}
    ],
    {ok, {SupFlags, Children}}.
