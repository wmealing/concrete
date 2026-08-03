%% cowboy WebSocket handler for bidirectional events.
-module(concrete_ws_handler).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

init(Req, State) ->
    {cowboy_websocket, Req, State}.

websocket_init(State) ->
    {[], State}.

websocket_handle({text, Msg}, State) ->
    case thoas:decode(Msg) of
        {ok, #{<<"type">> := <<"action">>} = Payload} ->
            handle_action(Payload, State);
        {ok, #{<<"type">> := <<"command">>} = Payload} ->
            handle_command(Payload, State);
        _ ->
            {[], State}
    end;
websocket_handle(_Frame, State) ->
    {[], State}.

websocket_info({concrete_event, Event}, State) ->
    Data = thoas:encode(concrete_serializer:encode(Event)),
    {[{text, Data}], State};
websocket_info(_Info, State) ->
    {[], State}.

handle_action(_Payload, State) ->
    %% TODO: dispatch action, return updated state diff
    {[], State}.

handle_command(_Payload, State) ->
    %% TODO: dispatch command, return response
    {[], State}.
