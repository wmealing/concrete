%% SSE stream for the snake demo: joins the game (spawning this
%% player's snake) the moment the connection opens, subscribes to the
%% shared snake_board pubsub channel, and relays every broadcast (see
%% snake_game:step/1) to the browser as a Server-Sent Event, type
%% -tagged the same way concrete_sse_handler does. Cleanup when the tab
%% closes is handled by snake_game itself (it monitors this process --
%% see snake_game:join/2), not a terminate/3 callback here: cowboy
%% doesn't guarantee terminate/3 runs when a loop handler's peer just
%% vanishes mid-stream.
-module(snake_sse_handler).
-behaviour(cowboy_loop).

-export([init/2, info/3]).

init(Req, State) ->
    PlayerId = cowboy_req:binding(player_id, Req),
    ok = snake_game:join(PlayerId, self()),
    concrete_pubsub:subscribe(snake_board, self()),
    Req2 = cowboy_req:stream_reply(200,
        #{<<"content-type">>  => <<"text/event-stream">>,
          <<"cache-control">> => <<"no-cache">>}, Req),
    %% An immediate snapshot so the client can draw before the next tick.
    send_board(Req2, snake_game:board()),
    {cowboy_loop, Req2, State#{player_id => PlayerId}}.

info({concrete_event, Board}, Req, State) ->
    send_board(Req, Board),
    {ok, Req, State};
info(_Msg, Req, State) ->
    {ok, Req, State}.

send_board(Req, Board) ->
    Data = thoas:encode(concrete_serializer:encode(Board)),
    cowboy_req:stream_body(["data: ", Data, "\n\n"], nofin, Req).
