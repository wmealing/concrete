# Part B — `rebar3 new concrete_app` project generator

## Context

Depends on Part A being done first: `concrete_app`/`concrete_sup` must
be a real, working "start my app" entry point before it makes sense to
scaffold new projects around it.

There is no existing rebar3 project-template scaffolding in this repo
to build on (confirmed: no `.mustache` files, no `priv/templates/*.template`,
nothing). `priv/templates/scoreboard.slab` is unrelated — it's a
`.slab` component template consumed by `concrete_renderer`/
`template_demo`, not a rebar3 project template. New files must use
distinct names and not collide with it.

How rebar3 templates actually work (researched against rebar3.org docs):

- Custom `rebar_compiler` behaviour modules are wired in via a plugin
  module matching the OTP app name, exporting `init/1`, which calls
  `rebar_state:append_compilers(State, [CompilerMod])`. `concrete.erl`
  already matches the app name — `init/1` goes there (see part-a.md).
- Templates: any app loaded as a rebar3 plugin (`plugins`/
  `project_plugins`, or globally via `~/.config/rebar3/rebar.config`)
  gets its `priv/` template files auto-discovered — no extra
  registration code needed, but the `.template` index + fragment files
  should be flat under `priv/templates/` (matching rebar3's own bundled
  template convention) with names distinct from `scoreboard.slab`.
- For `rebar3 new concrete_app name=my_app` to work before any project
  exists (bootstrapping), `concrete` must be registered in
  `~/.config/rebar3/rebar.config`'s global `{plugins, [...]}` — that's
  the one-line install instruction, not a custom `concrete new` CLI
  provider.

## Directory layout

New files, flat, under `priv/templates/`, distinct from
`scoreboard.slab`:

```
priv/templates/
  concrete_app.template          # index file
  concrete_new_app.erl           # -> {{name}}_app.erl
  concrete_new_sup.erl           # -> {{name}}_sup.erl
  concrete_new_page.erl          # -> {{name}}_page.erl (page module)
  concrete_new_counter.erl       # -> counter.erl (component)
  concrete_new_page.slab         # -> priv/templates/page.slab
  concrete_new_counter.slab      # -> priv/templates/counter.slab
  concrete_new.app.src           # -> {{name}}.app.src
  concrete_new_rebar.config      # -> rebar.config
  concrete_new_gitignore         # -> .gitignore
  concrete_new_README.md         # -> README.md
```

## File contents

### `priv/templates/concrete_app.template` (index)

```erlang
{description, "A new Concrete (isomorphic web framework) application"}.
{variables, [
    {name, "my_app", "Name of the OTP application"},
    {port, "4000", "HTTP listener port"}
]}.

{dir, "{{name}}"}.
{dir, "{{name}}/src"}.
{dir, "{{name}}/priv/templates"}.

{template, "concrete_new_app.erl",      "{{name}}/src/{{name}}_app.erl"}.
{template, "concrete_new_sup.erl",      "{{name}}/src/{{name}}_sup.erl"}.
{template, "concrete_new_page.erl",     "{{name}}/src/{{name}}_page.erl"}.
{template, "concrete_new_counter.erl",  "{{name}}/src/counter.erl"}.
{template, "concrete_new_page.slab",    "{{name}}/priv/templates/page.slab"}.
{template, "concrete_new_counter.slab", "{{name}}/priv/templates/counter.slab"}.
{template, "concrete_new.app.src",      "{{name}}/src/{{name}}.app.src"}.
{template, "concrete_new_rebar.config", "{{name}}/rebar.config"}.
{file,     "concrete_new_gitignore",    "{{name}}/.gitignore"}.
{template, "concrete_new_README.md",    "{{name}}/README.md"}.
```

(`{dir, "{{name}}"}` creates a subdirectory, matching rebar3's own
`release`/`app` templates. Confirm at implementation time whether this
is the desired UX vs. generating into `.`.)

### `priv/templates/concrete_new.app.src`

```erlang
{application, {{name}}, [
    {description, "A Concrete application"},
    {vsn, "0.1.0"},
    {registered, [{{name}}_sup]},
    {mod, {{{name}}_app, []}},
    {applications, [kernel, stdlib, concrete]},
    {env, []},
    {modules, []},
    {licenses, ["Apache-2.0"]},
    {links, []}
]}.
```

### `priv/templates/concrete_new_app.erl`

```erlang
-module({{name}}_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, _} = application:ensure_all_started(concrete),
    {{name}}_sup:start_link().

stop(_State) -> ok.
```

This is the "reuse `concrete_app`" contract: the generated app's own
`_app`/`_sup` is a thin top-level app that boots `concrete` (which
starts `concrete_sup`, the cowboy listener, registry, pubsub) and
supervises nothing else of its own unless the user adds children —
matches CLAUDE.md's stated architecture where user apps just add
page/component modules, not reimplement the server stack.

### `priv/templates/concrete_new_sup.erl`

```erlang
-module({{name}}_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
```

Empty children list — generated app has no app-specific processes;
page/component state lives in `concrete_registry`. Real projects add
children here later.

### `priv/templates/concrete_new_page.erl`

```erlang
-module({{name}}_page).
-behaviour(concrete_page).
-concrete([{route, "/"}]).
-export([init/2, template/0]).

init(_Params, Server) ->
    {#{state => #{}}, Server}.

template() ->
    "page.slab".
```

### `priv/templates/concrete_new_page.slab`

```html
<div class="page">
  <h1>Welcome to {{name}}</h1>
  <:component module={counter} initial_value={0} />
</div>
```

(mirrors `test/renderer_SUITE_data/fixture_page.slab`'s `<:component .../>`
embedding pattern)

### `priv/templates/concrete_new_counter.erl`

Matches CLAUDE.md's canonical component example:

```erlang
-module(counter).
-behaviour(concrete_component).
-export([init/2, action/3, template/0]).

init(Props, Server) ->
    Count = maps:get(initial_value, Props, 0),
    {#{state => #{count => Count}}, Server}.

action(increment, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count := N + 1}};
action(decrement, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count := N - 1}}.

template() ->
    "counter.slab".
```

### `priv/templates/concrete_new_counter.slab`

```html
<div class="counter">
  <p>Count: {@count}</p>
  <button concrete-click="increment">+</button>
  <button concrete-click="decrement">-</button>
</div>
```

### `priv/templates/concrete_new_rebar.config`

```erlang
{erl_opts, [debug_info]}.

{deps, [
    {concrete, {git, "https://github.com/<ORG>/concrete.git", {branch, "main"}}}
]}.

%% Registers concrete's rebar_compiler_concrete plugin so `rebar3 compile`
%% also produces JS bundles for every page module in this project.
{project_plugins, [
    {concrete, {git, "https://github.com/<ORG>/concrete.git", {branch, "main"}}}
]}.

{shell, [
    {apps, [{{name}}]}
]}.
```

**Flagged risk** (verify first during the smoke test): `concrete` is
declared twice — once as a regular `{deps,...}` (so `concrete_page`,
`concrete_component`, `concrete_app` etc. are on the compile/runtime
path) and once as `{project_plugins,...}` (so `rebar_compiler_concrete`
is registered into the DAG via `concrete:init/1`). This dual-fetch is
an unusual but supported rebar3 pattern — confirm it actually works
before shipping. Fallback if it errors: drop the `{deps,...}` copy;
`.app.src`'s `{applications,...}` listing `concrete` may be sufficient
for runtime linking even without a duplicate `{deps,...}` entry, since
`project_plugins` also makes the compiled app available on the regular
code path in newer rebar3 — confirm via smoke test which one actually
satisfies both compile-time and plugin-time needs, and adjust the
template accordingly.

### `priv/templates/concrete_new_gitignore`

```
_build/
rebar.lock
.rebar3/
priv/js/bundles/
priv/concrete_manifest.json
priv/concrete.plt
```

### `priv/templates/concrete_new_README.md`

```markdown
# {{name}}

A [Concrete](https://github.com/<ORG>/concrete) app.

## Run

    rebar3 shell

Then visit http://localhost:{{port}}/ — click the counter buttons; the
click dispatches `counter:action/3`, compiled to JS at build time by
`rebar_compiler_concrete` and executed in the browser, then patches the DOM.

## Structure

- `src/{{name}}_page.erl` — page module, routed at `/`
- `src/counter.erl` — interactive component
- `priv/templates/*.slab` — templates
```

## No companion CLI provider

Bare `rebar3 new concrete_app name=my_app` is sufficient once
`concrete` is registered as a plugin. Do not build a `concrete new`
provider — it would duplicate `rebar3 new`'s variable-substitution/
scaffolding engine for zero benefit. Ship one line of install
instructions in the top-level README:

```erlang
%% ~/.config/rebar3/rebar.config
{plugins, [{concrete, {git, "https://github.com/<ORG>/concrete.git", {branch, "main"}}}]}.
```

then `rebar3 new concrete_app name=my_app` works from any directory.
If `concrete` is later published to hex, this collapses to
`{plugins, [concrete]}`.

## Verification (manual smoke test)

```bash
# Register locally for testing (path dep instead of git).
mkdir -p ~/.config/rebar3 && cat >> ~/.config/rebar3/rebar.config <<'EOF'
{plugins, [{concrete, {path, "/Users/wmealing/Projects/elixir/concrete"}}]}.
EOF

rebar3 new concrete_app name=demo_app
cd demo_app
rebar3 compile                       # confirm build succeeds AND priv/js/bundles/*.mjs + concrete_manifest.json appear
rebar3 shell                         # boots demo_app_app -> concrete_app -> concrete_sup -> cowboy on :4000
curl -s http://localhost:4000/       # confirm page HTML + bootstrap <script> tag present
# open in browser: click +/- and confirm DOM count updates without full reload (hydration path)
```

Confirm specifically:

- `priv/js/bundles/demo_app_page_<hash>.mjs` exists (proves
  `rebar_compiler_concrete:compile/4` ran).
- `priv/concrete_manifest.json` maps `"demo_app_page"` to the bundle
  filename (proves `concrete_assets:bundle_url/1` resolves correctly).
- Re-running `rebar3 compile` with no source changes does not rebuild
  (once `bundle_is_stale/2` is fixed) — confirms the Part A fix, not
  just Part B scaffolding.

## Post-implementation notes

This plan was implemented, and the design changed in one deliberate
way plus several bugs were found and fixed via real end-to-end testing
(a throwaway local git mirror of the working tree, used as a
`{git, "file://...", ...}` dependency, so `rebar3 new` → `rebar3
compile` → boot → curl → click-in-jsdom could all be exercised for
real instead of trusted from a read of the code).

**Design change**: dropped the separate `counter` component embedded
via `<:component>` in the scaffolded page. `client.js`'s DOM renderer
explicitly throws `"client-side component embedding is not supported
yet (Phase 5)"` for nested `<:component>` tags — so a page that embeds
a component can never be interactive client-side today, no matter how
correct the compiler pipeline is. The scaffold instead puts `action/3`
directly on the page module, exactly like the existing, working
`example/scoreboard_page.erl` does. `concrete_new_counter.erl`/
`concrete_new_counter.slab` were deleted; `concrete_new_page.erl`/
`concrete_new_page.slab` carry the counter logic directly.

**Bugs found and fixed along the way** (all pre-existing, not
introduced by Part A — Part A's registration work is what first
exercised them for real):

1. `rebar_compiler_concrete:context/1` was missing the `include_dirs`
   key required by rebar3's real `rebar_compiler` behaviour contract —
   crashed `rebar3`'s compiler core against any app in the build.
2. `needed_files/4` returned the wrong shape (`{Changed, []}`) — the
   real contract is `{{FirstFiles,Opts},{RestFiles,Opts}}`. Fixed to
   `{{[], []}, {Changed, AppInfo}}`, threading `AppInfo` through as the
   `Opts` term `compile/4` receives as its 4th argument.
3. `populate_mfa/2` pattern-matched `{ok, #{'definitions' := Defs}}` (a
   map) against what `concrete_beam_reader` actually returns
   (`#ir_module{definitions = Defs}`, a record) — could never match,
   so PLT population was silently a no-op.
4. `compile/4` never encoded the page's `.slab` template into a
   client-side `render/1`, unlike the hand-rolled `template_demo.erl`
   pattern — a bundle built by the "wired up" plugin had no render
   function at all. Fixed by adding `render_function_js/2`, mirroring
   `template_demo.erl`'s `bundle_js/1`.
5. `concrete_call_graph:build/2` only rooted the graph at `init/2` and
   `template/0` — `action/3` (and `command/3`) are invoked directly by
   the browser/client dispatch, never via a traceable Erlang call from
   those two roots, so a page's click handler was silently eliminated
   as "dead code." Fixed by adding them as conditional extra roots
   when present in the PLT (`concrete_call_graph:build_from_entries/2`
   is the new general entry point).
6. `plugin/rebar_compiler_concrete.erl` lived under a separate
   `plugin/` `extra_src_dirs` entry. `extra_src_dirs` output beams land
   in a directory mirroring the source dir name (`.../plugin/*.beam`),
   never `ebin/` — and rebar3's project-plugin loader only ever adds
   `ebin/` to the code path. This made the plugin work exactly once
   (compiled in-memory during the initial dependency-fetch pass) and
   `undef` on every subsequent `rebar3 compile`. Fixed by moving the
   module to `src/rebar_compiler_concrete.erl` and dropping the
   `extra_src_dirs` entry entirely (see `part-a.md`).
7. `concrete_app:page_modules/0` discovered page modules via
   `code:all_loaded/0` — but `concrete` (and this callback) starts
   *before* the application that actually defines page modules (a
   generated project depends on `concrete`, not the other way round),
   so those modules were never loaded yet at the point this ran.
   Fixed to scan `code:get_path()` on disk instead (same approach
   `rebar_compiler_concrete:find_page_modules/1` already used
   correctly) — calling `Module:module_info/1` on an unloaded module
   loads it on demand.
8. `concrete_app:load_manifest/0` read
   `code:priv_dir(concrete)/concrete_manifest.json` — concrete's own
   library priv dir — but the manifest is written into the *generated
   project's* priv dir by the compiler plugin. Fixed to scan every
   application directory on the code path and merge any
   `concrete_manifest.json` found (same disk-scan pattern as #7).
9. Both `concrete_app:load_manifest/0` and
   `rebar_compiler_concrete:update_manifest/3` assumed
   `thoas:decode/1` returns the decoded map directly; it actually
   returns `{ok, Map}`. This hadn't surfaced yet because no manifest
   file existed at either read point in prior testing — a second page
   module or a second build would have hit `{badmap, {ok, _}}`. Fixed
   to pattern-match `{ok, Map}`.
10. `concrete_router:route_for/1` had one extra level of list-pattern
    nesting than what `-concrete([{route, "/"}])` actually produces in
    `Module:module_info(attributes)` (verified directly: a single
    custom attribute declaration is *not* further wrapped in a list).
    This crashed `concrete_router:start/1` with a `function_clause` in
    `proplists:get_value/3` the moment any real page module was routed
    — i.e. the router had never actually routed a real compiled page
    before this fix.

None of these had any test coverage (`grep` for `concrete_router`,
`concrete_app`, `rebar_compiler_concrete` in `test/` turns up nothing),
which is exactly how they survived. `rebar3 ct` was re-run after every
fix and stayed at 176/176 throughout.
