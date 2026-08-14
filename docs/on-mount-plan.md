# Plan: an `on_mount` lifecycle hook

## Problem

Concrete has no callback that runs automatically, once, after a
component's markup is actually in the DOM. Anything that needs to run
at that point today — opening an SSE stream, wiring a `dom:on_keydown`
listener, reading `localStorage` — has to be smuggled into `render/1`
(the only thing the client runtime calls automatically and
unconditionally), and that requires three workarounds every time:

1. **A server-side guard.** `render/1` runs twice: compiled to JS in
   the browser, and as plain Erlang on the server, to produce the
   page's first HTML (`concrete_renderer` evaluates the template
   directly against the module). `dom:*`/`sse:*` don't exist as real
   Erlang functions, so any call to them from server-side `render/1`
   raises `undef`. Every caller ends up writing the same
   `try ... catch error:undef -> ok end` around the one call that
   kicks off the real work, just to survive running twice.

2. **A deferred tick.** The client runtime always rebuilds the
   container's DOM right after the render/1 call that reached the
   mount code (first render clears and rebuilds `Client.container`
   wholesale; see `client.js`'s `render()`). Anything done
   synchronously during that same call gets wiped a moment later, so
   the real work has to be wrapped in `dom:set_timeout(0, ...)` to run
   on the next tick instead — one extra indirection, and an extra
   function (`do_mount/1` alongside `mount/1`) purely to hold it.

3. **A reachability anchor.** `concrete_call_graph`'s dead-code
   elimination only follows literal call nodes in a clause body — not
   calls inside an anonymous fun, not a bare atom passed as a
   `Module`/`Function` pair to `sse:connect`/`dom:on_click`/
   `dom:on_keydown`, and not a call used as an argument expression
   (`dom:set_value(Id, some_call())`). Every function only ever reached
   through one of those (which is most of what a mount-style function
   calls, by nature) has to be given a second, fake call site — a
   dead branch behind a literal `false`, called from somewhere the
   walker does trace — just so it survives into the compiled bundle.

None of this is specific to any one app. Every non-trivial use of
`sse:connect`/`dom:on_click`/`dom:on_keydown` hits all three, in the
same order, for the same underlying reason: there's no dedicated place
to put "runs once, after mount, client-side only" code.

## Goals

- A `mount/1` (page) and `mount/2` (component) optional callback,
  invoked automatically, exactly once per component instance, after
  that instance's markup is in the real DOM.
- Never invoked server-side. Removes the `try/catch error:undef`
  workaround entirely — a module that defines `mount/1` shouldn't need
  to know or care that `render/1` also runs on the server.
- Runs at a point where DOM manipulation is already safe — removes the
  `dom:set_timeout(0, ...)` deferral.
- A real call-graph root, the same way `action/3` is today (see
  `concrete_call_graph:page_entries/2`) — removes the reachability
  anchor. Anything `mount/1`/`mount/2` calls, directly or indirectly,
  gets traced normally.

## Non-goals (v1)

- **Per-instance mount for `<:component>`.** This needs solving first
  as its own project — see "Blocked on: persistent component
  instances" below. v1 ships page-level `mount/1` only.
- **`on_unmount`.** A natural companion (an `sse:connect`ed component
  that disappears from the tree should close its stream), but it
  depends on the same instance-identity work component-level
  `mount/2` does. Tracked as a fast-follow once that groundwork
  exists, not blocking v1.
- Changing anything about `action/3`/`command/3` dispatch. This is
  additive.

## Proposed API

```erlang
-module(concrete_page).

-callback init(Params :: map(), Server :: map()) ->
    {Component :: map(), Server :: map()}.

-callback template() -> TemplateFile :: string() | {inline, term()}.

%% New:
-callback mount(Component :: map()) -> ok.

-optional_callbacks([init/2, mount/1]).
```

`Component` is whatever `init/2` returned, wire-decoded — the exact
same term shape `action/3`'s third argument already is, so anyone who
has written an `action/3` clause already knows the shape of what
`mount/1` receives. No return value is used; `mount/1` runs purely for
its side effects, the same way `action/3`'s compiled body already
calls `dom:*`/`sse:*` for theirs.

`concrete_component`'s eventual `mount/2` (Props, Component — Phase 2)
mirrors `action/3`'s `(ActionName, Params, Component)` shape rather
than introducing a new convention.

## Design

### Where it's called from

Not from `render/1` — `mount/1` becomes the runtime's job to invoke,
not the template author's. `client.js`'s `Client.init()`, right after
its one-time DOM rebuild:

```js
init(moduleName, containerId, stateJSON) {
  Client.module = moduleName;
  Client.container = document.getElementById(containerId);
  const wire = typeof stateJSON === "string" ? JSON.parse(stateJSON) : stateJSON;
  Client.component = Client.deserialize(wire);
  Client.server = Type.map([]);
  Client.container.addEventListener("click", /* ... unchanged ... */);
  Client.render();
  Client.mount();          // <-- new
},

mount() {
  if (!Interpreter.isExported(Client.module, "mount", 1)) return;
  const state = Interpreter.mapLookup(Client.component, Type.atom("state")) || Type.map([]);
  Interpreter.call(Client.module, "mount", 1, [Client.component]);
},
```

Calling it after `Client.render()` (not inside it) means the DOM is
already in its final first-render state — no wipe to defer past, no
`dom:set_timeout(0, ...)`, no `do_mount/1` indirection. `mount/1`'s
body reads exactly like `action/3`'s already does.

`Interpreter.isExported/3` is new — a cheap guard so pages that don't
define `mount/1` (the overwhelming majority, unaffected by any of
this) don't pay for a lookup against a function that was never
compiled in. `Interpreter.defineErlangFunction` already registers
functions in a lookup table keyed by name/arity; exposing an existence
check against that same table is a small addition, not a new
subsystem.

### Never runs server-side

`concrete_page_handler` calls `Module:init/2` and renders the template
to produce the first HTML — it should simply never call `mount/1` at
all. Since invocation moves out of `render/1` and into `Client.init()`
(a client-only entry point that has no server-side equivalent — there
is no `concrete_renderer:mount_page/2`), this is automatic, not an
extra guard to remember. The `try/catch error:undef` workaround stops
being necessary because the code that used to need it (a server-side
call to a browser-only BIF) no longer exists.

### Reachability

`concrete_call_graph:page_entries/2` adds `mount/1` to the root list
exactly the way it already adds `action/3` — conditionally, when the
module defines it:

```erlang
page_entries(PageModule, PLT) ->
    BaseEntries = [{PageModule, init, 2}, {PageModule, template, 0}],
    ExtraEntries = [E || E <- [{PageModule, action, 3}, {PageModule, mount, 1}],
                          concrete_plt:get(PLT, E) =/= not_found],
    BaseEntries ++ ExtraEntries.
```

(`command/3` stays excluded, per the existing comment there — it's
never compiled-to-JS-reachable, `mount/1` is.)

This is the part that actually removes the reachability-anchor
workaround: everything `mount/1` calls — `sse:connect`,
`dom:on_keydown`, a helper function passed as a bare atom callback —
is now reached by ordinary call-graph tracing rooted at a real,
always-present entry point, the same as everything `action/3` calls
already is. No dead `case false of true -> ... end` branch required.

## Blocked on: persistent component instances

The natural next step — `mount/2` firing once per `<:component>`
instance, when *that* instance's markup first appears — runs into an
existing gap that has nothing to do with mount specifically:
`<:component>` embedding has no persistent instance at all today.

`client.js`'s `resolveComponentDom` (shared by both the plain-HTML
renderer and the vnode builder) re-runs `Module:init/2` from scratch,
every single time the *parent* re-renders:

```js
resolveComponentDom(modAtom, propsListTerm) {
  const modName = modAtom.value;
  const propsMap = Type.map(propsListTerm.data.map((pair) => pair.data));
  const initResult = Interpreter.call(modName, "init", 2, [propsMap, Type.map([])]);
  const childComponent = initResult.data[0];
  // ...
  return Interpreter.call(modName, "render", 1, [childState]);
},
```

There's no cache, no key, no persisted state between calls — a
`<:component>` is really syntactic sugar for "inline this markup,"
re-derived fresh on every parent render. A `mount/2` firing "once" has
no well-defined meaning yet, because there's no stable "once" to
attach it to: the component doesn't have a lifetime independent of its
parent's own re-renders, and neither does any state it might hold.

Solving that is a separate, larger piece of work, and a prerequisite
worth calling out explicitly rather than working around:

- A stable identity per `<:component>` call site (or explicit `key`
  prop, React-style, for repeated/list-rendered components) that
  survives across parent re-renders.
- Persisted per-instance state, keyed by that identity, so a
  component's own state isn't silently reset every time its parent
  renders.
- Mount/unmount *detection* during diffing — the vnode differ needs to
  notice "this instance's identity wasn't in the previous tree" (→
  mount) and "this identity from the previous tree isn't in the new
  one" (→ unmount), not just patch attributes and children in place.

`concrete_registry.erl` already exists in the tree — "gproc-based
registry mapping component instance IDs to PIDs" — but its `register`/
`lookup`/`unregister` functions aren't called from anywhere yet
(`concrete_sup` starts it; nothing else references it). It's a
plausible foundation for the identity half of this — worth checking
whether it was scaffolded with exactly this in mind before designing a
second one — but the diffing/lifecycle half is greenfield.

**Recommendation:** ship page-level `mount/1` now (small, self-
contained, immediately removes real pain), and scope persistent
component instances as its own plan once there's a concrete component
that needs it — trying to design both at once risks either shipping
neither, or bending the simple page-level design around requirements
a real second use case hasn't actually confirmed yet.

## Implementation milestones

1. `Interpreter.isExported(module, name, arity)` in `runtime.js`,
   backed by the existing `defineErlangFunction` registration table.
2. `-callback mount(Component) -> ok.` + `-optional_callbacks` on
   `concrete_page`; same on `concrete_component` (unused until Phase
   2, but the shape should exist so example apps can write forward-
   compatible code).
3. `concrete_call_graph:page_entries/2`: add the conditional
   `{Module, mount, 1}` entry.
4. `client.js`: `Client.mount()`, called once from `Client.init()`
   after the first `Client.render()`.
5. Update `example/counter_app` (or add a new minimal example) to use
   `mount/1` for something real — `dom:on_keydown_global` is a good
   candidate, since the counter example doesn't currently need SSE.
6. Docs: this is the natural next blog post once shipped — the
   `clowning` chat app in the tutorial series is already exercising
   exactly the workaround this removes, so before/after is a clean
   comparison.

## Testing

- `client_SUITE` (or wherever `Client.init`/`render` already has
  coverage): a fixture module with `mount/1` that calls a `dom:*` BIF
  and asserts the resulting DOM, run through the same harness the
  existing action/render tests use.
- A fixture module *without* `mount/1` defined, asserting
  `Client.mount()` is a no-op (no `Interpreter.call` on a
  nonexistent function, no thrown error) — this is the common case and
  needs to stay free.
- `concrete_call_graph` unit test: a module with `mount/1` calling a
  helper only reachable that way; assert the helper appears in
  `reachable/1`'s output. A second case with no `mount/1` defined,
  asserting nothing extra gets added.
- An encoder-level test compiling a `mount/1` that calls
  `sse:connect/3` with a bare atom callback, asserting the callback
  target is present in the compiled bundle — this is the exact
  scenario the reachability anchor exists to work around today, and
  the test that proves it's no longer needed.

## Open questions

- **Naming.** `mount/1` matches the LiveView/Hologram convention most
  readers will already know; `on_mount/1` reads more explicitly as an
  event hook and pairs more naturally with a future `on_unmount/1`.
  Leaning `mount/1` for the page case (parallels `init/2`, `action/3`,
  `template/0` — no `on_` prefix anywhere else in `concrete_page`), but
  worth a second opinion before locking it in, since it's the kind of
  thing that's annoying to rename once example code exists.
- **Arity for the page case.** `mount/1` (just `Component`) is enough
  for everything in this plan and matches what's actually needed
  today. If a use case needs `Server` too, `mount/2` mirroring
  `init/2`'s `(Params, Server)` shape is the natural extension — not
  adding it speculatively now.
- **Should `mount/1`'s (non-)return value ever matter?** Proposed as
  pure side effect, matching how `action/3`'s compiled body already
  freely calls `dom:*`/`sse:*` without those calls' return values
  feeding back into anything. Keeping it that way avoids a second,
  parallel state-merge path alongside the one `action/3`'s return
  value and `command/3`'s response already have.
