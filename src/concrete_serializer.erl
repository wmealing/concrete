%% Encodes Erlang terms to the type-tagged JSON wire format.
-module(concrete_serializer).

-export([encode/1, encode_command_response/1]).

-spec encode(term()) -> map().
encode(Atom) when is_atom(Atom) ->
    #{type => atom, value => atom_to_binary(Atom)};
encode(Int) when is_integer(Int) ->
    #{type => integer, value => Int};
encode(Float) when is_float(Float) ->
    #{type => float, value => Float};
encode(Bin) when is_binary(Bin) ->
    #{type => bitstring, value => base64:encode(Bin)};
encode(Tuple) when is_tuple(Tuple) ->
    #{type => tuple, data => [encode(E) || E <- tuple_to_list(Tuple)]};
encode([]) ->
    #{type => list, data => [], tail => null};
encode(List) when is_list(List) ->
    case is_proper_list(List) of
        true ->
            #{type => list, data => [encode(E) || E <- List], tail => null};
        false ->
            {Proper, Tail} = split_improper(List),
            #{type => list, data => [encode(E) || E <- Proper], tail => encode(Tail)}
    end;
encode(Map) when is_map(Map) ->
    Pairs = [[encode(K), encode(V)] || {K, V} <- maps:to_list(Map)],
    #{type => map, data => Pairs};
encode(Pid) when is_pid(Pid) ->
    #{type => pid, value => list_to_binary(pid_to_list(Pid))}.

-spec encode_command_response(map()) -> map().
encode_command_response(Server) ->
    #{state => encode(Server)}.

is_proper_list([]) -> true;
is_proper_list([_ | T]) -> is_proper_list(T);
is_proper_list(_) -> false.

split_improper(List) ->
    split_improper(List, []).

split_improper([], Acc) ->
    {lists:reverse(Acc), []};
split_improper([H | T], Acc) when is_list(T) ->
    split_improper(T, [H | Acc]);
split_improper([H | T], Acc) ->
    {lists:reverse([H | Acc]), T}.
