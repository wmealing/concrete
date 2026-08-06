%% Page for the WebSocket demo (see ws_demo.erl). Every button click on
%% the page sends a real {"type": "action" | "command", ...} JSON
%% message over one live WebSocket connection to /concrete/ws.
%% concrete_ws_handler decodes it and calls concrete_runtime, which
%% dispatches to action/3 or command/3 below -- entirely server-side,
%% no compiled JS bundle involved.
-module(ws_demo_page).
-behaviour(concrete_page).
-concrete([{route, "/"}]).
-export([init/2, template/0, action/3, command/3]).

init(_Params, Server) ->
    Count = ws_demo_counter:value(),
    {#{state => #{count => Count, echo => 1}}, Server}.

template() ->
    "ws_demo.slab".

%% Runs server-side per {"type": "action"} message. Operates only on
%% whatever component state the browser sent up in that one message --
%% nothing here persists between messages.
action(double, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count := N * 2}}.

%% Runs server-side per {"type": "command"} message. Bumps the one
%% shared, persistent counter every connected browser reads on page
%% load (see ws_demo_counter).
command(bump, #{<<"delta">> := Delta}, Server) ->
    NewCount = ws_demo_counter:bump(Delta),
    Server#{count => NewCount}.
