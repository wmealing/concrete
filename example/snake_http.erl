%% Plain HTTP handlers for the snake demo: the page (mints a session
%% secret and joins the game), the direction-input endpoint, and the
%% client's half of the heartbeat exchange (see snake_client.erl and
%% snake_sse_handler.erl for the server's half, sent down the SSE
%% stream itself). The SSE stream is a separate cowboy_loop handler --
%% see snake_sse_handler.
-module(snake_http).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, #{route := page} = State) ->
    %% Only mints the secret here -- the player doesn't actually join
    %% the game (spawn a snake) until its SSE connection opens, see
    %% snake_sse_handler:init/2.
    Secret = new_secret(),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/html; charset=utf-8">>},
        page_html(Secret), Req),
    {ok, Req2, State};
init(Req, #{route := input} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    {ok, #{<<"secret">> := Secret, <<"direction">> := DirBin}} = thoas:decode(Body),
    ok = snake_game:set_direction(Secret, binary_to_existing_atom(DirBin)),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>}, <<"{}">>, Req1),
    {ok, Req2, State};
init(Req, #{route := heartbeat} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    {ok, #{<<"secret">> := Secret}} = thoas:decode(Body),
    io:format("[snake_http] heartbeat <- ~s~n", [binary:part(Secret, 0, 8)]),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>}, <<"{}">>, Req1),
    {ok, Req2, State}.

%% A per-tab session credential, not just an identifier: it's the only
%% thing that authenticates the SSE stream and input POSTs as "the same
%% player" (see snake_game.erl's module header), so it has to be
%% unguessable, not just unique -- an incrementing counter would let
%% anyone hijack another open tab's snake by requesting a nearby id.
new_secret() ->
    to_hex(crypto:strong_rand_bytes(16)).

to_hex(Bin) ->
    <<<<(hex_digit(N div 16)), (hex_digit(N rem 16))>> || <<N>> <= Bin>>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N)              -> $a + N - 10.

%% The secret is only known at request time (one per page load), so --
%% like template_demo's page_shell -- the page is assembled here rather
%% than served as a static file, with the secret baked directly into
%% the boot call.
page_html(Secret) ->
    [
     """
     <!DOCTYPE html>
     <html lang="en">
     <head>
       <meta charset="UTF-8">
       <title>Concrete -- multiplayer snake</title>
       <link rel="stylesheet" href="/assets/theme.css">
       <style>
         .legend { max-width: 320px; margin: 1em auto 0; }
         .legend-row { display: flex; align-items: center; gap: 0.5em;
                       font-size: 0.85em; color: var(--text-dim); padding: 2px 0; }
         .swatch { width: 14px; height: 14px; border-radius: 3px;
                   border: 1px solid var(--border); flex: none; }
       </style>
     </head>
     <body>
       <a class="back-link" href="http://localhost:8760/">&larr; All demos</a>
       <p>A real Erlang <code>gen_server</code> (<code>snake_game.erl</code>) owns the board and ticks every worker's snake forward, broadcasting the new state to every connected browser over SSE. Open this page in another tab (or another browser) to play together -- everyone sees everyone else's snake move live.</p>
       <div style="text-align:center;">
         <canvas id="board" width="600" height="400"></canvas>
         <p id="status" class="sub"></p>
         <div id="legend" class="legend"></div>
       </div>
       <script src="/assets/runtime.js"></script>
       <script src="/assets/snake/snake_client.js"></script>
       <script>Interpreter.callTopLevel("snake_client", "start", 1, [Type.bitstring("
     """,
     Secret,
     """
     ")]);</script>
       <script src="http://localhost:8799/dev-reload.js"></script>
     </body>
     </html>
     """
    ].
