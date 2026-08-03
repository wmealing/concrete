# Concrete

A pure-Erlang port of [Hologram](https://github.com/bartblast/hologram) — a full-stack isomorphic web framework. Write browser UI components entirely in Erlang; Concrete compiles them to JavaScript bundles at build time and serves them via cowboy.

**New here? Start with the [tutorial](tutorial/README.md)** — nine short
chapters from first compile to a hydrated page with working buttons,
including how to use the generated JavaScript in your own pages.

## Requirements

- Erlang/OTP 25 or later
- rebar3 3.14 or later

## Building

```
rebar3 compile
```

## Try the demos

The fastest way to see Concrete running is the parent demo index: it builds
and starts every example below on its own port, then serves a page linking
to all of them.

```
rebar3 as example shell
```
```erlang
demo_parent:serve().
```

Then open **http://localhost:8760**.

| Demo | Port | What it shows |
|---|---|---|
| Counter | 8765 | The smallest possible demo: a self-rescheduling counter loop, pure Erlang compiled straight to JavaScript. |
| Template / Scoreboard | 8766 | A `.slab` template rendered server-side on first load, then hydrated — button clicks dispatch to a compiled `action/3` running in the browser. |
| Todo List | 8767 | A small stateful app (add/complete/clear) persisted to `localStorage`, entirely compiled Erlang — no server round trips. |
| Canvas Animation | 8768 | A self-scheduling animation loop drawing a rotating flower on `<canvas>` via the `canvas:*` BIFs. |
| gen_server-style Process | 8769 | A real `spawn`/`self`/`!`/`receive` generic-server loop (`concrete_gen_server.erl`) dispatching into a callback module, running in the browser. |
| Process Ring (spawn/self/send/receive) | 8770 | Six spawned worker processes passing a token around a ring, with a live canvas visualization of every send/receive hop. |

Each demo also has its own runner module (`concrete_demo`, `template_demo`,
`todo_demo`, `canvas_demo`, `gen_server_demo`, `process_viz_demo`) if you'd
rather build and serve just one — see the walkthroughs below, starting with
the counter demo.

## Creating a new Concrete app

Concrete ships a `rebar3 new` template that scaffolds a minimal app: a
supervised OTP application with one routed page module, a `.slab`
template, and `rebar.config` already wired to Concrete's compiler
plugin.

Add Concrete as a plugin so `rebar3 new` can find the template — either
globally in `~/.config/rebar3/rebar.config`:

```erlang
{plugins, [
    {concrete, {git, "https://github.com/wmealing/concrete.git", {branch, "main"}}}
]}.
```

or per-project, in an existing project's `rebar.config`. Then generate
the new app:

```
rebar3 new concrete_app name=my_app port=4001
```

This creates `my_app/` with:

```
my_app/
├── src/
│   ├── my_app_app.erl     -- application callback, starts my_app_sup
│   ├── my_app_sup.erl     -- top-level supervisor
│   ├── my_app_page.erl    -- page module routed at "/", with a counter action/3
│   └── my_app.app.src
├── priv/templates/
│   └── page.slab          -- the counter's template
├── config/
│   └── sys.config         -- sets the concrete app's listen port
├── rebar.config           -- depends on concrete, registers its compiler plugin,
│                              loads config/sys.config into the shell
└── README.md
```

`port` defaults to `4000` if omitted. Build and run it:

```
cd my_app
rebar3 shell
```

Then visit `http://localhost:4001/` — the +/− buttons dispatch
`my_app_page:action/3`, compiled to JavaScript at build time by
`rebar_compiler_concrete` and executed in the browser.

## Running the tests

### All suites

```
rebar3 ct
```

### A single suite

```
rebar3 ct --suite transformer_SUITE
rebar3 ct --suite encoder_SUITE
rebar3 ct --suite pipeline_SUITE
rebar3 ct --suite plt_SUITE
rebar3 ct --suite call_graph_SUITE
rebar3 ct --suite beam_reader_SUITE
rebar3 ct --suite serializer_SUITE
rebar3 ct --suite runtime_SUITE
rebar3 ct --suite template_parser_SUITE
rebar3 ct --suite renderer_SUITE
```

### A single test case

```
rebar3 ct --suite transformer_SUITE --case atom
rebar3 ct --suite pipeline_SUITE --case arithmetic
rebar3 ct --suite serializer_SUITE --case nested_map_roundtrip
```

### Re-run only failing tests

```
rebar3 ct --retry
```

### View the HTML report

```
open _build/test/logs/index.html
```

## Test suite reference

| Suite | Phase | What it covers |
|---|---|---|
| `transformer_SUITE` | 1 | Every `erl_parse` AST node type → correct IR record |
| `encoder_SUITE` | 1 | Every IR node type → expected JavaScript fragment |
| `pipeline_SUITE` | 1 | Full source string → transform → encode → JS assertions |
| `plt_SUITE` | 2 | PLT put/get, overwrite, persist to disk and reload |
| `call_graph_SUITE` | 2 | Reachable MFAs, transitive calls, dead-code exclusion |
| `beam_reader_SUITE` | 2 | IR extraction from compiled OTP BEAM files |
| `serializer_SUITE` | 4 | Wire format encode/decode round-trips for all term types |
| `runtime_SUITE` | 4 | Action and command dispatch to component callbacks |
| `template_parser_SUITE` | 3 | `.slab` syntax → DOM AST: elements, attrs, `{@state}` exprs, components; client render-fn compilation |
| `renderer_SUITE` | 3 | Server-side HTML rendering: expr evaluation, escaping, void elements, component embedding, `render_page/2` |
| `js_exec_SUITE` | 1 | Execution round-trips: Erlang source → compiled JS → run in Node.js against the runtime, output asserted (see `compiler-plan.md`) |
| `client_SUITE` | 4/5 | Hydration + action dispatch: bundle from BEAM, hydrate serializer JSON, click → compiled `action/3` → re-render, run in Node.js |

## Generating JavaScript from Erlang source

The compiler pipeline can be driven interactively from the Erlang shell.

### Start the shell

```
rebar3 as example shell
```

### Compile any Erlang source string to JavaScript

```erlang
concrete_demo:run("-module(mymod). double(N) -> N * 2.").
```

This prints the source and the generated JavaScript to stdout.

### Run the built-in hello world example

```erlang
concrete_demo:hello_world().
```

Output:

```
=== SOURCE ===
-module(hello).
greet(Name) -> {ok, Name}.
add(A, B) -> A + B.
label(ok) -> done;
label(error) -> failed.

=== GENERATED JAVASCRIPT ===
// Module: hello
Interpreter.defineErlangFunction("hello", "greet", 1, [...]);
Interpreter.defineErlangFunction("hello", "add",   2, [...]);
Interpreter.defineErlangFunction("hello", "label", 1, [...]);
```

Each Erlang function becomes a `defineErlangFunction` call. Each clause is a
`[patternFn, guardFn, bodyFn]` triple — the runtime tries them in order until
one matches.

## Browser demo: a live counter written in Erlang

A self-contained browser demo is included in `priv/js/demo/`. It requires no
npm or bundler. A counter module written in Erlang is compiled to JavaScript
and runs in the browser forever — it appends an incrementing number and a
`<br>` to the page four times a second. All of the logic lives in Erlang:

```erlang
-module(counter).
-export([start/0, tick/1]).
start() ->
    tick(0).
tick(N) ->
    dom:append_html(<<"output">>, integer_to_binary(N)),
    dom:append_html(<<"output">>, <<"<br>">>),
    dom:set_timeout(250, counter, tick, [N + 1]).
```

Start the shell, regenerate the compiled JS, and serve it:

```
rebar3 as example shell
```
```erlang
concrete_demo:build().    % compiles the counter source to priv/js/demo/counter/counter.js
concrete_demo:serve().    % static file server on http://localhost:8765
```

Then open http://localhost:8765 in your browser. To use a different port:

```erlang
concrete_demo:serve(9000).
```

See [Try the demos](#try-the-demos) above for the other example apps.

The page loads:

- **`runtime.js`** — minimal stub implementing `Type`, `Interpreter`, and the `Erlang` BIF table
- **`counter.js`** — the compiled counter module, generated by `concrete_demo:build()`
- **`app.js`** — one line: `Interpreter.callTopLevel("counter", "start", 0, [])`, the JS equivalent of `erl -s counter start`

### How Erlang talks to the DOM

The DOM is exposed to compiled Erlang code as a BIF module implemented in
`runtime.js` — the same mechanism `lists:reverse/1` uses:

| Erlang call | Effect |
|---|---|
| `dom:append_html(Id, Html)` | `insertAdjacentHTML("beforeend", ...)` on the element |
| `dom:set_text(Id, Text)` | replace the element's `textContent` |
| `dom:set_timeout(Ms, M, F, Args)` | schedule an Erlang MFA call — the browser analogue of `erlang:send_after/3` |

The loop sustains itself from Erlang: each `tick/1` writes to the DOM and
schedules the next tick. A literal tail-recursive loop would block the
browser's single thread, so rescheduling through `dom:set_timeout/4` is the
idiomatic pattern (the same event-loop shape upstream Hologram uses).

The counter source lives in `concrete_demo:counter_src/0`. Edit it and rerun
`concrete_demo:build().` — the running file server picks up the new bundle on
the next page reload.

## Dead-code elimination and bundling

`concrete_demo:bundle().` demonstrates the full build pipeline:
`compile:forms` with `debug_info` → `concrete_beam_reader` extracts IR from
the BEAM → `concrete_plt` caches IR per MFA → `concrete_call_graph` walks the
graph from the page entry points (`init/2`, `template/0`) →
`concrete_encoder:encode_bundle/2` emits JS for reachable functions only.

```erlang
concrete_demo:bundle().
```

The demo module exports `perimeter/2`, which is never called from an entry
point — it and its private helper `double/1` are excluded from the bundle:

```
=== REACHABLE FROM init/2 + template/0 ===
[{shapes,area,2},{shapes,banner,0},{shapes,init,2},{shapes,template,0}]

=== ELIMINATED (dead code) ===
[{shapes,double,1},{shapes,perimeter,2}]
```

## Template system 

`concrete_demo:render().` walks a `.slab` template through the whole
pipeline:

```erlang
concrete_demo:render().
```

1. **Parse** — `concrete_template_parser:parse_string/1` turns the template
   into a DOM AST. `{@name}` interpolations are rewritten to
   `maps:get(name, CONCRETE_STATE)` and parsed as real Erlang expressions,
   so `{@score + 1}` works too.
2. **Server render** — `concrete_renderer:render_nodes/2` walks the AST and
   evaluates expressions against component state with `erl_eval`. Evaluated
   values are HTML-escaped; void elements (`<br>`, `<img>`, ...) render
   without closing tags.
3. **Client compile** — `concrete_template_parser:compile_render_fun/1`
   compiles the same AST into an IR `render/1` function, which the encoder
   emits as JavaScript. In the browser it rebuilds the DOM AST with all
   expressions evaluated — the same template renders identically on both
   sides.

```
<div class="scoreboard">          <div class="scoreboard">
  <h1>{@title}</h1>          →      <h1>Scores</h1>
  <p>Next score: {@score + 1}</p>    <p>Next score: 42</p>
  ...                                ...
```

Templates come from `.slab` files (resolved against the `templates_dir` app
env, default `priv/templates`) or inline from
`template() -> {inline, DOM}`. Child components embed with
`<:component module={mod} prop={@value} />` — props are evaluated against
the parent's state, then passed to the child's `init/2`.
`concrete_renderer:render_page/2` renders a full page module and returns
the HTML plus the type-tagged state JSON used for client hydration.

### The full loop in the browser: server render + hydration + actions

`template_demo` serves a real page module over HTTP with working buttons:

```
rebar3 as example shell
```
```erlang
template_demo:serve().    % http://localhost:8766
```

**Server side** — each request calls
`concrete_renderer:render_page(scoreboard_page, Params)`:
`scoreboard_page:init/2` builds state from the query params,
`priv/templates/scoreboard.slab` is parsed, and the `{@...}` expressions are
evaluated with `erl_eval`. Open http://localhost:8766/?player=sam&score=100
and the server re-renders with the new state. Rendered values are
HTML-escaped.

**Client side** — the page then hydrates and comes alive:

- `/bundle.js` is generated on request from `scoreboard_page`'s BEAM
  (`concrete_beam_reader` → IR → `concrete_encoder`) plus the template
  compiled to a `render/1` function.
- `client.js` deserializes the type-tagged hydration JSON back into terms,
  installs one delegated click listener, and re-renders.
- Clicking **+** / **−** dispatches `increment`/`decrement` to the compiled
  `scoreboard_page:action/3` — the same Erlang clauses in the module —
  running in the browser, then re-renders the template client-side.
  `Score:` and the derived `Next score: {@score + 1}` both update with no
  server round-trip.

The dispatch cycle is `concrete-click` attribute → `Client.dispatch` →
compiled `action/3` → new component map → compiled `render/1` →
`innerHTML`. Full re-render for now; vdom diffing arrives with the
runtime. `client_SUITE` covers the cycle headlessly: it builds the bundle,
hydrates from real serializer output, fires the click listener, and asserts
the updated DOM — in Node.js, standing in for the browser.

## Wire format round-trip 

`concrete_demo:wire().` round-trips a nested Erlang term through the
type-tagged JSON wire format used between server and browser
(`concrete_serializer` → JSON text via `thoas` → `concrete_deserializer`):

```
=== TERM ===
#{count => 42,label => <<"clicks">>,status => {ok,ready},history => [1,2,3]}

=== WIRE JSON ===
{"data":[[{"type":"atom","value":"count"},{"type":"integer","value":42}], ...

Round-trip equal: true
```

## rebar3 compiler plugin

`src/rebar_compiler_concrete.erl` is a `rebar_compiler` behaviour
implementation that lets `rebar3 compile` produce page bundles directly,
instead of driving the pipeline by hand from the shell
(`concrete_demo:bundle()` etc., as shown above). It's registered as an
active compiler via `concrete:init/1`, which rebar3 calls automatically
for any project that lists `concrete` under `{plugins, ...}` or
`{project_plugins, ...}` — this is exactly what `rebar3 new concrete_app`
scaffolds, see [Creating a new Concrete app](#creating-a-new-concrete-app)
above.

What it does:

1. **`context/1`** tells rebar3 where to look — Erlang source in `src/`,
   compiling to `.mjs` under `priv/js/bundles`. This is how it plugs into
   rebar3's normal build-graph/dependency tracking alongside the standard
   `.erl → .beam` compiler pass.
2. **`needed_files/4`** scans compiled `.beam` files in `ebin/` for
   modules implementing `-behaviour(concrete_page)`, using
   `module_info(attributes)`, and returns those whose BEAM digest has
   changed since the last build (checked against the digest recorded in
   the PLT) as the set to (re)bundle.
3. **`compile/4`** does the real work per page module: loads the PLT
   (`concrete_plt`), walks the module's call graph
   (`concrete_call_graph:build/2`) pulling IR for any newly-reachable
   `{M,F,A}` out of BEAM abstract code (`concrete_beam_reader`), encodes
   the reachable graph to JS (`concrete_encoder:encode_bundle/2`), parses
   the page's `.slab` template into a client-side `render/1` function and
   appends it to the same bundle, and writes the result as a
   content-addressed file — `<page_module>_<sha256>.mjs` — under
   `priv/js/bundles/`. It also updates `concrete_manifest.json` (page
   module → bundle filename) so the server handlers know which bundle to
   serve for a given page, and persists the updated PLT (including the
   new digest) back to disk.
4. **`dependencies/3`** and **`clean/2`** are no-ops for now — incremental
   dependency wiring and cleanup of generated bundles aren't implemented.

In short, this is the same pipeline the shell demos exercise manually
(`concrete_beam_reader` → `concrete_plt` → `concrete_call_graph` →
`concrete_encoder`), packaged as a first-class compile step that runs for
every `concrete_page` module in the project on `rebar3 compile`.

## Project structure

```
concrete/
├── src/               Erlang source modules, incl. rebar_compiler_concrete
├── include/           concrete_ir.hrl — IR record definitions
├── test/              Common Test suites
├── priv/js/demo/      Concrete JS runtime (runtime.js, client.js) + demos
├── priv/js/upstream/  Unadapted upstream Hologram JS (reference/parts bin)
├── priv/templates/    .slab templates + rebar3 new project generator
└── rebar.config
```

Concrete's runtime is its own implementation —

`runtime.js` (terms, interpreter, BIF table incl. `lists:*`/`maps:*` stdlib
and the `dom` module) plus `client.js` (hydration + action dispatch). The
upstream Hologram JS tree is hosted in `priv/js/upstream/` as a
parts bin; its `bitstring.mjs` and `vdom.mjs` are candidates for later
integration, but its interpreter contract is Elixir-specific and is not
what the Concrete encoder targets. Compatibility ground truth:
`js_exec_SUITE` and `client_SUITE` execute compiled bundles in Node.js.

## Architecture overview

See `CLAUDE.md` for the full architecture, component model, IR system, wire format, and porting notes from Hologram.
