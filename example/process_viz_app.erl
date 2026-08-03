%% Browser demo of spawn/self/!/receive, with a live visualization.
%% Pure Erlang, compiled to JavaScript, running real message-passing
%% processes against the runtime's cooperative process model (see
%% Interpreter.spawnProcess/send/receiveMatch in runtime.js).
%%
%% Six worker processes are spawned in a ring. Each holds a pid to the
%% "next" worker (learned via a one-off {configure, ...} message after
%% all six are spawned -- pids aren't known until spawn/1 returns, so
%% the ring can't be wired up any earlier). Clicking "Start" sends a
%% {token, N, HopsLeft} message to worker 1; each worker that receives
%% the token draws the whole ring on <canvas> (idle workers as dim
%% circles, itself lit up, a line to whoever it's forwarding to),
%% logs the hop, and -- unless the token has run out of hops --
%% schedules the next hop with dom:set_timeout so you can watch it
%% travel around the ring one step at a time.
%%
%% "Poll workers" is a second, independent demonstration: it sends
%% {self(), stats} to every worker and blocks in receive for each
%% reply in turn -- a classic synchronous call/reply round trip. Since
%% workers reply the instant they're sent to (send steps its target
%% synchronously), the replies are already sitting in the mailbox by
%% the time the ephemeral polling process reaches its own receive
%% (see Interpreter.runEphemeral's doc comment in runtime.js).
%%
%% Start with: rebar3 as example shell
%% Then call:  process_viz_demo:build().  %% compiles this module
%%             process_viz_demo:serve().  %% http://localhost:8770
-module(process_viz_app).
-export([start/0, click/1, forward/3]).

-define(CANVAS, <<"ring">>).
-define(WORKERS, 6).
-define(RADIUS, 130).
-define(NODE_R, 22).

%% --- Boot ---

start() ->
    dom:on_click(<<"viz-root">>, <<"data-action">>, process_viz_app, click),
    Positions = positions(?WORKERS),
    Pids = spawn_workers(?WORKERS),
    configure_ring(Pids, Positions),
    ui:set_pid({Pids, Positions}),
    draw(Positions, none, none),
    log(<<"Ring of 6 worker processes ready. Click Start to send the token.">>),
    ok.

click(<<"start">>) ->
    {Pids, _Positions} = ui:get_pid(),
    [First | _] = Pids,
    log(<<"Sending {token, 1, HopsLeft} to worker 1 ...">>),
    First ! {token, 1, 17};
click(<<"poll">>) ->
    {Pids, _Positions} = ui:get_pid(),
    log(<<"--- polling every worker via self()/receive ---">>),
    lists:foreach(fun poll_one/1, Pids).

poll_one(Pid) ->
    Pid ! {self(), stats},
    receive
        {stats, Id, Handled} ->
            log(<<"worker ", (integer_to_binary(Id))/binary, " has handled ",
                  (integer_to_binary(Handled))/binary, " token hop(s)">>)
    end.

%% --- Ring geometry ---

%% Positions of N points evenly spaced around a circle centered on the
%% canvas, as {X, Y} pixel pairs (index order == worker id order).
positions(N) ->
    Cx = 180, Cy = 180,
    [begin
         Angle = 2 * math:pi() * I / N,
         X = Cx + trunc(?RADIUS * math:cos(Angle)),
         Y = Cy + trunc(?RADIUS * math:sin(Angle)),
         {X, Y}
     end || I <- lists:seq(0, N - 1)].

%% --- Spawning & wiring the ring ---

spawn_workers(N) ->
    [spawn(fun() -> worker(Id) end) || Id <- lists:seq(1, N)].

%% Worker Id's neighbor is the next id around the ring, wrapping back
%% to 1 after the last one.
configure_ring(Pids, Positions) ->
    N = length(Pids),
    lists:foreach(fun(I) ->
        Pid  = lists:nth(I, Pids),
        Next = lists:nth((I rem N) + 1, Pids),
        Pid ! {configure, Next, Positions}
    end, lists:seq(1, N)).

%% --- Worker process ---

worker(Id) ->
    receive
        {configure, Next, Positions} -> worker_loop(Id, Next, Positions, 0)
    end.

worker_loop(Id, Next, Positions, Handled) ->
    receive
        {token, N, HopsLeft} ->
            Handled2 = Handled + 1,
            draw(Positions, Id, next_index(Id, length(Positions))),
            log(<<"worker ", (integer_to_binary(Id))/binary, " received token #",
                  (integer_to_binary(N))/binary, " (", (integer_to_binary(HopsLeft))/binary,
                  " hop(s) left)">>),
            case HopsLeft of
                0 ->
                    log(<<"token journey complete.">>);
                _ ->
                    dom:set_timeout(450, process_viz_app, forward, [Next, N + 1, HopsLeft - 1])
            end,
            worker_loop(Id, Next, Positions, Handled2);
        {From, stats} ->
            From ! {stats, Id, Handled},
            worker_loop(Id, Next, Positions, Handled)
    end.

next_index(Id, N) -> (Id rem N) + 1.

%% Scheduled via dom:set_timeout so each hop is its own animation
%% frame; forwarding the token is just an ordinary send to whichever
%% worker is already blocked waiting for it.
forward(Pid, N, HopsLeft) ->
    Pid ! {token, N, HopsLeft},
    ok.

%% --- Drawing ---

%% Redraw the whole ring: every worker as a dim circle, the currently
%% active one lit up, and (if forwarding) a line to its neighbor.
%% ActiveId/NextId are `none` for the initial idle frame.
draw(Positions, ActiveId, NextId) ->
    canvas:clear(?CANVAS),
    lists:foreach(fun(I) ->
        {X, Y} = lists:nth(I, Positions),
        case ActiveId =/= none andalso I =:= ActiveId of
            true  -> set_active_style();
            false -> set_idle_style()
        end,
        canvas:begin_path(?CANVAS),
        canvas:arc(?CANVAS, X, Y, ?NODE_R, 0, 2 * math:pi()),
        canvas:fill(?CANVAS),
        canvas:stroke(?CANVAS)
    end, lists:seq(1, length(Positions))),
    case ActiveId of
        none -> ok;
        _    -> draw_link(Positions, ActiveId, NextId)
    end.

draw_link(Positions, FromId, ToId) ->
    {Fx, Fy} = lists:nth(FromId, Positions),
    {Tx, Ty} = lists:nth(ToId, Positions),
    canvas:set_stroke_hsl(?CANVAS, 45, 90, 60),
    canvas:set_line_width(?CANVAS, 3),
    canvas:begin_path(?CANVAS),
    canvas:move_to(?CANVAS, Fx, Fy),
    canvas:line_to(?CANVAS, Tx, Ty),
    canvas:stroke(?CANVAS).

set_idle_style() ->
    canvas:set_fill_hsl(?CANVAS, 220, 30, 30),
    canvas:set_stroke_hsl(?CANVAS, 220, 30, 55),
    canvas:set_line_width(?CANVAS, 2).

set_active_style() ->
    canvas:set_fill_hsl(?CANVAS, 45, 90, 55),
    canvas:set_stroke_hsl(?CANVAS, 45, 90, 75),
    canvas:set_line_width(?CANVAS, 3).

%% --- Logging ---

log(Msg) ->
    dom:append_html(<<"viz-log">>, <<"<div>", Msg/binary, "</div>">>).
