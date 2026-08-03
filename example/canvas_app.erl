%% Browser canvas demo. Pure Erlang, compiled to JavaScript, running a
%% self-scheduling animation loop against an HTML5 <canvas> element via
%% the canvas:* BIFs in priv/js/demo/runtime.js. No JS glue beyond the
%% one-line bootstrap in canvas_app.js.
%%
%% Start with: rebar3 as example shell
%% Then call:  canvas_demo:build().  %% compiles this module to canvas_app.js
%%             canvas_demo:serve().  %% http://localhost:8768
-module(canvas_app).
-export([start/0, tick/1]).

-define(CANVAS, <<"canvas">>).
-define(PETALS, 48).

start() ->
    tick(0).

%% One animation frame: fade the previous frame slightly (instead of a
%% hard clear) to leave a comet-trail behind each petal, draw the
%% rotating flower at time N, then schedule the next frame.
tick(N) ->
    fade(),
    draw_flower(N),
    dom:set_timeout(30, canvas_app, tick, [N + 1]).

fade() ->
    W = canvas:width(?CANVAS),
    H = canvas:height(?CANVAS),
    canvas:set_fill_rgba(?CANVAS, 10, 10, 20, 0.12),
    canvas:fill_rect(?CANVAS, 0, 0, W, H).

%% Draw ?PETALS circles arranged around the canvas center. Each petal's
%% angle and radius are both functions of N, so the whole flower spins
%% and breathes; each petal's hue drifts with N and its own index, so
%% the colors cycle as it rotates.
draw_flower(N) ->
    Cx = canvas:width(?CANVAS) / 2,
    Cy = canvas:height(?CANVAS) / 2,
    lists:foreach(fun(I) -> draw_petal(N, I, Cx, Cy) end, lists:seq(0, ?PETALS - 1)).

draw_petal(N, I, Cx, Cy) ->
    Turns = N / 90,
    Angle = Turns + (I * 2 * math:pi() / ?PETALS),
    Radius = 110 + 70 * math:sin(N / 45 + I / 4),
    X = Cx + Radius * math:cos(Angle),
    Y = Cy + Radius * math:sin(Angle),
    Hue = (trunc(I * 360 / ?PETALS) + N) rem 360,
    canvas:set_stroke_hsl(?CANVAS, Hue, 85, 60),
    canvas:set_line_width(?CANVAS, 2),
    canvas:begin_path(?CANVAS),
    canvas:arc(?CANVAS, X, Y, 16, 0, 2 * math:pi()),
    canvas:stroke(?CANVAS).
