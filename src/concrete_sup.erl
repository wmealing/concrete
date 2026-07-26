%% Top-level supervisor: pg scope, asset manifest server, component registry.
-module(concrete_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

-spec start_link(map()) -> {ok, pid()}.
start_link(Manifest) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Manifest]).

init([Manifest]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{id => concrete_pg,
          start => {pg, start_link, [concrete_pubsub]},
          restart => permanent, shutdown => 5000, type => worker, modules => [pg]},
        #{id => concrete_assets,
          start => {concrete_assets, start_link, [Manifest]},
          restart => permanent, shutdown => 5000, type => worker, modules => [concrete_assets]},
        #{id => concrete_registry,
          start => {concrete_registry, start_link, []},
          restart => permanent, shutdown => 5000, type => worker, modules => [concrete_registry]}
    ],
    {ok, {SupFlags, Children}}.
