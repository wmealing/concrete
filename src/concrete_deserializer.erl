%% Decodes the type-tagged JSON wire format back to Erlang terms.
-module(concrete_deserializer).

-export([decode/1]).

-spec decode(map()) -> term().
decode(#{<<"type">> := <<"atom">>, <<"value">> := V}) ->
    binary_to_existing_atom(V);
decode(#{<<"type">> := <<"integer">>, <<"value">> := V}) when is_integer(V) ->
    V;
decode(#{<<"type">> := <<"float">>, <<"value">> := V}) when is_float(V) ->
    V;
decode(#{<<"type">> := <<"bitstring">>, <<"value">> := V}) ->
    base64:decode(V);
decode(#{<<"type">> := <<"tuple">>, <<"data">> := Elems}) ->
    list_to_tuple([decode(E) || E <- Elems]);
decode(#{<<"type">> := <<"list">>, <<"data">> := Elems, <<"tail">> := null}) ->
    [decode(E) || E <- Elems];
decode(#{<<"type">> := <<"list">>, <<"data">> := Elems, <<"tail">> := Tail}) ->
    lists:foldr(fun(E, Acc) -> [decode(E) | Acc] end, decode(Tail), Elems);
decode(#{<<"type">> := <<"map">>, <<"data">> := Pairs}) ->
    maps:from_list([{decode(K), decode(V)} || [K, V] <- Pairs]);
decode(#{<<"type">> := <<"pid">>, <<"value">> := V}) ->
    list_to_pid(binary_to_list(V));
decode(Other) ->
    error({unknown_wire_type, Other}).
