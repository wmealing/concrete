# Erlang Hologram — Implementation Plan

Build a pure-Erlang equivalent of Hologram: a framework for writing rich, interactive browser UIs entirely in Erlang, with component logic compiled to JavaScript at build time. No Elixir. No JavaScript frameworks.

Working name: **hologram_erl** (or `erlogram`).

---

## Goals

- Define UI components as plain Erlang modules implementing a behaviour
- Compile Erlang component code to JavaScript bundles at build time via a rebar3 plugin
- Deliver a JS runtime to the browser that executes the compiled code
- Synchronise server and client state over WebSocket/SSE
- Handle actions (client-only state changes) and commands (server round-trips) identically to Hologram
- Support server-side rendering of the initial page HTML
- Provide dead-code elimination so only reachable functions are bundled per page

Non-goals (for v1):
- Distribution / multi-node state sync (CRDT map)
- Hot code reloading in production
- Erlang record support in component code (use maps)

---

## Current Status

The project shipped as **Concrete** (module prefix `concrete_*`), not under either
working name above; the rest of this document is otherwise still the accurate
design record. Phases 1–4 and 6 are functionally complete, including layouts
(a plan item this document originally only sketched — see `-concrete([{route,
...}, {layout, Module}])` and the `<slot />` template tag). Phase 7 is partial.
Phase 5 (JS runtime) has a working lean implementation, but not the one
originally scoped — see below.

**Done:**
- IR, transformer, encoder, call graph, dead-code elimination, BEAM reader, PLT
- `.slab` template parser, server-side renderer, layouts with `<slot />`
- cowboy routing, page/command/SSE/WS handlers, runtime dispatch, pub/sub,
  serializer/deserializer
- WebSocket action/command dispatch (`concrete_ws_handler` -> `concrete_runtime`),
  wire-compatible with the HTTP command endpoint
- SSE streams scoped per component (`/concrete/sse/:id`)
- `rebar3 new concrete_app` project scaffolding
- Example apps: counter, template/scoreboard, todo, canvas, gen_server,
  process-ring, multiplayer snake (SSE), WebSocket actions/commands (`ws_demo`)
- Client-side `<:component>` embedding: the bundler (`rebar_compiler_concrete`)
  now walks `<:component>` references transitively (`discover_modules/2`) to
  pull every embedded module's code and its own `render/1` into the page's
  bundle, call-graph entries and bundle-staleness digests cover the whole
  set, and `client.js` actually renders the child (`init/2` then `render/1`)
  instead of throwing. Proven with a real Node execution test
  (`client_SUITE:embedded_component_renders`), not just server-side.
- Client-side layout `<slot />` rendering: `discover_modules/2` also finds a
  page's declared layout (`concrete_renderer:layout_for/1`, read from
  `-concrete([..., {layout, Mod}])` — not from the template, so it's a
  separate root, not something `component_modules/1` could ever find) and
  bundles it the same way. `client.js` gained `Client.renderWithLayout/3`,
  the client-side equivalent of `concrete_renderer:wrap_in_layout/2`: it
  renders the layout's own template with already-rendered page HTML spliced
  in at `<slot />`. `Client.init`/`dispatch` deliberately don't call it —
  the mount point (`#concrete-root`) already sits inside the
  server-rendered, static layout shell, so re-rendering only the page's own
  content into it is correct as-is; `renderWithLayout` exists as a real,
  tested capability for anything that needs the whole tree client-side.
  Proven in Node (`client_SUITE:render_with_layout_fills_slot`,
  `slot_outside_layout_throws`).

**Known gaps (not yet built):**
1. **No client-side vdom diffing.** `priv/js/demo/client.js` does a full
   `innerHTML` replace on every action instead of the diff+patch this document
   calls for (Phase 3.3). `priv/js/upstream/vdom.mjs` and `renderer.mjs` are
   kept as an unadapted reference for this. **Next up.**
2. **No declarative client-side command dispatch.** `concrete-click` gets
   automatic action dispatch; there's no equivalent for commands — a
   component has to hand-call the `http:post_json/2` BIF or open its own
   WebSocket, as `ws_demo` does.
3. **No end-to-end integration test.** Phase 7 wants Common Test against a
   real cowboy server with HTTP client assertions; coverage currently stops
   at unit/pipeline tests plus Node.js bundle execution (`js_exec_SUITE`).

**Deliberate deviations from this document (not gaps):**
- `receive` in compiled action code is supported (this document originally
  flagged it as a pitfall to warn on instead).
- No `esbuild` dependency — the encoder emits ready-to-run JS directly, so
  the external bundling step this document lists under Dependencies was
  never needed.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  BUILD TIME (rebar3 plugin)                             │
│                                                         │
│  .erl source ──► erl_parse ──► Erlang AST              │
│                                    │                    │
│                               Transformer               │
│                                    │                    │
│                               Hologram IR               │
│                                    │                    │
│                    ┌───────────────┤                    │
│                    │           Call Graph               │
│                    │               │                    │
│                  Encoder      Dead-code elim            │
│                    │               │                    │
│              page_bundle.mjs ◄─────┘                   │
└─────────────────────────────────────────────────────────┘
         │
         ▼ served as static asset
┌─────────────────────────────────────────────────────────┐
│  BROWSER (JS runtime)                                   │
│                                                         │
│  interpreter.mjs  ──  executes compiled Erlang fns      │
│  hologram.mjs     ──  component lifecycle, event loop   │
│  renderer.mjs     ──  vdom diff + DOM patching          │
│  erlang/*.mjs     ──  BIF implementations               │
└─────────────────────────────────────────────────────────┘
         │  WebSocket / SSE / HTTP
         ▼
┌─────────────────────────────────────────────────────────┐
│  SERVER (cowboy + OTP)                                  │
│                                                         │
│  hologram_router      ──  cowboy dispatch table         │
│  hologram_controller  ──  command handler, SSE, WS      │
│  hologram_renderer    ──  server-side HTML rendering     │
│  hologram_runtime     ──  action/command dispatch       │
│  hologram_pubsub      ──  pg-based channel broadcasts   │
│  hologram_registry    ──  gproc component instances     │
└─────────────────────────────────────────────────────────┘
```

---

## Component Model

Components are Erlang modules implementing `-behaviour(hologram_component)`.

```erlang
-module(counter).
-behaviour(hologram_component).
-export([init/2, action/3, template/0]).

init(Props, Server) ->
    Count = maps:get(initial_value, Props, 0),
    {#{state => #{count => Count}}, Server}.

action(increment, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count => N + 1}};
action(decrement, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count => N - 1}}.

template() -> "counter.holo".
```

Pages are modules implementing `-behaviour(hologram_page)`, with routing and layout declared via a module attribute:

```erlang
-module(dashboard_page).
-behaviour(hologram_page).
-hologram([{route, "/dashboard"}, {layout, main_layout}]).
-export([init/2, template/0]).

init(_Params, Server) ->
    {#{state => #{}}, Server}.

template() -> "dashboard.holo".
```

Template files use the same `.holo` markup as Hologram (HTML-like with `{@expr}` interpolation and `<:component module={name} />` for embedding components).

---

## Implementation Phases

### Phase 1 — Compiler Foundation

**Goal**: Take a single Erlang module and produce working JavaScript.

1. **IR definition** (`hologram_ir.hrl`)
   - Define all IR node record types (see `details.md`)
   - Port the ~35 node types from Hologram's `IR` module to Erlang records

2. **Erlang AST → IR transformer** (`hologram_transformer.erl`)
   - Walk `erl_parse` output node by node
   - Map each Erlang AST form to the corresponding IR record
   - Handle: functions, clauses, patterns, guards, case, if, try, receive, comprehensions, maps, binaries, anonymous funs, remote/local calls
   - Context tracks current module, imports, whether inside a pattern

3. **IR → JavaScript encoder** (`hologram_encoder.erl`)
   - Port Hologram's `Encoder` module logic to Erlang
   - Each IR node type → JavaScript string fragment
   - Wrap function definitions using the `defineElixirFunction()` JS runtime API
   - Emit module registration calls at the top of each bundle

4. **Smoke test**
   - Write a simple module with pattern matching and maps
   - Compile it through the pipeline
   - Load the JS in Node.js with the Hologram JS runtime and verify execution

### Phase 2 — Call Graph & Dead Code Elimination

**Goal**: Only bundle functions reachable from a given page.

1. **Call graph builder** (`hologram_call_graph.erl`)
   - Walk IR to find all `{remote_call, Module, Function, Arity}` and `{local_call, Function, Arity}` nodes
   - Build a digraph of `{Module, Function, Arity}` → `[{Module, Function, Arity}]` edges
   - Entry points are the page's `init/2` and `template/0`, plus all reachable component callbacks

2. **BEAM abstract code reader** (`hologram_beam_reader.erl`)
   - Use `beam_lib:chunks(BeamFile, [abstract_code])` to extract AST from compiled `.beam` files
   - This covers standard library modules (maps, lists, etc.) — transform their AST into IR to include reachable functions
   - Cache extracted IR in an ETS-backed PLT (Persistent Lookup Table)

3. **Bundle generator**
   - For each page, run BFS/DFS over the call graph from entry points
   - Collect all reachable IR
   - Encode to a single `page_<digest>.mjs` bundle

### Phase 3 — Template System

**Goal**: Parse `.holo` files into a DOM AST and render them server-side and client-side.

1. **Template parser** (`hologram_template_parser.erl`)
   - Port or adapt the existing `.holo` parser (it is pure parsing logic, not Elixir-specific)
   - Output: tuple-based DOM AST `{element, Tag, Attrs, Children}` / `{text, Binary}` / `{expr, Expr}` / `{component, Module, Props}`
   - `{expr, Expr}` nodes contain Erlang AST fragments parsed with `erl_scan` + `erl_parse`

2. **Server-side renderer** (`hologram_renderer.erl`)
   - Walk DOM AST, evaluate `{expr, Expr}` nodes against component state
   - Output iolist HTML for initial page delivery
   - Collect component states into a JSON map for client-side hydration

3. **Client-side renderer**
   - The existing `renderer.mjs` and `vdom.mjs` from Hologram are reusable with minor adaptation
   - Ensure DOM AST format matches what the JS renderer expects

### Phase 4 — Server Runtime

**Goal**: Serve pages, handle commands, push updates.

1. **cowboy routing** (`hologram_router.erl`)
   - Discover all `hologram_page` modules at startup (by scanning loaded modules for the attribute)
   - Build cowboy dispatch table dynamically
   - Routes: `GET /:page_route`, `POST /hologram/command`, `GET /hologram/sse`, `GET /hologram/ws`

2. **Controller handlers**
   - `hologram_page_handler` — render initial HTML, inject client state bootstrap
   - `hologram_command_handler` — decode command, call `Module:command/3`, encode response actions
   - `hologram_sse_handler` — cowboy loop handler streaming server-pushed updates
   - `hologram_ws_handler` — cowboy websocket handler for bidirectional events

3. **Runtime dispatch** (`hologram_runtime.erl`)
   - `dispatch_action(Target, ActionName, Params, ComponentState)` — call `Module:action/3`
   - `dispatch_command(Target, CommandName, Params, Server)` — call `Module:command/3`
   - Return encoded state diff or next action

4. **Pub/sub** (`hologram_pubsub.erl`)
   - Thin wrapper over OTP `pg` (available since OTP 23)
   - `subscribe(Channel, Pid)`, `broadcast(Channel, Message)`
   - Channels are atoms or `{atom, term}` tagged tuples

5. **Serializer / Deserializer**
   - `hologram_serializer.erl` — Erlang terms → JSON wire format (matching what the JS client sends)
   - `hologram_deserializer.erl` — JSON wire format → Erlang terms
   - Use `thoas` or `jason`-compatible format; keep the Hologram type-tagged JSON encoding

### Phase 5 — JS Runtime Adaptation

**Goal**: Strip Elixir-specific JS, verify the runtime works with Erlang-compiled bundles.

1. **Audit `assets/js/`**
   - Remove `elixir/` directory (not needed)
   - Remove `erlang/elixir_aliases.mjs`, `erlang/elixir_locals.mjs`, `erlang/elixir_utils.mjs`
   - Keep everything else

2. **`interpreter.mjs` adjustments**
   - Remove Elixir-specific IR node handling (module attributes, `with` expressions, `sigil_*`, `defstruct`)
   - Verify Erlang IR nodes (receive, if guards, binary comprehensions) are handled
   - Adjust how module/function names are encoded (Erlang uses atoms only, no `Elixir.` prefix)

3. **Type encoding**
   - Erlang atoms `true`/`false` are just atoms; no special boolean type needed
   - Erlang strings are charlists (list of integers); binaries are the idiomatic string type in component code — enforce this convention

4. **Bundle entry point**
   - Each page bundle exports an entry function that registers all compiled modules with `interpreter.mjs`
   - `hologram.mjs` bootstraps by calling this entry function, then initialises component tree

### Phase 6 — rebar3 Compiler Plugin

**Goal**: Make compilation automatic and incremental in a standard rebar3 project.

1. **`rebar_compiler_hologram`** (implements `rebar_compiler` behaviour)
   - `context/1` — declare source extensions (`.erl`, `.holo`) and output directories
   - `needed_files/4` — detect changed sources by comparing file digests with stored PLT
   - `compile/4` — for each changed page module, run the full pipeline and emit bundles
   - `clean/2` — remove generated bundles and PLT

2. **Module discovery**
   - At plugin startup, compile all `.erl` files normally first (rebar3 handles this)
   - Then load compiled modules and check `module_info(attributes)` for `-behaviour(hologram_page)`
   - Use those modules as entry points for per-page bundle generation

3. **Incremental compilation**
   - Store module IR and call graph edges in an ETS table persisted via `dets` (PLT)
   - On recompile, only re-transform changed modules, then re-link affected page bundles

4. **Asset manifest**
   - Emit `hologram_manifest.json` mapping page module → bundle filename (with content hash)
   - Server reads this at startup to know which bundle to serve per page

### Phase 7 — Integration & Testing

1. **Example application** — counter, todo list, form with server command, pub/sub channel
2. **Test harness** — EUnit for compiler pipeline unit tests; Common Test for integration (real cowboy server + headless browser or HTTP client)
3. **Documentation** — component authoring guide, rebar3 plugin configuration, template syntax reference

---

## Directory Structure (new project)

```
hologram_erl/
├── src/
│   ├── hologram_component.erl       # behaviour definition + default callbacks
│   ├── hologram_page.erl            # behaviour definition + default callbacks
│   ├── hologram_transformer.erl     # Erlang AST → IR
│   ├── hologram_encoder.erl         # IR → JavaScript
│   ├── hologram_call_graph.erl      # MFA dependency graph
│   ├── hologram_beam_reader.erl     # beam_lib AST extraction + IR cache
│   ├── hologram_template_parser.erl # .holo file parser
│   ├── hologram_renderer.erl        # server-side HTML rendering
│   ├── hologram_router.erl          # cowboy dispatch table builder
│   ├── hologram_page_handler.erl    # cowboy handler — initial page request
│   ├── hologram_command_handler.erl # cowboy handler — command POST
│   ├── hologram_sse_handler.erl     # cowboy loop handler — SSE stream
│   ├── hologram_ws_handler.erl      # cowboy websocket handler
│   ├── hologram_runtime.erl         # action/command dispatch
│   ├── hologram_pubsub.erl          # pg wrapper
│   ├── hologram_serializer.erl      # Erlang → JSON wire format
│   ├── hologram_deserializer.erl    # JSON wire format → Erlang
│   ├── hologram_plt.erl             # ETS+dets PLT for IR caching
│   ├── hologram_assets.erl          # asset manifest reader
│   └── hologram_app.erl             # OTP application + supervision tree
├── include/
│   └── hologram_ir.hrl              # IR record definitions
├── priv/
│   └── js/                          # JS runtime (adapted from Hologram)
│       ├── interpreter.mjs
│       ├── hologram.mjs
│       ├── renderer.mjs
│       ├── vdom.mjs
│       ├── bitstring.mjs
│       ├── type.mjs
│       ├── erlang/                  # BIF implementations
│       └── ...
├── plugin/
│   └── rebar_compiler_hologram.erl  # rebar3 compiler plugin
├── test/
│   ├── transformer_SUITE.erl
│   ├── encoder_SUITE.erl
│   ├── template_parser_SUITE.erl
│   └── integration_SUITE.erl
├── example/
│   └── counter_app/                 # minimal working example
└── rebar.config
```

---

## Dependencies

```erlang
{deps, [
    {cowboy, "2.12.0"},        % HTTP server, WebSocket, SSE (loop handler)
    {gproc, "1.0.0"},          % process registry for component instances
    {thoas, "1.0.0"},          % fast JSON encode/decode
    {esbuild, "..."}           % JS bundling (called as an external tool, not a dep)
]}.
```

OTP 25+ required for `pg` (pub/sub), `beam_lib` (AST extraction), and map pattern matching features.

---

## Key Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Erlang AST gaps (macros, parse transforms in stdlib) | Restrict component code to plain Erlang; expand records manually or disallow them in v1 |
| JS runtime divergence from Erlang semantics | Use Hologram's existing test suite for the JS runtime as a reference; write property tests |
| rebar3 plugin complexity | Build the compiler pipeline standalone first (as an escript), integrate into rebar3 in Phase 6 |
| Template expression evaluation on server | Parse `{expr, _}` fragments with `erl_parse`, eval with `erl_eval` against component state |
| Dead-code elimination misses | Fall back to bundling entire modules if call graph is incomplete; optimise later |
