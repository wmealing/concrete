%% SSE stream for the snake demo: joins the game (spawning this
%% player's snake) the moment the connection opens, subscribes to the
%% shared snake_board pubsub channel, and relays every broadcast (see
%% snake_game:step/1) to the browser as a Server-Sent Event, type
%% -tagged the same way concrete_sse_handler does. Cleanup when the tab
%% closes is handled by snake_game itself (it monitors this process --
%% see snake_game:join/2), not a terminate/3 callback here: cowboy
%% doesn't guarantee terminate/3 runs when a loop handler's peer just
%% vanishes mid-stream.
%%
%% Also sends a {heartbeat, N} event down this same stream every
%% ?HEARTBEAT_MS, independent of board broadcasts (which already keep
%% the connection busy on their own -- this exists as an observable
%% "is this specific pair still talking" signal, not as a keepalive).
%% snake_client.erl sends its own independent heartbeat back to the
%% server over HTTP (see snake_http.erl's heartbeat route); the two
%% directions are deliberately not synchronized with each other.
-module(snake_sse_handler).
-behaviour(cowboy_loop).

-export([init/2, info/3]).

-define(HEARTBEAT_MS, 10000).

init(Req, State) ->
    Secret = cowboy_req:binding(secret, Req),
    {ok, MyColor} = snake_game:join(Secret, self()),
    concrete_pubsub:subscribe(snake_board, self()),
    Req2 = cowboy_req:stream_reply(200,
        #{<<"content-type">>  => <<"text/event-stream">>,
          <<"cache-control">> => <<"no-cache">>}, Req),
    %% An immediate snapshot so the client can draw before the next
    %% tick -- and, only this once, this connection's own color, so it
    %% can tell its snake apart from everyone else's (board_term/1
    %% never broadcasts whose is whose to the group at large).
    InitialBoard = (snake_game:board())#{my_color => MyColor},
    send_board(Req2, InitialBoard),
    erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
    {cowboy_loop, Req2, State#{secret => Secret, heartbeat_count => 0}}.

info({concrete_event, Board}, Req, State) ->
    send_board(Req, Board),
    {ok, Req, State};
info(heartbeat, Req, #{secret := Secret, heartbeat_count := N} = State) ->
    N2 = N + 1,
    send_heartbeat(Req, N2),
    io:format("[snake_sse] heartbeat #~p -> ~s~n", [N2, binary:part(Secret, 0, 8)]),
    erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
    {ok, Req, State#{heartbeat_count := N2}};
info(_Msg, Req, State) ->
    {ok, Req, State}.

send_board(Req, Board) ->
    Data = thoas:encode(concrete_serializer:encode(Board)),
    cowboy_req:stream_body(["data: ", Data, "\n\n"], nofin, Req).

send_heartbeat(Req, N) ->
    Data = thoas:encode(concrete_serializer:encode({heartbeat, N})),
    cowboy_req:stream_body(["data: ", Data, "\n\n"], nofin, Req).
