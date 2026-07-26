-module({{name}}_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    %% concrete_router reads its listen port from the `concrete` app's own
    %% env, not this app's — set it before starting concrete so it takes.
    ok = application:set_env(concrete, port, {{port}}),
    {ok, _} = application:ensure_all_started(concrete),
    {{name}}_sup:start_link().

stop(_State) -> ok.
