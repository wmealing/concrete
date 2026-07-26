# Concrete Compiler Plan — Encoder Completion

Goal: close the gap between the IR the transformer produces (38 record
types) and what the encoder can emit as JavaScript (was 20). Target: every
construct needed to compile real `action/3`/`init/2` callbacks to the
browser.

Verification strategy: every milestone gets (a) fragment tests in
`encoder_SUITE` and (b) **execution round-trips** in the new
`js_exec_SUITE`, which compiles an Erlang snippet through the full
pipeline and runs it in Node.js against `priv/js/demo/runtime.js`,
asserting the printed term. The suite skips if `node` is not on PATH.

## Research findings (bitstrings)

- Upstream Hologram **does** implement bitstring construction *and*
  pattern matching in JS: `assets/js/bitstring.mjs` (1,551 lines —
  segments with type/size/unit/endianness/signedness, bit-level concat,
  chunk extraction) plus matching logic in `interpreter.mjs`. Already
  copied to `priv/js/bitstring.mjs` for the Phase 5 runtime.
  Upstream's one gap: matching `utf8/utf16/utf32` segments raises
  "not yet implemented".
- JavaScript has **no native bitstring type**. Building blocks used by
  upstream (all available): `Uint8Array`, `DataView` (endian-aware
  int/float access), `TextEncoder`/`TextDecoder`, `BigInt`.
- Decision: the demo/stub runtime implements a **byte-aligned subset**
  with `DataView` semantics (below); the full bit-level implementation
  is reused from upstream in Phase 5 rather than rewritten.

## Milestones

### M0 — Node.js execution test harness ✅
`js_exec_SUITE`: Erlang source string → transformer → encoder → JS file
(runtime.js + module + `console.log(termToString(...))`) → `node` →
assert output. This is the ground truth for all later milestones.

### M1 — Truthiness and comparison semantics ✅
Erlang comparisons are expressions returning `true`/`false` *atoms*, not
JS booleans.
- `==,/=,=:=,=/=,<,>,=<,>=` now encode to `Erlang["==/2"]` etc.,
  returning atom terms (previously `Interpreter.isEqual` → JS bool,
  wrong in body position).
- `Interpreter.isTrue(t)` accepts JS bools and atom terms; guards wrap
  every guard expression with it.
- `andalso`/`orelse` encode as lazy runtime helpers
  (`Interpreter.andalso(() => L, () => R)`) with Erlang semantics;
  `not` → `Erlang["not/1"]`.
- Guard BIF table in runtime: `is_atom/1`, `is_integer/1`, `is_float/1`,
  `is_number/1`, `is_boolean/1`, `is_list/1`, `is_tuple/1`, `is_map/1`,
  `is_binary/1`, `is_bitstring/1`, `is_function/1`, `length/1`,
  `tuple_size/1`, `map_size/1`, `byte_size/1`, `hd/1`, `tl/1`,
  `element/2`, `abs/1`. Resolved via the auto-import fallback in
  `Interpreter.call`.

### M2 — Real pattern compilation ✅
Rewrote pattern encoding from "flat equality checks" to a recursive
pattern compiler emitting ordered statements (checks interleaved with
bindings):
- Nested destructuring: tuples, fixed lists, cons (`[H|T]`), maps
  (literal keys), literals, wildcards — fixes the pre-existing bug where
  `f({rect, W, H})` compiled to a bogus structural-equality check.
- Repeated variables (`f(X, X)`) and already-bound variables match by
  equality (runtime `"X" in bindings` check in nested contexts; static
  tracking in function heads).
- **Scope inheritance**: clause sets nested in a body (case, anon funs,
  try) now start from `Object.assign({}, parentBindings)` — fixes the
  pre-existing bug where a case clause body could not see enclosing
  variables.

### M3 — `match` (`=`) and `if` ✅
- `Pattern = Expr` in a body: IIFE that evaluates once, destructures
  into the enclosing bindings, throws `{badmatch, Value}` on failure,
  returns the value.
- `if`: guard-seq chain; no clause true → `error(if_clause)`.

### M4 — Anonymous functions ✅
- `fun(X) -> ... end` → `Type.anonFun(Arity, closure)` capturing the
  defining clause's bindings; multi-clause funs dispatch through
  `Interpreter.callClauses`.
- Calling: `F(Args)` → `Interpreter.callAnon` (arity-checked).
- `fun f/1` and `fun m:f/1` → wrappers over `Interpreter.call`.

### M5 — Map update ✅
`M#{k := v, k2 => v2}` → `Interpreter.mapUpdate(M, [[k,v],...])`.
v1 limitation: `:=` and `=>` both upsert (the transformer collapses the
assoc/exact distinction; strict `:=` key-exists checking would need
`ir_map_update` to keep it).

### M6 — List comprehensions ✅
`[T || P <- L, F]` → nested loops with per-level bindings shadowing;
non-matching generator elements are skipped (not errors), filters use
`isTrue`. Multiple generators and filters compose.
Binary comprehensions (`ir_bc`) raise a clear encoder error — deferred
until the Phase 5 bitstring runtime lands.

### M7 — `try`/`catch`/`throw` ✅
- Runtime `ErlangError` carrying `{Class, Reason}`; BIFs `throw/1`,
  `error/1`, `error/2`, `exit/1`.
- `try ... of ... catch Class:Pattern -> ... after ... end` →
  `Interpreter.tryCatch(bodyFn, ofClauses, catchClauses, afterFn)`;
  catch clauses pattern-match `[Class, Reason]`, unmatched exceptions
  rethrow, `after` maps to `finally`. Stack-trace variables are not
  bound (v1).
- Native JS exceptions surface as `error:{js_error, Message}`.

### M8 — `receive` → compile-time error ✅
`receive` cannot exist in browser-compiled code. The encoder raises
`{receive_not_supported_in_client_code, ...}` with a message pointing at
server-side handling — per the design note in CLAUDE.md ("the encoder
should emit a compile-time warning if receive appears in an action
callback"; we fail hard, which is stricter and safer).

### M9 — Bitstrings (byte-aligned subset) ✅
Transformer now handles the general `{bin, ...}` AST (literal-only
binaries still take the `ir_string` fast path). Encoder emits segment
descriptors; runtime implements:
- **Construction** `Interpreter.buildBitstring(segs)`: integer segments
  (8/16/32 bits, big/little), float (32/64), binary (whole or sized),
  string literals as text bytes. Backed by `DataView`.
- **Matching** `Interpreter.matchBitstringSegments(subject, descs)`:
  sequential extraction with the same types, `Rest/binary` tail
  segments, literal segment comparison, exact-length enforcement.
- Representation in the stub runtime: byte string (`charCode ≤ 255`),
  keeping the existing `{type:"bitstring", value}` wire shape.

v1 limitations (all supported by upstream `bitstring.mjs`, to be lifted
in Phase 5): no non-byte-aligned sizes, no dynamic sizes
(`<<D:Len/binary>>` where `Len` is a variable), no integer segments
> 32 bits, no `utf16/utf32`, signedness on extraction only.

## Deliberately out of scope
- `ir_pid` encoding (no meaningful browser semantics yet)
- Binary comprehensions (M6 note)
- `receive` (M8 — hard error by design)
- Stacktrace binding in catch clauses
