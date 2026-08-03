%% Plain HTTP handlers for the snake demo: the page (mints a player id
%% and joins the game) and the direction-input endpoint. The SSE stream
%% itself is a separate cowboy_loop handler -- see snake_sse_handler.
-module(snake_http).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, #{route := page} = State) ->
    %% Only mints the id here -- the player doesn't actually join the
    %% game (spawn a snake) until its SSE connection opens, see
    %% snake_sse_handler:init/2.
    PlayerId = new_player_id(),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/html; charset=utf-8">>},
        page_html(PlayerId), Req),
    {ok, Req2, State};
init(Req, #{route := input} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    {ok, #{<<"player_id">> := PlayerId, <<"direction">> := DirBin}} = thoas:decode(Body),
    ok = snake_game:set_direction(PlayerId, binary_to_existing_atom(DirBin)),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>}, <<"{}">>, Req1),
    {ok, Req2, State}.

new_player_id() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).

%% The player id is only known at request time (one per page load), so
%% -- like template_demo's page_shell -- the page is assembled here
%% rather than served as a static file, with the id baked directly into
%% the boot call.
page_html(PlayerId) ->
    [<<"<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
       "  <meta charset=\"UTF-8\">\n"
       "  <title>Concrete -- multiplayer snake</title>\n"
       "  <link rel=\"stylesheet\" href=\"/assets/theme.css\">\n"
       "</head>\n<body>\n"
       "  <a class=\"back-link\" href=\"http://localhost:8760/\">&larr; All demos</a>\n"
       "  <p>A real Erlang <code>gen_server</code> (<code>snake_game.erl</code>) owns the "
       "board and ticks every worker's snake forward, broadcasting the new state to every "
       "connected browser over SSE. Open this page in another tab (or another browser) to "
       "play together -- everyone sees everyone else's snake move live.</p>\n"
       "  <div style=\"text-align:center;\">\n"
       "    <canvas id=\"board\" width=\"600\" height=\"400\"></canvas>\n"
       "    <p id=\"status\" class=\"sub\"></p>\n"
       "  </div>\n"
       "  <script src=\"/assets/runtime.js\"></script>\n"
       "  <script src=\"/assets/snake/snake_client.js\"></script>\n"
       "  <script>Interpreter.callTopLevel(\"snake_client\", \"start\", 1, "
       "[Type.bitstring(\"">>, PlayerId, <<"\")]);</script>\n"
       "</body>\n</html>\n">>].
