%% Browser three.js demo: draws an animated, rotating spirograph
%% (hypotrochoid) curve, compiled straight from Erlang to JavaScript.
%% Every three.js call -- building the scene, the camera, the
%% renderer, the curve geometry, and the per-frame rotation -- goes
%% through concrete_js, calling into three.js loaded from a CDN
%% <script> tag (see priv/js/demo/spirograph/index.html). Nothing here
%% is a hand-written BIF the way canvas_app.erl's canvas:* calls are;
%% concrete_js needed no compiler support to make this possible -- see
%% CONCRETE 005: JavaScript Interop for why.
%%
%% Start with: rebar3 as example shell
%% Then call:  spirograph_demo:build().  %% compiles this module to spirograph_app.js
%%             spirograph_demo:serve().  %% http://localhost:8773
-module(spirograph_app).
-include("concrete_js.hrl").
-export([start/0, tick/2]).

-define(CONTAINER, <<"three-container">>).

%% Hypotrochoid parameters: a circle of radius ?R_SMALL rolling inside
%% a fixed circle of radius ?R, tracing a point ?D from its own center.
%% Think gear teeth, the way a real Spirograph works: ?R and ?R_SMALL
%% only ever matter through their difference and their ratio, never as
%% absolute sizes, the same way a 36-tooth ring and a 35-tooth wheel
%% describe a shape regardless of how big the actual gears are. Picking
%% them close together, one tooth apart, is what turns the curve from a
%% simple few-petaled flower into the dense braided ring a real
%% Spirograph draws with adjacent gears: ?R - ?R_SMALL becomes a small,
%% fast wobble, ?D becomes the big, slow sweep that actually sets the
%% ring's radius, and the two together trace many thin overlapping
%% loops around a hollow center instead of a handful of fat petals.
%%
%% The curve closes after gcd(?R, ?R_SMALL) / ?R_SMALL full turns
%% around the center -- ?LOOPS exists so that number is chosen on
%% purpose, not left to fall out of ?R and ?R_SMALL by accident. Get it
%% wrong (too low, or too high with T_MAX not adjusted to match) and
%% the curve either never closes, or spends half its points retracing
%% a shape it already finished drawing -- which reads as "one loop" no
%% matter how many turns T_MAX actually sweeps through.
-define(R, 540).
-define(R_SMALL, 525).
-define(D, 110).
-define(LOOPS, 35).
-define(POINTS, 6000).
-define(T_MAX, (?LOOPS * 2 * math:pi())).

start() ->
    Scene            = ?js:new('THREE.Scene', []),
    Camera           = build_camera(),
    Renderer         = build_renderer(),
    {Line, Material} = build_spirograph_line(),
    ?js:call(Scene, add, [Line]),
    World = #{line => Line, scene => Scene, camera => Camera,
              renderer => Renderer, material => Material},
    tick(World, 0.0).

%% One animation frame: spin the whole curve a little further around
%% its own center, cycle the line color through the color wheel, render,
%% and schedule the next frame -- the same self-rescheduling shape
%% canvas_app:tick/1 uses, just driving three.js instead of Canvas2D.
tick(World, Angle) ->
    #{line := Line, scene := Scene, camera := Camera,
      renderer := Renderer, material := Material} = World,
    Rotation = ?js:get(Line, <<"rotation">>),
    ?js:set(Rotation, <<"z">>, Angle),
    Color = ?js:get(Material, <<"color">>),
    ?js:call(Color, <<"setHSL">>, [hue(Angle), 0.8, 0.65]),
    ?js:call(Renderer, <<"render">>, [Scene, Camera]),
    dom:set_timeout(16, spirograph_app, tick, [World, Angle + 0.006]).

hue(Angle) ->
    Turns = Angle / (2 * math:pi()),
    Turns - trunc(Turns).

build_camera() ->
    Camera = ?js:new('THREE.PerspectiveCamera', [45, 1.0, 1, 2000]),
    Position = ?js:get(Camera, <<"position">>),
    ?js:set(Position, <<"z">>, 420),
    Camera.

build_renderer() ->
    Renderer = ?js:new('THREE.WebGLRenderer', [#{antialias => true}]),
    ?js:call(Renderer, <<"setSize">>, [600, 600]),
    ?js:call(Renderer, <<"setClearColor">>, [16#0A0A14, 1]),
    Container = ?js:call(<<"document">>, <<"getElementById">>, [?CONTAINER]),
    DomEl = ?js:get(Renderer, <<"domElement">>),
    ?js:call(Container, <<"appendChild">>, [DomEl]),
    Renderer.

build_spirograph_line() ->
    Points = [?js:new('THREE.Vector3', [X, Y, 0.0]) || {X, Y} <- spirograph_points()],
    Geometry = ?js:new('THREE.BufferGeometry', []),
    ?js:call(Geometry, <<"setFromPoints">>, [Points]),
    Material = ?js:new('THREE.LineBasicMaterial', [#{color => 16#9CCCFF}]),
    Line = ?js:new('THREE.Line', [Geometry, Material]),
    {Line, Material}.

spirograph_points() ->
    Step = ?T_MAX / ?POINTS,
    [spirograph_point(N * Step) || N <- lists:seq(0, ?POINTS)].

spirograph_point(T) ->
    Ratio = (?R - ?R_SMALL) / ?R_SMALL,
    X = (?R - ?R_SMALL) * math:cos(T) + ?D * math:cos(Ratio * T),
    Y = (?R - ?R_SMALL) * math:sin(T) - ?D * math:sin(Ratio * T),
    {X, Y}.
