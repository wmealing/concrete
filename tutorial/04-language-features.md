# 04 — Language features

Everything below compiles to JavaScript today and is verified by
execution tests (`test/js_exec_SUITE.erl` — each feature runs in Node
and the output is compared against what the BEAM produces).

## Pattern matching

Full destructuring, everywhere patterns appear (function heads, `case`,
`=`, comprehension generators):

```erlang
area({rect, W, H}) -> W * H;
area({circle, R})  -> 3.14 * R * R.

f({point, {X, Y}}) -> X + Y.            %% nested
sum([H | T], Acc)  -> sum(T, Acc + H);  %% cons
sum([], Acc)       -> Acc.
get_a(#{a := A})   -> A.                %% map patterns (literal keys)
same(X, X)         -> true.             %% repeated variables
tag({_, B} = T)    -> {B, T}.           %% alias patterns
```

## Guards, comparisons, `if`

```erlang
f(N) when is_integer(N), N > 0 -> pos;
f(_) -> other.

g(N) ->
    if N > 3 -> big;
       true  -> small
    end.
```

Comparisons are expressions returning `true`/`false` atoms, exactly like
Erlang. `andalso`/`orelse` are lazy. Guard BIFs available: `is_atom`,
`is_integer`, `is_float`, `is_number`, `is_boolean`, `is_list`,
`is_tuple`, `is_map`, `is_binary`, `is_function`, `length`,
`tuple_size`, `map_size`, `byte_size`, `hd`, `tl`, `element`, `abs`.

## Anonymous functions

Closures, multi-clause funs, and fun references — including passing them
to the JS-implemented stdlib:

```erlang
Y = 10,
F = fun(X) -> X + Y end,          %% closure over Y
G = fun(0) -> zero; (_) -> other end,
H = fun double/1,                 %% local fun ref
lists:map(fun(X) -> X * X end, lists:seq(1, 4)).   %% => [1,4,9,16]
```

## Maps

```erlang
M  = #{a => 1},
M2 = M#{a := 2, b => 3},          %% update syntax
maps:fold(fun(_K, V, Acc) -> Acc + V end, 0, M2).
```

Stdlib available: `maps:get/2,3`, `put`, `remove`, `keys`, `values`,
`merge`, `is_key`, `size`, `fold`, `to_list`, `from_list`;
`lists:map`, `filter`, `foldl`, `foreach`, `seq`, `member`, `sum`,
`nth`, `sort`, `reverse`.

## Comprehensions, exceptions

```erlang
[X * 2 || X <- [1, 2, 3], X > 1].               %% filters
[V || {ok, V} <- Results].                      %% non-matches skipped
[{X, Y} || X <- [1, 2], Y <- [3, 4]].           %% multiple generators

try throw(ball)
catch throw:ball -> caught
end.

try f() of
    {ok, V} -> V
catch
    error:{badmatch, _} -> bad
after
    cleanup()
end.
```

## Bitstrings (byte-aligned)

```erlang
<<A:8, B:8>> = <<1, 2>>,                %% integer segments: 8/16/32 bits
<<N:16/little>> = <<1, 0>>,             %% endianness
<<H:8, Rest/binary>> = <<"abc">>,       %% rest patterns
<<"ab:", Tail/binary>> = Packet,        %% literal prefixes
<<F:64/float>> = <<2.5:64/float>>,      %% floats (32/64)
Combined = <<Prefix/binary, "suffix">>. %% construction
```

## Not supported (deliberate, with clear compile-time errors)

| Construct | Why | Error |
|---|---|---|
| `receive` | No processes in the browser; use server-side `command/3` | `receive_not_supported_in_client_code` |
| Binary comprehensions | Deferred until the bit-level runtime lands | `binary_comprehensions_not_supported` |
| Dynamic segment sizes (`<<D:Len/binary>>`) | Byte-aligned static subset for now | `bitstring_dynamic_size_not_supported` |
| Non-byte-aligned / >32-bit integer segments | Same | `bit_level_segments_not_supported` |
| Records | Use maps (project convention) | untransformed AST error |

See `compiler-plan.md` for the full milestone history and limitations.

Next: [05 — Talking to the DOM](05-talking-to-the-dom.md)
