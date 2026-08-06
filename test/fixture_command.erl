%% Test fixture: a page module with a server-side command, used by
%% ws_handler_SUITE and mirroring what concrete_command_handler already
%% exercises over HTTP.
-module(fixture_command).
-export([init/2, template/0, command/3]).

init(_Params, Server) ->
    {#{state => #{}}, Server}.

template() ->
    {inline, []}.

command(save, #{<<"value">> := Value}, Server) ->
    Server#{saved => Value}.
