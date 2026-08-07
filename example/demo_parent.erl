%% Landing page that lists every example demo and starts each one on
%% its own port, so you can click through all of them from one place.
%%
%% Start with: rebar3 as example shell
%% Then call:  demo_parent:serve().   %% builds + starts every demo,
%%                                    %% then http://localhost:8760
%%
%% Each demo keeps its own cowboy listener on its own port (see
%% concrete_demo, template_demo, todo_demo, canvas_demo,
%% gen_server_demo, process_viz_demo) -- this module doesn't proxy
%% them, it just launches all of them and serves an index page of
%% links. Every demo's own page links back here.
-module(demo_parent).
-export([serve/0, serve/1, start_all/0, demos/0]).

demos() ->
    [
     #{id => counter, title => <<"Counter">>, port => 8765, module => concrete_demo,
       desc => <<"The smallest possible demo: a self-rescheduling counter loop, "
                 "pure Erlang compiled straight to JavaScript.">>},
     #{id => template, title => <<"Template / Scoreboard">>, port => 8766, module => template_demo,
       desc => <<"A .slab template rendered server-side on first load, then hydrated -- "
                 "button clicks dispatch to a compiled action/3 running in the browser.">>},
     #{id => todo, title => <<"Todo List">>, port => 8767, module => todo_demo,
       desc => <<"A small stateful app (add/complete/clear) persisted to localStorage, "
                 "entirely compiled Erlang -- no server round trips.">>},
     #{id => canvas, title => <<"Canvas Animation">>, port => 8768, module => canvas_demo,
       desc => <<"A self-scheduling animation loop drawing a rotating flower on "
                 "&lt;canvas&gt; via the canvas:* BIFs.">>},
     #{id => gen_server, title => <<"gen_server-style Process">>, port => 8769, module => gen_server_demo,
       desc => <<"A real spawn/self/!/receive generic-server loop (concrete_gen_server.erl) "
                 "dispatching into a callback module, running in the browser.">>},
     #{id => process_viz, title => <<"Process Ring (spawn/self/send/receive)">>, port => 8770,
       module => process_viz_demo,
       desc => <<"Six spawned worker processes passing a token around a ring, with a live "
                 "canvas visualization of every send/receive hop.">>},
     #{id => snake, title => <<"Multiplayer Snake">>, port => 8771, module => snake_demo,
       desc => <<"A real gen_server owns the board and broadcasts it over SSE to every "
                 "connected browser -- open it in two tabs and watch both snakes move live.">>},
     #{id => ws, title => <<"WebSocket Actions &amp; Commands">>, port => 8772, module => ws_demo,
       desc => <<"Plain JavaScript, no compiled bundle -- every click sends a real "
                 "action/command message over one WebSocket to concrete_ws_handler, "
                 "dispatched server-side. The counter is a gen_server, so it survives "
                 "a reload.">>},
     #{id => spirograph, title => <<"three.js Spirograph">>, port => 8773, module => spirograph_demo,
       desc => <<"A rotating, color-cycling spirograph drawn with three.js, loaded from a CDN "
                 "&lt;script&gt; tag -- every THREE.* call is compiled Erlang, reaching the "
                 "library through concrete_js, with no hand-written JavaScript at all.">>}
    ].

%% Build + start every demo's own cowboy listener, then serve the
%% index page linking to all of them. Safe to call more than once --
%% a demo (or the index) that's already listening is just skipped.
start_all() ->
    lists:foreach(fun(#{module := Mod, port := Port}) -> ensure_started(Mod, Port) end, demos()),
    ok.

serve() ->
    serve(8760).

serve(Port) ->
    start_all(),
    {ok, _} = application:ensure_all_started(cowboy),
    DemoDir   = filename:join([code:priv_dir(concrete), "js", "demo"]),
    IndexFile = filename:join(DemoDir, "index.html"),
    ok = file:write_file(IndexFile, render_index()),
    Dispatch  = cowboy_router:compile([
        {'_', [
            {"/",        cowboy_static, {file, IndexFile}},
            {"/[...]",   cowboy_static, {dir,  DemoDir, [{mimetypes, cow_mimetypes, all}]}}
        ]}
    ]),
    ensure_listener(demo_parent_http, Port, Dispatch),
    io:format("~nAll demos running. Open http://localhost:~w to click through them.~n", [Port]).

ensure_started(Mod, Port) ->
    try
        ok = Mod:serve(Port),
        io:format("~s running at http://localhost:~w~n", [Mod, Port])
    catch
        error:{badmatch, {error, {already_started, _}}} ->
            io:format("~s already running at http://localhost:~w~n", [Mod, Port])
    end.

ensure_listener(Ref, Port, Dispatch) ->
    case cowboy:start_clear(Ref, [{port, Port}], #{env => #{dispatch => Dispatch}}) of
        {ok, _}                            -> ok;
        {error, {already_started, _}}      -> cowboy:set_env(Ref, dispatch, Dispatch)
    end.

%% --- Index page ---

render_index() ->
    Cards = [render_card(D) || D <- demos()],
    unicode:characters_to_binary([
        <<"<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
          "  <meta charset=\"UTF-8\">\n"
          "  <title>Concrete -- demos</title>\n"
          "  <link rel=\"stylesheet\" href=\"/theme.css\">\n"
          "</head>\n<body>\n"
          "  <h1>Concrete demos</h1>\n"
          "  <p class=\"sub\">Every demo is pure Erlang, compiled to JavaScript, running in "
          "your browser. Each one listens on its own port.</p>\n">>,
        Cards,
        <<"</body>\n</html>\n">>
    ]).

render_card(#{title := Title, desc := Desc, port := Port}) ->
    Url = iolist_to_binary(io_lib:format("http://localhost:~w/", [Port])),
    [<<"  <div class=\"card\">\n    <h2>">>, Title, <<"</h2>\n    <p>">>, Desc,
     <<"</p>\n    <a href=\"">>, Url, <<"\">">>, Url, <<"</a>\n  </div>\n">>].
