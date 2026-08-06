%% Phase 4: WebSocket action/command dispatch tests.
%%
%% Exercises concrete_ws_handler:handle_action/2 and handle_command/2
%% directly with realistic wire payloads (built the same way a real
%% client would: encode a component/server map, round-trip it through
%% JSON so the handler sees plain binary-keyed maps, same as
%% thoas:decode/1 would hand it).
-module(ws_handler_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    dispatch_action_over_ws/1,
    dispatch_command_over_ws/1
]).

all() ->
    [{group, all_parallel}].

groups() ->
    [{all_parallel, [parallel], [
        dispatch_action_over_ws,
        dispatch_command_over_ws
    ]}].

dispatch_action_over_ws(_Config) ->
    {Component, _Server} = fixture_counter:init(#{}, #{}),
    Payload = #{
        <<"type">>   => <<"action">>,
        <<"module">> => <<"fixture_counter">>,
        <<"action">> => <<"increment">>,
        <<"params">> => #{},
        <<"state">>  => wire_roundtrip(Component)
    },
    {[{text, RespJSON}], state} = concrete_ws_handler:handle_action(Payload, state),
    {ok, Resp} = thoas:decode(RespJSON),
    #{<<"type">> := <<"action">>, <<"state">> := WireState} = Resp,
    NewComponent = concrete_deserializer:decode(WireState),
    #{state := #{count := 1}} = NewComponent.

dispatch_command_over_ws(_Config) ->
    Payload = #{
        <<"type">>    => <<"command">>,
        <<"module">>  => <<"fixture_command">>,
        <<"command">> => <<"save">>,
        <<"params">>  => #{<<"value">> => <<"hello">>},
        <<"state">>   => wire_roundtrip(#{})
    },
    {[{text, RespJSON}], state} = concrete_ws_handler:handle_command(Payload, state),
    {ok, Resp} = thoas:decode(RespJSON),
    #{<<"type">> := <<"command">>, <<"state">> := WireState} = Resp,
    NewServer = concrete_deserializer:decode(WireState),
    #{saved := <<"hello">>} = NewServer.

%% Erlang term -> type-tagged wire map -> JSON -> back to a plain
%% binary-keyed map, the same shape thoas:decode/1 produces for a real
%% client message.
wire_roundtrip(Term) ->
    {ok, Decoded} = thoas:decode(thoas:encode(concrete_serializer:encode(Term))),
    Decoded.
