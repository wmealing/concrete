%% Interop with arbitrary JavaScript already loaded in the browser (e.g.
%% a library pulled in via a plain <script> tag, such as three.js).
%%
%% Every function here compiles like any other remote call -- Concrete's
%% encoder has no special case for this module. concrete_encoder always
%% emits Erlang["Mod:Fun/Arity"](Args) for a remote call, so
%% "concrete_js:call/2" resolves at runtime to an entry in the Erlang
%% BIF table in priv/js/demo/runtime.js, exactly the same path
%% dom:*/canvas:* already use. That also means these functions carry no
%% BEAM abstract code the call graph can trace into -- same as any
%% other BIF module, and by design.
%%
%% Receiver and ClassPath arguments accept either:
%%   - a dotted path resolved against the browser's global scope, as a
%%     binary (<<"console.log">>) or an atom -- quoted if it isn't a
%%     valid bare atom ('THREE.Scene'), unquoted otherwise (add). Atoms
%%     are the more idiomatic choice for a name that's fixed at compile
%%     time, and read better than binary syntax; or
%%   - a native handle returned by new/2, call/2, call/3, or get/2.
%% Method and Prop arguments accept the same binary-or-atom choice.
%%
%% These bodies exist only so code that calls this module still runs
%% (harmlessly) if it executes on the real BEAM -- action/3 clauses do
%% run there sometimes, when a browser dispatches an action over
%% concrete_ws_handler instead of running the compiled version
%% (concrete_runtime:dispatch_action/4). The real implementations are
%% JavaScript; init/2 never re-runs client-side (hydration only
%% deserializes server-sent state), so this matters for action/3, not
%% init/2.
%%
%% Not built: js_import (pulling in an actual JS module/package --
%% Concrete's build pipeline has no ES-module loader or bundler to hang
%% that off yet), eval/exec, dispatch_event, and promise/async interop.
-module(concrete_js).

-export([call/2, call/3, new/2, get/2, set/3, delete/2, instanceof/2, typeof/1]).

-type dotted_path() :: binary() | atom().

-spec call(Path :: dotted_path(), Args :: list()) -> term().
call(_Path, _Args) -> undefined.

-spec call(Receiver :: term(), Method :: dotted_path(), Args :: list()) -> term().
call(_Receiver, _Method, _Args) -> undefined.

-spec new(ClassPath :: term(), Args :: list()) -> term().
new(_ClassPath, _Args) -> undefined.

-spec get(Receiver :: term(), Prop :: dotted_path()) -> term().
get(_Receiver, _Prop) -> undefined.

-spec set(Receiver :: term(), Prop :: dotted_path(), Value :: term()) -> term().
set(Receiver, _Prop, _Value) -> Receiver.

-spec delete(Receiver :: term(), Prop :: dotted_path()) -> term().
delete(Receiver, _Prop) -> Receiver.

-spec instanceof(Value :: term(), ClassPath :: term()) -> boolean().
instanceof(_Value, _ClassPath) -> false.

-spec typeof(Value :: term()) -> atom().
typeof(_Value) -> undefined.
