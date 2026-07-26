-module({{name}}_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, _} = application:ensure_all_started(concrete),
    {{name}}_sup:start_link().

stop(_State) -> ok.
