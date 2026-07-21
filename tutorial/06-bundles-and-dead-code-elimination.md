# 06 — Bundles and dead-code elimination

Shipping a whole module per page wastes bytes. The build pipeline reads
compiled BEAM files, builds a call graph from a page's entry points, and
emits JavaScript for **reachable functions only**.

```
.beam (debug_info) → concrete_beam_reader → IR per function
                                              │
                     concrete_plt (ETS cache, keyed by {M,F,A})
                                              │
                     concrete_call_graph — walk from entry points
                     {Page, init, 2} and {Page, template, 0}
                                              │
                     concrete_encoder:encode_bundle/2 → minimal JS
```

## See it run

```
rebar3 shell
```
```erlang
concrete_demo:bundle().
```

The demo compiles this module in memory:

```erlang
-module(shapes).
-export([init/2, template/0, perimeter/2]).
init(_Params, Server) ->
    {#{state => #{area => area(3, 4)}}, Server}.
template() ->
    banner().
banner() -> <<"** shapes **">>.
area(W, H) -> W * H.
perimeter(W, H) -> double(W + H).   %% exported — but never called
double(X) -> X * 2.                 %% only perimeter calls it
```

and prints:

```
=== REACHABLE FROM init/2 + template/0 ===
[{shapes,area,2},{shapes,banner,0},{shapes,init,2},{shapes,template,0}]

=== ELIMINATED (dead code) ===
[{shapes,double,1},{shapes,perimeter,2}]
```

`perimeter/2` is *exported* but unreachable from the page entry points,
so it — and transitively its private helper `double/1` — never reach the
bundle.

## The pieces individually

```erlang
{ok, IR} = concrete_beam_reader:extract_ir(my_module),  %% BEAM → IR
PLT = concrete_plt:new(),                               %% per-MFA cache
concrete_plt:put(PLT, {my_module, f, 1}, FunDef),
Graph = concrete_call_graph:build(my_module, PLT),      %% rooted walk
JS = concrete_encoder:encode_bundle(Graph, PLT).        %% reachable only
```

The PLT persists (`concrete_plt:save/2`, `load/1`) so incremental builds
don't re-derive IR for unchanged modules.

Next: [07 — Templates](07-templates.md)
