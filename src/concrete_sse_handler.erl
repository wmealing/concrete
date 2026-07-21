%% cowboy loop handler for SSE (Server-Sent Events) streams.
-module(concrete_sse_handler).
-behaviour(cowboy_loop).

-export([init/2, info/3]).

init(Req, State) ->
    ComponentId = cowboy_req:binding(id, Req),
    concrete_pubsub:subscribe(ComponentId, self()),
    Req2 = cowboy_req:stream_reply(200,
        #{<<"content-type">>  => <<"text/event-stream">>,
          <<"cache-control">> => <<"no-cache">>}, Req),
    {cowboy_loop, Req2, State#{component_id => ComponentId}}.

info({concrete_event, Event}, Req, State) ->
    Data = thoas:encode(concrete_serializer:encode(Event)),
    cowboy_req:stream_body(["data: ", Data, "\n\n"], nofin, Req),
    {ok, Req, State};
info(_Msg, Req, State) ->
    {ok, Req, State}.
