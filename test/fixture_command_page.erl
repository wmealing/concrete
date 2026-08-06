%% Test fixture: a page with a declarative concrete-command button --
%% used by client_SUITE to prove the client-side command dispatch path
%% (as opposed to fixture_command.erl, exercised over real HTTP by
%% ws_handler_SUITE's WebSocket path).
-module(fixture_command_page).
-export([init/2, template/0, command/3]).

init(_Props, Server) ->
    {#{state => #{count => 0}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<p>count: {@count}</p>"
        "<button concrete-command=\"bump\">+</button>")}.

command(bump, _Params, Server) ->
    Server#{count => 41}.
