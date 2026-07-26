# Part A — Fix the broken OTP application skeleton

## Context

`concrete_app.erl` is supposed to be the reusable "start my app" entry
point (cowboy listener + registry + pubsub, all supervised), but it has
never actually run:

- `src/concrete.app.src` has no `{mod, {concrete_app, []}}` tuple, so
  `application:start(concrete)` never calls `concrete_app:start/2` at all.
- Even if it were called, `concrete_app:start/2` calls
  `supervisor:start_link({local, concrete_sup}, concrete_sup_mod, Children)`
  — `concrete_sup_mod` does not exist anywhere in the repo, and the
  call signature is wrong anyway (`supervisor:start_link/3`'s 3rd arg
  is `Args` passed to a callback module's `init/1`, not a raw
  child-spec list).
- `plugin/rebar_compiler_concrete.erl` implements real JS-bundle
  compilation but isn't compiled by anything (`rebar.config` has no
  `extra_src_dirs` entry for `plugin/`) and isn't registered as a
  rebar3 compiler, so `rebar3 compile` never invokes it.
- Every currently-working example (`concrete_demo.erl`,
  `template_demo.erl`, `todo_demo.erl`) bypasses all of this and
  hand-rolls its own `cowboy:start_clear/3` + `cowboy_router:compile/1`.

No test suite references `concrete_app`, `concrete_sup`, or
`rebar_compiler_concrete` today — Part A is unconstrained by existing
tests, only by "don't break the 176 passing" (`rebar3 ct`).

Fixing this is the prerequisite for Part B (a `rebar3 new` project
generator) — scaffolding a generator around a broken "start my app"
story would be premature.

## Changes

### 1. `plugin/rebar_compiler_concrete.erl` — MODIFY

- Add `-include("concrete_ir.hrl").` — the file uses
  `#ir_function_def{}` (in `populate_mfa/2`) without including the
  header; it would fail to compile the moment it's added to a src path.
- Fix `bundle_is_stale/2`: currently hardcoded to always return `true`
  (no real incremental compilation). Implement a real staleness check:
  compare the page module's current BEAM digest (via
  `concrete_beam_reader`/`beam_lib:md5/1`) against a digest recorded in
  the PLT the last time that bundle was built (during `compile/4`),
  falling back to `true` only when there's no recorded digest yet.
- No signature changes to `context/1`, `needed_files/4`,
  `dependencies/3`, `compile/4`, `clean/2` — preserve exactly.

### 2. `src/concrete.erl` — MODIFY

Add a rebar3 plugin entry point (module name matches the OTP app name,
which is how rebar3 discovers a plugin's `init/1`):

```erlang
-export([init/1]).

%% rebar3 plugin entry point: registers rebar_compiler_concrete into the
%% compiler pipeline for any project that lists `concrete` under
%% {plugins,...} / {project_plugins,...}.
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    {ok, rebar_state:append_compilers(State, [rebar_compiler_concrete])}.
```

No conflicts with existing exports (`compile/1`, `compile_module/1`,
`compile_to_file/2`, `runtime_path/0`, `client_path/0`).

### 3. `rebar.config` — MODIFY

Add `plugin/` to the base source dirs so `rebar_compiler_concrete.erl`
actually compiles as part of `concrete`'s own build:

```erlang
{erl_opts, [debug_info, {i, "include"}]}.
{extra_src_dirs, ["plugin"]}.
```

Leave `{plugins, [rebar3_ex_doc]}` alone — `concrete` does not need to
register itself as its own plugin for its own build (the existing
examples don't use the compiler pipeline; `pipeline_SUITE` calls
transformer/encoder directly).

### 4. `src/concrete.app.src` — MODIFY

```erlang
{application, concrete, [
    {description, "Erlang port of Hologram — full-stack isomorphic web framework"},
    {vsn, "0.1.0"},
    {registered, [concrete_sup, concrete_assets, concrete_registry]},
    {mod, {concrete_app, []}},
    {applications, [kernel, stdlib, cowboy, gproc, thoas]},
    {env, [{port, 4000}]},
    {modules, []},
    {licenses, ["Apache-2.0"]},
    {links, []}
 ]}.
```

This is the fix that makes `application:start(concrete)` actually call
`concrete_app:start/2` — currently dead code.

### 5. `src/concrete_sup.erl` — NEW

```erlang
-module(concrete_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

-spec start_link(map()) -> {ok, pid()}.
start_link(Manifest) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Manifest]).

init([Manifest]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{id => concrete_pg,
          start => {pg, start_link, [concrete_pubsub]},
          restart => permanent, shutdown => 5000, type => worker, modules => [pg]},
        #{id => concrete_assets,
          start => {concrete_assets, start_link, [Manifest]},
          restart => permanent, shutdown => 5000, type => worker, modules => [concrete_assets]},
        #{id => concrete_registry,
          start => {concrete_registry, start_link, []},
          restart => permanent, shutdown => 5000, type => worker, modules => [concrete_registry]}
    ],
    {ok, {SupFlags, Children}}.
```

Design decisions:

- `pg:start(concrete_pubsub)` (the previous unsupervised, unreachable
  call) is replaced with a real supervised child
  `{pg, start_link, [concrete_pubsub]}`.
- `cowboy:start_clear/3` (inside `concrete_router:start/1`) is **not**
  wrapped as a supervisor child — cowboy already registers its
  listener under `ranch_sup` (its own supervision tree); wrapping it
  would need a one-shot task child spec for no real benefit. This
  preserves existing `concrete_router` behavior untouched, called from
  `concrete_app:start/2` after the supervisor is up.
- `concrete_assets:start_link/1` and `concrete_registry:start_link/0`
  signatures are unchanged — only their supervision wiring changes.

### 6. `src/concrete_app.erl` — MODIFY

```erlang
-module(concrete_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Manifest = load_manifest(),
    case concrete_sup:start_link(Manifest) of
        {ok, Pid} ->
            PageModules = page_modules(),
            {ok, _} = concrete_router:start(PageModules),
            {ok, Pid};
        {error, _} = Err ->
            Err
    end.

stop(_State) -> ok.

load_manifest() -> ...  %% unchanged
page_modules() -> ...   %% unchanged
is_page_module(Module) -> ... %% unchanged
```

Fixes: removes the bogus `concrete_sup_mod`/raw-child-spec
`supervisor:start_link/3` call, removes the unreachable `pg:start`
(now supervised inside `concrete_sup`), returns `{ok, Pid}` as OTP
requires (previously this app had never successfully started).

### 7. `src/concrete_registry.erl` — MODIFY (minimal, keep API)

`register/2`, `lookup/1`, `unregister/1` already delegate straight to
`gproc` (which manages its own state, not the placeholder pid). Keep
that API exactly; just make the placeholder process not crash on
unexpected messages:

```erlang
start_link() ->
    Pid = spawn_link(fun loop/0),
    {ok, Pid}.

loop() ->
    receive
        stop -> ok;
        _    -> loop()
    end.
```

A "genuinely real" registry (its own ETS table, ignoring gproc) is out
of scope — not requested, and `concrete_registry`'s job today is
purely a facade in front of `gproc`, which is correct per `gproc`'s
own design.

### 8. `src/concrete_router.erl` — MODIFY (configurable port/host)

```erlang
start(PageModules) ->
    Dispatch = cowboy_router:compile([{'_', routes(PageModules)}]),
    Port = application:get_env(concrete, port, 4000),
    TransportOpts = case application:get_env(concrete, ip) of
        {ok, Ip} -> [{port, Port}, {ip, Ip}];
        undefined -> [{port, Port}]
    end,
    cowboy:start_clear(concrete_http, TransportOpts, #{
        env => #{dispatch => Dispatch}
    }).
```

`routes/1`, `page_routes/1`, `route_for/1`, `system_routes/0`
unchanged.

### 9. `src/concrete_pubsub.erl`, `src/concrete_assets.erl`, `src/concrete_runtime.erl` — NO CHANGES

All three are already correct and reusable as-is; `concrete_pubsub`
just needs `pg:start_link(concrete_pubsub)` to have run once (now via
`concrete_sup`).

## Verification

```bash
rebar3 compile                       # confirms plugin/ compiles cleanly (new include), concrete_sup compiles
rebar3 ct                            # must stay at 176/176 passing
erl -pa _build/default/lib/*/ebin -eval \
  'application:ensure_all_started(concrete), \
   io:format("~p~n", [supervisor:which_children(concrete_sup)]), halt().'
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/  # listener answers
```

Also manually verify `application:get_env(concrete, port)` override:
start with `{concrete, [{port, 4321}]}` in a `sys.config` and confirm
the listener binds 4321.

Must not touch `example/todo_app.erl`, `example/todo_demo.erl`, or any
of the todo demo files — those are finished, tested, and out of scope.

## Post-implementation notes

Everything above was implemented and verified (`rebar3 ct` stays at
176/176; `application:ensure_all_started(concrete)` actually starts
and `concrete_sup` shows all three children; the cowboy listener binds
and answers; the port override works).

Building the Part B scaffold end-to-end (a generated project actually
running `rebar3 compile` more than once, and actually booting and
serving a page) surfaced several additional pre-existing bugs beyond
what was scoped above, fixed as part of that work — see `part-b.md`'s
post-implementation notes for the full list. The one most relevant
here: `plugin/rebar_compiler_concrete.erl` was moved to
`src/rebar_compiler_concrete.erl` and the `{extra_src_dirs, ["plugin"]}`
rebar.config entry was removed — `extra_src_dirs` output beams land in
a directory mirroring the source dir name (`plugin/*.beam`), never
`ebin/`, and rebar3's project-plugin loader only ever adds `ebin/` to
the code path. Keeping the compiler module in `src/` like every other
module is what actually makes it loadable as a plugin on every run,
not just the first.
