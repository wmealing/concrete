-module(concrete_js).

%% Tells concrete_beam_reader:extract_ir/1 to refuse to trace into this
%% module's real (harmless pass-through) bodies, the same as it already
%% refuses for dom/canvas/http, which have no .erl source to trace at
%% all. Without this, the call graph walk would pull concrete_js's real
%% bodies into the bundle and register them under the exact same
%% Erlang["concrete_js:fun/arity"] keys runtime.js's hand-written native
%% BIFs use, silently overwriting them. See extract_ir/1 for the check.
-concrete([{bif_module, true}]).

-moduledoc """
Interop with arbitrary JavaScript already loaded in the browser -- a
library pulled in via a plain `<script>` tag (three.js, Chart.js, etc.),
not something Concrete bundles or manages.

```erlang
Scene = concrete_js:new('THREE.Scene', []),
Geo   = concrete_js:new('THREE.BoxGeometry', [1, 1, 1]),
Mesh  = concrete_js:new('THREE.Mesh', [Geo]),
concrete_js:call(Scene, add, [Mesh]).
```

## No compiler support needed

Every function here compiles like any other remote call -- Concrete's
encoder has no special case for this module. `concrete_encoder` always
emits `Erlang["Mod:Fun/Arity"](Args)` for a remote call, so
`concrete_js:call/2` resolves at runtime to an entry in the `Erlang`
BIF table in `priv/js/demo/runtime.js`, exactly the same path
`dom:*`/`canvas:*` already use. Unlike `dom:*`/`canvas:*` (which have
no `.erl` source at all), this module *does* have real, traceable
abstract code -- its `-concrete([{bif_module, true}])` attribute above
is what tells `concrete_beam_reader:extract_ir/1` to refuse to trace
into it, so the call graph walk never pulls its harmless pass-through
bodies into a bundle and overwrites the hand-written native BIFs.
Any future native-JS-fronting module needs the same attribute.

## The `?js` shorthand

The module can't just be named `js` -- Erlang has one flat, global
module namespace, and a name that generic is too likely to collide
with a project's own module. `include/concrete_js.hrl` defines
`-define(js, concrete_js).` as an opt-in, project-local shorthand:

```erlang
-include_lib("concrete/include/concrete_js.hrl").

?js:call(Element, addEventListener, [click, fun(_Event) -> ok end]).
```

## `Receiver` / `ClassPath` / `Method` / `Prop` arguments

A `Receiver` or `ClassPath` argument is either:

- a dotted path resolved against the browser's global scope, given as
  a binary (`<<"console.log">>`) or an atom -- quoted if it isn't a
  valid bare atom (`'THREE.Scene'`), unquoted otherwise (`add`). An
  atom is the more idiomatic choice for a name that's fixed at compile
  time, and reads better than binary syntax; or
- a native handle returned by a previous `new/2`, `call/2`, `call/3`,
  or `get/2`.

`Method` and `Prop` arguments accept the same binary-or-atom choice.

## Passing an Erlang fun as a JS callback

Any argument to `call/2`, `call/3`, `new/2`, or `set/3` can be an
ordinary Erlang `fun` -- it is wrapped as a real, callable JS function,
so it works anywhere a native API wants a callback:

```erlang
?js:call(Element, addEventListener, [click, fun(_Event) -> ok end]),
?js:set(Element, onclick, fun(_Event) -> ok end).
```

A callback fun follows the same "cold entry point" rule `await/1`
does: it must finish in one step, with no blocking `receive` -- see
`await/1`'s docs for why.

## Values that aren't plain Concrete terms

A value that isn't representable as a plain Concrete term (a class
instance, a function) becomes an opaque `{js_native, Type, Ref}`
handle. Passing that handle into a later call resolves it back to the
real JS value.

## Errors

A native call that throws surfaces as an ordinary `{js_error, Reason}`
error, catchable with a plain `try`/`catch`.

## Running on the real BEAM

Every function here has a harmless server-side pass-through body, so
code that calls this module still runs (producing an inert stub
result) if it executes on the real BEAM -- `action/3` clauses do run
there sometimes, when a browser dispatches an action over
`concrete_ws_handler` instead of running the compiled version
(`concrete_runtime:dispatch_action/4`). `init/2` never re-runs
client-side (hydration only deserializes server-sent state), so this
matters for `action/3`, not `init/2`.

## Not built

`js_import` (pulling in an actual JS module/package -- Concrete's
build pipeline has no ES-module loader or bundler to hang that off
yet; the dotted-path/global-scope approach above is the only way to
reach a library today), `eval`/`exec`, `dispatch_event`.
""".

-export([call/2, call/3, new/2, get/2, set/3, delete/2, instanceof/2, typeof/1, await/1]).

-doc """
A JS property, method, or class path: either a dotted binary (`<<"THREE.Scene">>`) or an atom, quoted if it isn't a valid bare atom (`'THREE.Scene'`) and unquoted otherwise (`add`).
""".
-type dotted_path() :: binary() | atom().

-doc """
Calls the function at `Path` in the browser's global scope with `Args`.

```erlang
concrete_js:call(<<"console.log">>, [<<"hi">>]).
```
""".
-spec call(Path :: dotted_path(), Args :: list()) -> term().
call(_Path, _Args) -> undefined.

-doc """
Calls `Method` on `Receiver` with `Args` -- the JS equivalent of
`Receiver.Method(...Args)`.

```erlang
concrete_js:call(Scene, add, [Mesh]).
```
""".
-spec call(Receiver :: term(), Method :: dotted_path(), Args :: list()) -> term().
call(_Receiver, _Method, _Args) -> undefined.

-doc """
Constructs a new instance of `ClassPath` with `Args` -- the JS
equivalent of `new ClassPath(...Args)`. Returns a native handle usable
as a `Receiver` in later calls.

```erlang
Scene = concrete_js:new('THREE.Scene', []).
```
""".
-spec new(ClassPath :: term(), Args :: list()) -> term().
new(_ClassPath, _Args) -> undefined.

-doc "Reads `Prop` off `Receiver` -- the JS equivalent of `Receiver.Prop`.".
-spec get(Receiver :: term(), Prop :: dotted_path()) -> term().
get(_Receiver, _Prop) -> undefined.

-doc "Sets `Prop` on `Receiver` to `Value` -- the JS equivalent of `Receiver.Prop = Value`. Returns `Receiver`, so calls can be chained.".
-spec set(Receiver :: term(), Prop :: dotted_path(), Value :: term()) -> term().
set(Receiver, _Prop, _Value) -> Receiver.

-doc "Deletes `Prop` from `Receiver` -- the JS equivalent of `delete Receiver.Prop`. Returns `Receiver`.".
-spec delete(Receiver :: term(), Prop :: dotted_path()) -> term().
delete(Receiver, _Prop) -> Receiver.

-doc "Tests whether `Value` is an instance of `ClassPath` -- the JS equivalent of `Value instanceof ClassPath`.".
-spec instanceof(Value :: term(), ClassPath :: term()) -> boolean().
instanceof(_Value, _ClassPath) -> false.

-doc "Returns the JS `typeof Value` result as an atom (e.g. `function`, `object`, `undefined`).".
-spec typeof(Value :: term()) -> atom().
typeof(_Value) -> undefined.

-doc """
Registers interest in a JS Promise's settlement and returns
immediately with a real Erlang reference -- it does not block on its
own. Pair it with an ordinary `receive`, from inside a process started
with `spawn/1`, to get the blocking wait:

```erlang
Pid = spawn(fun() ->
    Promise = ?js:call(<<"fetch">>, [Url]),
    Ref = concrete_js:await(Promise),
    receive
        {Ref, ok, Response}  -> ok;
        {Ref, error, Reason} -> error
    end
end).
```

This only works inside a spawned process, not from a bare `action/3`
clause or any other "cold" top-level call. `receive` already compiles
to a real blocking generator, but only a process started with
`spawn/1` can genuinely suspend across async time and be resumed later
by an out-of-band message -- a cold entry point is driven to
completion in one synchronous step and has nowhere to put a wait that
only finishes later. Calling `await/1` outside a spawned process
raises `{js_error, _}` immediately rather than sending a reply nothing
is listening for.
""".
-spec await(PromiseHandle :: term()) -> reference().
await(_PromiseHandle) -> make_ref().
