%% Browser half of the multiplayer snake demo: pure Erlang compiled to
%% JS, with no game logic of its own. It just connects to the SSE
%% stream (see snake_sse_handler.erl) and, on every board broadcast
%% from the authoritative snake_game gen_server, redraws the whole
%% board on <canvas>; arrow keys POST a direction change back to the
%% server (see snake_http.erl) via http:post_json/2. Every connected
%% browser runs this same loop, which is why every tab sees every
%% player's snake move in lockstep.
-module(snake_client).
-export([start/1, on_board/1, key_up/0, key_down/0, key_left/0, key_right/0]).

-define(CANVAS, <<"board">>).
-define(CELL, 20).

%% Secret is this tab's private session credential (see snake_game.erl
%% and snake_http.erl) -- sse:connect/3 hangs onto it internally and
%% reconnects with it automatically if the stream drops (see
%% runtime.js), which is what resumes this same snake instead of
%% spawning a new one.
start(Secret) ->
    ui:set_pid(Secret),
    sse:connect(<<"/snake/events/", Secret/binary>>, snake_client, on_board),
    %% Global, not scoped to the canvas: browsers don't reliably focus a
    %% <canvas> even with tabindex/autofocus, so a focus-scoped listener
    %% would silently never fire. See dom:on_keydown_global/3.
    dom:on_keydown_global(<<"ArrowUp">>, snake_client, key_up),
    dom:on_keydown_global(<<"ArrowDown">>, snake_client, key_down),
    dom:on_keydown_global(<<"ArrowLeft">>, snake_client, key_left),
    dom:on_keydown_global(<<"ArrowRight">>, snake_client, key_right),
    ok.

key_up()    -> post_direction(<<"up">>).
key_down()  -> post_direction(<<"down">>).
key_left()  -> post_direction(<<"left">>).
key_right() -> post_direction(<<"right">>).

post_direction(Dir) ->
    Secret = ui:get_pid(),
    http:post_json(<<"/snake/input">>,
        #{<<"secret">> => Secret, <<"direction">> => Dir}).

%% Called once per board broadcast (see snake_sse_handler.erl), with
%% Board already deserialized straight into a term matching
%% snake_game:board_term/1.
on_board(Board) ->
    canvas:clear(?CANVAS),
    draw_food(maps:get(food, Board)),
    Players = maps:get(players, Board),
    lists:foreach(fun draw_player/1, Players),
    dom:set_text(<<"status">>,
        <<(integer_to_binary(alive_count(Players)))/binary,
          " snake(s) alive -- use the arrow keys">>),
    dom:set_html(<<"legend">>, legend_html(Players)).

draw_player({_Hue, _Body, false, _LastSeenMs}) ->
    ok;
draw_player({Hue, Body, true, _LastSeenMs}) ->
    lists:foreach(fun(Cell) -> draw_cell(Cell, Hue, 80, 55) end, Body).

draw_food(Cell) ->
    draw_cell(Cell, 0, 90, 60).

draw_cell({X, Y}, Hue, Sat, Light) ->
    canvas:set_fill_hsl(?CANVAS, Hue, Sat, Light),
    canvas:fill_rect(?CANVAS, X * ?CELL, Y * ?CELL, ?CELL - 1, ?CELL - 1).

alive_count(Players) ->
    length([ok || {_Hue, _Body, true, _LastSeenMs} <- Players]).

%% One row per currently-connected snake: a color swatch matching what
%% it's drawn as on the canvas, plus how long ago it last
%% joined/reconnected (see snake_game.erl's board_term/1).
legend_html(Players) ->
    lists:foldl(fun(P, Acc) -> <<Acc/binary, (legend_row(P))/binary>> end, <<>>, Players).

legend_row({Hue, _Body, Alive, LastSeenMs}) ->
    <<"<div class=\"legend-row\"><span class=\"swatch\" style=\"background:hsl(",
      (integer_to_binary(Hue))/binary, ",80%,55%)\"></span> ",
      (status_label(Alive))/binary, " -- last connected ",
      (ago_text(LastSeenMs))/binary, "</div>">>.

status_label(true)  -> <<"alive">>;
status_label(false) -> <<"respawning">>.

ago_text(Ms) when Ms < 1000 ->
    <<"just now">>;
ago_text(Ms) ->
    <<(integer_to_binary(Ms div 1000))/binary, "s ago">>.
