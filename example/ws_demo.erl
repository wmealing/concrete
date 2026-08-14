%% Browser demo for real-time action/command dispatch over a raw
%% WebSocket connection -- see concrete_ws_handler.erl for the server
%% side of the wire protocol this page drives directly with a few lines
%% of hand-written JavaScript. There's no compiled bundle here; the
%% point of this demo is the WebSocket plumbing itself (concrete_ws_handler
%% -> concrete_runtime:dispatch_action/4 / dispatch_command/4 ->
%% ws_demo_page:action/3 / command/3), not the compiler pipeline the
%% other demos already cover.
%%
%% Start with: rebar3 as example shell
%% Then call:  ws_demo:serve().  %% http://localhost:8772
%% Click "+1 via command" a few times, then reload the page (or open it
%% in a second tab): the count picks up where it left off, because
%% ws_demo_counter is a real gen_server holding server-side state, not
%% anything stored in the browser.
-module(ws_demo).
-behaviour(cowboy_handler).

-export([serve/0, serve/1, init/2]).

serve() ->
    serve(8772).

serve(Port) ->
    ensure_counter_started(),
    {ok, _} = application:ensure_all_started(cowboy),
    TemplatesDir = filename:join(code:priv_dir(concrete), "templates"),
    application:set_env(concrete, templates_dir, TemplatesDir),
    DemoDir = filename:join([code:priv_dir(concrete), "js", "demo"]),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/",             ?MODULE,             #{}},
            {"/concrete/ws",  concrete_ws_handler, #{}},
            {"/assets/[...]", cowboy_static,
                {dir, DemoDir, [{mimetypes, cow_mimetypes, all}]}}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(ws_demo_http, [{port, Port}], #{
        env => #{dispatch => Dispatch}
    }),
    io:format("~nWebSocket demo running at http://localhost:~w~n", [Port]).

ensure_counter_started() ->
    case whereis(ws_demo_counter) of
        undefined -> {ok, _} = ws_demo_counter:start_link(), ok;
        _Pid      -> ok
    end.

init(Req, State) ->
    {HTML, _StateJSON, _Server} = concrete_renderer:render_page(ws_demo_page, #{}),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/html; charset=utf-8">>},
        page_shell(HTML), Req),
    {ok, Req2, State}.

%% unicode:characters_to_binary/1 re-encodes the em dash below (and any
%% other non-ASCII source text) into real UTF-8 bytes -- the plain
%% (non-<<>>) triple-quoted string it lives in is a charlist, so a
%% character above codepoint 255 would otherwise be an invalid iodata
%% element and crash cowboy_req:reply/4 (via iolist_size/1) at request
%% time instead of at compile time.
page_shell(HTML) ->
    unicode:characters_to_binary([
     """
     <!DOCTYPE html>
     <html lang="en">
     <head>
       <meta charset="UTF-8">
       <title>Concrete — WebSocket actions &amp; commands</title>
       <link rel="stylesheet" href="/assets/theme.css">
       <style>
         .ws-demo { max-width: 32rem; border: 1px solid var(--border);
                    border-radius: var(--radius); background: var(--bg-panel);
                    padding: 1rem 2rem; }
         #log { max-height: 12rem; overflow-y: auto; font-size: 0.8rem; }
       </style>
     </head>
     <body>
       <a class="back-link" href="http://localhost:8760/">&larr; All demos</a>
       <p>Both buttons send one JSON message over a single WebSocket connection
          to <code>/concrete/ws</code>. <code>concrete_ws_handler</code> decodes it and calls
          <code>concrete_runtime:dispatch_action/4</code> or <code>dispatch_command/4</code>,
          which run <code>ws_demo_page:action/3</code> or <code>command/3</code> on the
          server, then reply on the same socket. The command bumps a real,
          persistent counter (a gen_server) -- reload this page, or open it in a
          second tab, and it starts from wherever it was left.</p>
     """,
     HTML,
     script(),
     "</body>\n</html>\n"
    ]).

%% Hand-written wire-format helpers -- deliberately not the compiled
%% JS runtime (priv/js/demo/runtime.js): this demo shows that the
%% concrete_ws_handler wire protocol is plain JSON any client can
%% speak, not something that requires the compiler pipeline.
script() ->
    <<
      """
      <script>
        function wireAtom(v) { return {type: "atom", value: v}; }
        function wireInt(v) { return {type: "integer", value: v}; }
        function wireMap(pairs) {
          return {type: "map", data: pairs.map(function(p) { return [wireAtom(p[0]), p[1]]; })};
        }
        function wireGet(node, key) {
          if (!node || node.type !== "map") return null;
          var pair = node.data.find(function(p) { return p[0].type === "atom" && p[0].value === key; });
          return pair ? pair[1] : null;
        }
        var log = document.getElementById("log");
        function logLine(dir, text) {
          log.textContent += dir + " " + text + "\n";
          log.scrollTop = log.scrollHeight;
        }
        var proto = location.protocol === "https:" ? "wss:" : "ws:";
        var ws = new WebSocket(proto + "//" + location.host + "/concrete/ws");
        var echoCount = 1;
        ws.onmessage = function(ev) {
          logLine("<-", ev.data);
          var msg = JSON.parse(ev.data);
          if (msg.type === "command") {
            var count = wireGet(msg.state, "count");
            document.getElementById("count").textContent = count ? count.value : "?";
          } else if (msg.type === "action") {
            var state = wireGet(msg.state, "state");
            var count = wireGet(state, "count");
            echoCount = count ? count.value : echoCount;
            document.getElementById("echo").textContent = echoCount;
          }
        };
        function send(msg) {
          var text = JSON.stringify(msg);
          logLine("->", text);
          ws.send(text);
        }
        document.getElementById("bump").onclick = function() {
          send({type: "command", module: "ws_demo_page", command: "bump",
                params: {delta: 1}, state: wireMap([])});
        };
        document.getElementById("double").onclick = function() {
          send({type: "action", module: "ws_demo_page", action: "double",
                params: {}, state: wireMap([["state", wireMap([["count", wireInt(echoCount)]])]])});
        };
      </script>
      """
    >>.
