%% cowboy WebSocket handler for bidirectional events.
-module(concrete_ws_handler).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).
-export([handle_action/2, handle_command/2]).

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

%% Mirrors concrete_command_handler's wire format: the client sends the
%% target module/action name, params, and its current component map
%% (type-tagged JSON); the reply carries the new component map back the
%% same way. Both directions share one socket, so the reply also
%% carries "type" -- the HTTP command endpoint doesn't need to, since
%% its request/response are already paired by the HTTP exchange itself.
handle_action(#{<<"module">> := ModuleBin, <<"action">> := ActionBin,
                <<"params">> := Params, <<"state">> := ClientState}, State) ->
    Module     = binary_to_existing_atom(ModuleBin),
    ActionName = binary_to_existing_atom(ActionBin),
    Component  = concrete_deserializer:decode(ClientState),
    NewComponent = concrete_runtime:dispatch_action(Module, ActionName, Params, Component),
    Response = #{type => action, state => concrete_serializer:encode(NewComponent)},
    {[{text, thoas:encode(Response)}], State}.

handle_command(#{<<"module">> := ModuleBin, <<"command">> := CommandBin,
                 <<"params">> := Params, <<"state">> := ClientState}, State) ->
    Module    = binary_to_existing_atom(ModuleBin),
    Command   = binary_to_existing_atom(CommandBin),
    Server    = concrete_deserializer:decode(ClientState),
    NewServer = concrete_runtime:dispatch_command(Module, Command, Params, Server),
    Response  = (concrete_serializer:encode_command_response(NewServer))#{type => command},
    {[{text, thoas:encode(Response)}], State}.
