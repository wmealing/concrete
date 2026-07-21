# 09 — Testing your code

```
rebar3 ct                              # everything
rebar3 ct --suite js_exec_SUITE        # one suite
rebar3 ct --retry                      # only what failed last time
```

Suites run their cases in parallel (each suite declares an
`all_parallel` group — Common Test has no global switch for this).

## The suite map

| Suite | Covers |
|---|---|
| `transformer_SUITE` | Erlang AST → IR records |
| `encoder_SUITE` | IR → JS fragments (incl. deliberate-error cases) |
| `pipeline_SUITE` | source → IR → JS, string-level assertions |
| `js_exec_SUITE` | **execution**: compiled JS run in Node, output asserted |
| `client_SUITE` | **hydration + dispatch**: full click cycle in Node |
| `template_parser_SUITE` | `.slab` → DOM AST |
| `renderer_SUITE` | server-side HTML rendering |
| `plt_SUITE`, `call_graph_SUITE`, `beam_reader_SUITE` | build pipeline |
| `serializer_SUITE` | wire-format round-trips |
| `runtime_SUITE` | server-side action/command dispatch |
| `api_SUITE` | the public `concrete:compile*` API |

## The execution-test pattern

String assertions on generated JS rot; executing it doesn't. The
pattern from `js_exec_SUITE`, reusable for your own modules — compile,
concatenate with the runtime, run in Node, compare printed terms:

```erlang
verify(Src, Expected) ->
    JS = concrete:compile(Src),
    {ok, Runtime} = file:read_file(concrete:runtime_path()),
    Script = ["const window = {};\n", Runtime, JS,
              "console.log(termToString("
              "Interpreter.call(\"m\", \"main\", 0, [])));\n"],
    File = "/tmp/check.js",
    ok = file:write_file(File, unicode:characters_to_binary(Script)),
    Expected = string:trim(os:cmd("node " ++ File)).
```

```erlang
verify("-module(m). main() -> lists:sum([1, 2, 3]).", "6").
```

Two habits worth copying from the suites:

- **Assert against the BEAM, not your head.** When a `js_exec` test
  expectation was once computed by hand, it was wrong — the JS and the
  BEAM agreed with each other, not with the author. Run the same
  expression in `erl` to produce the expected value.
- **Unique filenames for parallel cases.** Cases in a parallel group
  share the machine; the suites name generated files with
  `erlang:unique_integer/1`.

That's the tour. For architecture details see `CLAUDE.md`; for the
encoder's milestone history and current limitations see
`compiler-plan.md`.
