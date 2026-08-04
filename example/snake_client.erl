%% Browser half of the multiplayer snake demo: pure Erlang compiled to
%% JS, with no game logic of its own. It just connects to the SSE
%% stream (see snake_sse_handler.erl) and, on every board broadcast
%% from the authoritative snake_game gen_server, redraws the whole
%% board on <canvas>; arrow keys POST a direction change back to the
%% server (see snake_http.erl) via http:post_json/2. Every connected
%% browser runs this same loop, which is why every tab sees every
%% player's snake move in lockstep.
-module(snake_client).
-export([start/1, on_board/1, key_up/0, key_down/0, key_left/0, key_right/0,
         heartbeat_tick/1]).

-define(CANVAS, <<"board">>).
-define(CELL, 20).
-define(HEARTBEAT_MS, 10000).

%% Secret is this tab's private session credential (see snake_game.erl
%% and snake_http.erl) -- sse:connect/3 hangs onto it internally and
%% reconnects with it automatically if the stream drops (see
%% runtime.js), which is what resumes this same snake instead of
%% spawning a new one. "my_color" is learned from the first board
%% broadcast (see on_board/1) and cached the same way, so the client
%% can tell its own snake apart from everyone else's without the
%% server ever having to broadcast whose is whose to the group.
start(Secret) ->
    ui:set(<<"secret">>, Secret),
    sse:connect(<<"/snake/events/", Secret/binary>>, snake_client, on_board),
    %% Global, not scoped to the canvas: browsers don't reliably focus a
    %% <canvas> even with tabindex/autofocus, so a focus-scoped listener
    %% would silently never fire. See dom:on_keydown_global/3.
    dom:on_keydown_global(<<"ArrowUp">>, snake_client, key_up),
    dom:on_keydown_global(<<"ArrowDown">>, snake_client, key_down),
    dom:on_keydown_global(<<"ArrowLeft">>, snake_client, key_left),
    dom:on_keydown_global(<<"ArrowRight">>, snake_client, key_right),
    %% This tab's half of the heartbeat exchange -- entirely
    %% independent of the server's own heartbeat down the SSE stream
    %% (see snake_sse_handler.erl); the two aren't synchronized.
    dom:set_timeout(?HEARTBEAT_MS, snake_client, heartbeat_tick, [Secret]),
    ok.

heartbeat_tick(Secret) ->
    debug:log(<<"heartbeat -> server">>),
    http:post_json(<<"/snake/heartbeat">>, #{<<"secret">> => Secret}),
    dom:set_timeout(?HEARTBEAT_MS, snake_client, heartbeat_tick, [Secret]).

key_up()    -> post_direction(<<"up">>).
key_down()  -> post_direction(<<"down">>).
key_left()  -> post_direction(<<"left">>).
key_right() -> post_direction(<<"right">>).

post_direction(Dir) ->
    Secret = ui:get(<<"secret">>),
    http:post_json(<<"/snake/input">>,
        #{<<"secret">> => Secret, <<"direction">> => Dir}).

%% The SSE stream carries two shapes of message: the regular board
%% broadcast (a map, handled below) and the server's own heartbeat (a
%% {heartbeat, N} tuple -- see snake_sse_handler.erl), which this just
%% logs; it isn't otherwise part of the board's rendering.
on_board({heartbeat, N}) ->
    debug:log(<<"heartbeat <- server #", (integer_to_binary(N))/binary>>);
%% Called once per board broadcast (see snake_sse_handler.erl), with
%% Board already deserialized straight into a term matching
%% snake_game:board_term/1 (plus a one-off my_color key on the very
%% first message -- see snake_sse_handler:init/2).
on_board(Board) ->
    case maps:find(my_color, Board) of
        {ok, Color} -> ui:set(<<"my_color">>, Color);
        error -> ok
    end,
    MyColor = ui:get(<<"my_color">>),
    canvas:clear(?CANVAS),
    draw_food(maps:get(food, Board)),
    Players = maps:get(players, Board),
    lists:foreach(fun(P) -> draw_player(P, MyColor) end, Players),
    dom:set_text(<<"status">>,
        <<(integer_to_binary(alive_count(Players)))/binary,
          " snake(s) alive -- use the arrow keys">>),
    dom:set_html(<<"legend">>, legend_html(Players, MyColor)).

draw_player({_Hue, _Body, false, _LastSeenMs}, _MyColor) ->
    ok;
draw_player({Hue, Body, true, _LastSeenMs}, MyColor) ->
    case Hue =:= MyColor of
        true  -> lists:foreach(fun(Cell) -> draw_glow_cell(Cell, Hue) end, Body);
        false -> lists:foreach(fun(Cell) -> draw_cell(Cell, Hue, 80, 55) end, Body)
    end.

draw_food(Cell) ->
    draw_cell(Cell, 0, 90, 60).

draw_cell({X, Y}, Hue, Sat, Light) ->
    canvas:set_fill_hsl(?CANVAS, Hue, Sat, Light),
    canvas:fill_rect(?CANVAS, X * ?CELL, Y * ?CELL, ?CELL - 1, ?CELL - 1).

%% This runtime's canvas BIFs have no shadow/blur primitive, so the
%% "glow" is a bright halo rect drawn slightly larger and behind the
%% normal-colored cell on top of it.
draw_glow_cell({X, Y} = Cell, Hue) ->
    canvas:set_fill_hsl(?CANVAS, Hue, 100, 85),
    canvas:fill_rect(?CANVAS, X * ?CELL - 3, Y * ?CELL - 3, ?CELL + 5, ?CELL + 5),
    draw_cell(Cell, Hue, 90, 60).

alive_count(Players) ->
    length([ok || {_Hue, _Body, true, _LastSeenMs} <- Players]).

%% One row per currently-connected snake: a color swatch matching what
%% it's drawn as on the canvas, plus how long ago it last
%% joined/reconnected (see snake_game.erl's board_term/1), plus "(you)"
%% on whichever row is this tab's own snake.
legend_html(Players, MyColor) ->
    lists:foldl(fun(P, Acc) -> <<Acc/binary, (legend_row(P, MyColor))/binary>> end, <<>>, Players).

legend_row({Hue, _Body, Alive, LastSeenMs}, MyColor) ->
    You = case Hue =:= MyColor of
        true  -> <<" (you)">>;
        false -> <<>>
    end,
    <<"<div class=\"legend-row\"><span class=\"swatch\" style=\"background:hsl(",
      (integer_to_binary(Hue))/binary, ",80%,55%)\"></span> ",
      (status_label(Alive))/binary, You/binary, " -- last connected ",
      (ago_text(LastSeenMs))/binary, "</div>">>.

status_label(true)  -> <<"alive">>;
status_label(false) -> <<"respawning">>.

ago_text(Ms) when Ms < 1000 ->
    <<"just now">>;
ago_text(Ms) ->
    <<(integer_to_binary(Ms div 1000))/binary, "s ago">>.
