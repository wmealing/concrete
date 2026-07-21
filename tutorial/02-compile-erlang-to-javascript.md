# 02 — Compile Erlang to JavaScript

The pipeline is:

```
Erlang source → erl_parse AST → Concrete IR → JavaScript
                (erl_scan/       (concrete_     (concrete_
                 erl_parse)       transformer)   encoder)
```

## Try it

From `rebar3 shell`, compile a source string with the public API:

```erlang
JS = concrete:compile(
    "-module(temperature).\n"
    "to_fahrenheit(C) -> C * 9 div 5 + 32.\n"
    "describe(F) when F >= 30 -> hot;\n"
    "describe(_) -> fine.\n"),
io:format("~s~n", [JS]).
```

You'll see something like:

```javascript
// Module: temperature
Interpreter.defineErlangFunction("temperature", "to_fahrenheit", 1, ((currentModule) => [
  [(args) => { const bindings = {}; bindings["C"] = args[0]; return bindings; },
   (_bindings) => true,
   (bindings) => { return Erlang["+/2"](Erlang["div/2"](Erlang["*/2"](bindings["C"], Type.integer(9)), Type.integer(5)), Type.integer(32)); }]
])("temperature"));
...
```

## How to read the output

- Every Erlang term becomes a tagged JS object: `Type.integer(9)`,
  `Type.atom("hot")`, `Type.tuple([...])`. Terms are never raw JS values.
- Each function clause becomes a `[patternFn, guardFn, bodyFn]` triple.
  The runtime tries clauses in order — exactly Erlang's dispatch.
- Operators and BIFs go through the `Erlang` table (`Erlang["+/2"]`,
  `Erlang["lists:map/2"]`), implemented in `runtime.js`.
- Module names are plain atoms (`"temperature"`) — never namespaced.

## Compiling from a BEAM file

Real builds don't compile source strings — they read the abstract code
out of compiled `.beam` files (which is why modules need `debug_info`,
the default in this project):

```erlang
JS = concrete:compile_module(scoreboard_page).
```

This is the same path the bundle generator uses (chapter 06).

Next: [03 — Use the JavaScript in your own page](03-use-the-javascript-in-your-own-page.md)
