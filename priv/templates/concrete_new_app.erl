-module({{name}}_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    %% concrete is a required application (see {{name}}.app.src), so it has
    %% already started by the time this runs; its listen port comes from
    %% config/sys.config, read before boot -- see the `concrete` env there.
    {ok, _} = application:ensure_all_started(concrete),
    {{name}}_sup:start_link().

stop(_State) -> ok.
