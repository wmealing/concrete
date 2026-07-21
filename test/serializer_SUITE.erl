%% Phase 4: Serializer and Deserializer wire format tests.
%% Verifies that every Erlang term type round-trips correctly through
%% encode → JSON → decode.
-module(serializer_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    atom_encode/1,
    integer_encode/1,
    float_encode/1,
    binary_encode/1,
    tuple_encode/1,
    empty_list_encode/1,
    list_encode/1,
    nested_list/1,
    map_encode/1,
    atom_roundtrip/1,
    integer_roundtrip/1,
    binary_roundtrip/1,
    tuple_roundtrip/1,
    list_roundtrip/1,
    map_roundtrip/1,
    nested_map_roundtrip/1,
    decode_unknown_type/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [
        atom_encode, integer_encode, float_encode, binary_encode,
        tuple_encode, empty_list_encode, list_encode, nested_list, map_encode,
        atom_roundtrip, integer_roundtrip, binary_roundtrip,
        tuple_roundtrip, list_roundtrip, map_roundtrip, nested_map_roundtrip,
        decode_unknown_type
    ]}].
%% --- Encode shape tests ---

atom_encode(_Config) ->
    #{type := atom, value := <<"ok">>} = concrete_serializer:encode(ok).

integer_encode(_Config) ->
    #{type := integer, value := 42} = concrete_serializer:encode(42).

float_encode(_Config) ->
    #{type := float, value := 1.5} = concrete_serializer:encode(1.5).

binary_encode(_Config) ->
    Enc = concrete_serializer:encode(<<"hello">>),
    #{type := bitstring, value := B64} = Enc,
    <<"hello">> = base64:decode(B64).

tuple_encode(_Config) ->
    #{type := tuple, data := [#{type := atom}, #{type := integer}]} =
        concrete_serializer:encode({ok, 1}).

empty_list_encode(_Config) ->
    #{type := list, data := [], tail := null} = concrete_serializer:encode([]).

list_encode(_Config) ->
    #{type := list, data := [_, _], tail := null} =
        concrete_serializer:encode([1, 2]).

nested_list(_Config) ->
    Inner = [a, b],
    Outer = [Inner, c],
    #{type := list, data := [InnerEnc, _]} = concrete_serializer:encode(Outer),
    #{type := list} = InnerEnc.

map_encode(_Config) ->
    M = #{key => 1},
    #{type := map, data := [[_, _]]} = concrete_serializer:encode(M).

%% --- Round-trip tests (encode → JSON text → decode) ---

roundtrip(Term) ->
    Encoded  = concrete_serializer:encode(Term),
    JSON     = thoas:encode(Encoded),
    {ok, Decoded} = thoas:decode(JSON),
    concrete_deserializer:decode(Decoded).

atom_roundtrip(_Config) ->
    ok = roundtrip(ok).

integer_roundtrip(_Config) ->
    99 = roundtrip(99).

binary_roundtrip(_Config) ->
    <<"world">> = roundtrip(<<"world">>).

tuple_roundtrip(_Config) ->
    {ok, 1} = roundtrip({ok, 1}).

list_roundtrip(_Config) ->
    [1, 2, 3] = roundtrip([1, 2, 3]).

map_roundtrip(_Config) ->
    #{a := 1} = roundtrip(#{a => 1}).

nested_map_roundtrip(_Config) ->
    Input = #{state => #{count => 0}},
    Input = roundtrip(Input).

%% --- Decode error case ---

decode_unknown_type(_Config) ->
    try
        concrete_deserializer:decode(#{<<"type">> => <<"bogus">>}),
        ct:fail(expected_error)
    catch
        error:{unknown_wire_type, _} -> ok
    end.
