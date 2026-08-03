// Minimal Concrete runtime stub for browser demos.
// Implements just enough of Type, Erlang, and Interpreter to run
// compiled Erlang modules without the full bundled runtime.

const Type = {
  atom:      (value)    => ({ type: "atom",      value }),
  integer:   (value)    => ({ type: "integer",   value }),
  float:     (value)    => ({ type: "float",     value }),
  bitstring: (value)    => ({ type: "bitstring", value }),
  tuple:     (data)     => ({ type: "tuple",     data }),
  list:      (data)     => ({ type: "list",      data, tail: null }),
  map:       (pairs)    => ({ type: "map",        data: pairs }),
  pid:       (value)    => ({ type: "pid",        value }),
  ref:       (value)    => ({ type: "ref",        value }),
  anonFun:   (arity, callable) => ({ type: "anon_fun", arity, callable }),
};

// Erlang exceptions: class is "throw" | "error" | "exit", reason a term.
class ErlangError extends Error {
  constructor(cls, reason) {
    super(`${cls}: ${termToString(reason)}`);
    this.erlangClass = cls;
    this.reason = reason;
  }
}

// Structural equality — same as the wire format comparison.
function termEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (typeof a !== "object" || a === null) return a === b;
  if (a.type !== b.type) return false;
  switch (a.type) {
    case "atom":
    case "integer":
    case "float":
    case "bitstring":
    case "pid":
    case "ref":
      return a.value === b.value;
    case "tuple":
      return a.data.length === b.data.length &&
             a.data.every((v, i) => termEqual(v, b.data[i]));
    case "list":
      return a.data.length === b.data.length &&
             a.data.every((v, i) => termEqual(v, b.data[i])) &&
             termEqual(a.tail, b.tail);
    case "map":
      return a.data.length === b.data.length &&
             a.data.every(([k, v], i) =>
               termEqual(k, b.data[i][0]) && termEqual(v, b.data[i][1]));
    default:
      return false;
  }
}

// Pretty-print an Erlang term back to Erlang-style notation.
function termToString(t) {
  if (t === null) return "null";
  switch (t.type) {
    case "atom":      return t.value;
    case "integer":   return String(t.value);
    case "float":     return String(t.value);
    case "bitstring": return `<<"${t.value}">>`;
    case "pid":       return `<${t.value}>`;
    case "ref":       return `#Ref<${t.value}>`;
    case "tuple":
      return `{${t.data.map(termToString).join(", ")}}`;
    case "list":
      return `[${t.data.map(termToString).join(", ")}]`;
    case "map":
      const pairs = t.data.map(([k, v]) => `${termToString(k)} => ${termToString(v)}`);
      return `\#{${pairs.join(", ")}}`;
    default:
      return JSON.stringify(t);
  }
}

// Decode the type-tagged wire format (see concrete_serializer.erl) back
// into a boxed term. Used by sse:connect/3 to turn a server-pushed JSON
// event straight into something compiled Erlang can pattern-match on,
// without pulling in client.js (whose Client.deserialize does the same
// thing for page hydration).
function base64ToLatin1(b64) {
  if (typeof atob !== "undefined") return atob(b64);
  return Buffer.from(b64, "base64").toString("latin1");
}
function wireToTerm(node) {
  switch (node.type) {
    case "atom":      return Type.atom(node.value);
    case "integer":   return Type.integer(node.value);
    case "float":     return Type.float(node.value);
    case "bitstring": return Type.bitstring(base64ToLatin1(node.value));
    case "tuple":     return Type.tuple(node.data.map(wireToTerm));
    case "list":      return Type.list(node.data.map(wireToTerm));
    case "map":
      return Type.map(node.data.map(([k, v]) => [wireToTerm(k), wireToTerm(v)]));
    default:
      throw new Error(`cannot deserialize wire type: ${node.type}`);
  }
}

// The inverse direction, one level deep: a boxed term -> a plain JS
// value suitable for JSON.stringify. Used by http:post_json/2, whose
// params are a flat map of scalars (atom/integer/float/bitstring) --
// deep structures fall back to Erlang-style text via termToString.
function termToPlainJs(t) {
  switch (t.type) {
    case "atom":      return t.value;
    case "integer":
    case "float":     return t.value;
    case "bitstring": return t.value;
    default:          return termToString(t);
  }
}

// Registry of all compiled modules: modules["hello"]["greet/1"] = fn
const modules = {};

// Process table for spawn/self/!/receive: pid -> {mailbox, gen, done, result}.
// See distributed-wiggling-flame plan for the generator-based process
// model. Everything here runs cooperatively on the one JS thread: `!`
// (send) synchronously steps its target right away, so a gen_server
// -style call's reply is normally already sitting in the caller's
// mailbox by the time it reaches its own receive.
const processes = {};
let nextPidId = 1;
let nextRefId = 1;
// Pids currently mid-step somewhere on the active JS call stack. A send
// that would resume one of these (e.g. A sends to B, B replies to A
// while A itself is still mid-flight further up the stack) must not
// call .next() on it again -- JS throws on a reentrant generator step,
// and it's unnecessary anyway: the still-running process will see the
// newly queued message the moment it reaches its own next receive
// check, later in this same call stack.
const activeSteps = new Set();
let uiPid = null;
const uiStore = new Map();

// 2D contexts for <canvas> elements, cached by element id.
const canvasContexts = {};
function canvasCtx(id) {
  if (!canvasContexts[id]) {
    canvasContexts[id] = document.getElementById(id).getContext("2d");
  }
  return canvasContexts[id];
}

// bitstring value <-> byte helpers (latin1 semantics: charCode == byte)
function bitsToBytes(str) {
  const bytes = new Uint8Array(str.length);
  for (let i = 0; i < str.length; i++) bytes[i] = str.charCodeAt(i) & 0xff;
  return bytes;
}
function bytesToBits(bytes) {
  return String.fromCharCode(...bytes);
}

const Interpreter = {
  isEqual:        (a, b) => termEqual(a, b),
  isStrictlyEqual:(a, b) => termEqual(a, b),

  // The pid currently "running" -- valid only while stepping a
  // process's generator (see stepProcess/callTopLevel). self/0 reads
  // this; it's saved/restored around every step since sends recurse
  // (a clause body's `!` synchronously steps its target inline).
  currentPid: null,

  newPid() { return nextPidId++; },
  newRef()  { return nextRefId++; },

  // spawn/1: run the fun until it first blocks or finishes, return its
  // pid either way (matches real Erlang: spawn returns immediately;
  // the spawned computation keeps running/blocking independently).
  spawnProcess(fun) {
    const pid = Interpreter.newPid();
    processes[pid] = { mailbox: [], gen: null, done: false, result: null };
    const prev = Interpreter.currentPid;
    Interpreter.currentPid = pid;
    let result;
    try {
      result = fun.callable([]);
    } finally {
      Interpreter.currentPid = prev;
    }
    if (result && typeof result.next === "function") {
      processes[pid].gen = result;
      Interpreter.stepProcess(pid);
    } else {
      // a non-blocking spawned fun just runs to completion immediately
      processes[pid].done = true;
      processes[pid].result = result;
    }
    return Type.pid(pid);
  },

  // Advance a process's generator by exactly one step (i.e. until it
  // next blocks on an unmatched receive, or finishes).
  stepProcess(pid) {
    const proc = processes[pid];
    if (!proc || proc.done || !proc.gen || activeSteps.has(pid)) return;
    activeSteps.add(pid);
    const prev = Interpreter.currentPid;
    Interpreter.currentPid = pid;
    let r;
    try {
      r = proc.gen.next();
    } finally {
      Interpreter.currentPid = prev;
      activeSteps.delete(pid);
    }
    if (r.done) {
      proc.done = true;
      proc.result = r.value;
    }
  },

  // `!` (send): queue the message and immediately try to make progress
  // on the target. Sending to an unknown/dead pid is a silent no-op,
  // matching real Erlang.
  send(pid, msg) {
    const proc = processes[pid];
    if (!proc || proc.done) return;
    proc.mailbox.push(msg);
    Interpreter.stepProcess(pid);
  },

  // Scan a process's mailbox in arrival order; the first message
  // matching *any* clause wins (real Erlang receive semantics -- not
  // "first clause across the whole mailbox"). clauses is
  // [[patFn, guardFn], ...]; patFn/guardFn are the exact codegen used
  // for case/function clauses (receive has one pattern per clause, so
  // patFn is invoked the same way: patFn([message])).
  receiveMatch(pid, clauses) {
    const proc = processes[pid];
    if (!proc) return null;
    const mailbox = proc.mailbox;
    for (let i = 0; i < mailbox.length; i++) {
      for (let c = 0; c < clauses.length; c++) {
        const [patFn, guardFn] = clauses[c];
        const bindings = patFn([mailbox[i]]);
        if (bindings !== null && guardFn(bindings)) {
          mailbox.splice(i, 1);
          return { clauseIndex: c, bindings };
        }
      }
    }
    return null;
  },

  // The only cold entry point: called from real async browser/JS
  // events (dom:on_click, dom:on_keydown, dom:set_timeout, boot
  // scripts) that have no ambient process context. If the target turns
  // out to be blocking, wraps it in an ephemeral process and drives it
  // once; a compiled call site that already knows its target is
  // blocking uses `yield* Interpreter.call(...)` instead and must
  // never come through here.
  callTopLevel(moduleName, funcName, arity, args) {
    const result = Interpreter.call(moduleName, funcName, arity, args);
    if (result && typeof result.next === "function") {
      return Interpreter.runEphemeral(result);
    }
    return result;
  },

  // Shared by callTopLevel and the auto-registered cross-module BIF
  // wrapper (defineErlangFunction): wrap an already-created generator
  // -- from calling into a blocking compiled function outside of any
  // process context -- in a fresh, throwaway process and drive it to
  // completion. Correct because self()/receive inside it only ever
  // need *some* pid to exist for the duration of this call (e.g.
  // gen_server-style call/2 embeds self() as the reply address).
  runEphemeral(gen) {
    const pid = Interpreter.newPid();
    processes[pid] = { mailbox: [], gen, done: false, result: null };
    Interpreter.stepProcess(pid);
    const proc = processes[pid];
    if (!proc.done) {
      throw new Error(
        "process blocked waiting for a message that never arrived " +
        "(unsupported outside a running process in v1)");
    }
    return proc.result;
  },

  // Module:Function(Args) dynamic dispatch -- module/function are
  // runtime atom terms, not literals the encoder could resolve
  // statically (see ir_dynamic_call). Always treated as non-blocking.
  callDynamic(modTerm, funTerm, arity, args) {
    return Interpreter.call(modTerm.value, funTerm.value, arity, args);
  },

  // Guards and conditions: accepts JS booleans and 'true'/'false' atoms.
  isTrue(x) {
    if (x === true || x === false) return x;
    if (x && x.type === "atom") return x.value === "true";
    return Boolean(x);
  },

  raise(cls, reason) {
    throw new ErlangError(cls, reason);
  },

  matchError(value) {
    return new ErlangError("error",
      Type.tuple([Type.atom("badmatch"), value]));
  },

  // Try each [patternFn, guardFn, bodyFn] clause in order.
  callClauses(args, clauses) {
    for (const [patFn, guardFn, bodyFn] of clauses) {
      const bindings = patFn(args);
      if (bindings !== null && guardFn(bindings)) {
        return bodyFn(bindings);
      }
    }
    Interpreter.raise("error", Type.atom("function_clause"));
  },

  // Called by generated module bundles to register compiled functions.
  // Also registers under the module-prefixed key in the Erlang BIF
  // table, so a *different* compiled module can reach this one through
  // an ordinary ir_remote_call (`Erlang["mod:fn/N"]`) exactly like a
  // hand-written BIF -- each module is compiled independently, with no
  // visibility into any other module, so there's no separate "user
  // module call" code path in the encoder. If the call turns out to be
  // blocking, auto-resolve it as an ephemeral process (mirrors
  // Interpreter.callTopLevel): the calling module's own blocking
  // classification has no way to know some *other* module's function
  // blocks, so it can't have emitted a `yield*` for it.
  defineErlangFunction(moduleName, funcName, arity, clauses) {
    if (!modules[moduleName]) modules[moduleName] = {};
    const key = `${funcName}/${arity}`;
    const impl = (args) => Interpreter.callClauses(args, clauses);
    modules[moduleName][key] = impl;
    Erlang[`${moduleName}:${key}`] = (...args) => {
      const result = impl(args);
      if (result && typeof result.next === "function") {
        return Interpreter.runEphemeral(result);
      }
      return result;
    };
  },

  // Local call: Interpreter.call(currentModule, "funcName", arity, args)
  // Falls back to the Erlang BIF table for auto-imported BIFs
  // (integer_to_binary/1 etc.), mirroring Erlang's call resolution.
  call(moduleName, funcName, arity, args) {
    const key = `${funcName}/${arity}`;
    const mod = modules[moduleName];
    if (mod && mod[key]) return mod[key](args);
    if (Erlang[key]) return Erlang[key](...args);
    throw new Error(`Unknown function: ${moduleName}:${funcName}/${arity}`);
  },

  // Anonymous function call, arity-checked.
  callAnon(fn, args) {
    if (!fn || fn.type !== "anon_fun") {
      Interpreter.raise("error", Type.tuple([Type.atom("badfun"), fn]));
    }
    if (fn.arity !== args.length) {
      Interpreter.raise("error", Type.tuple([Type.atom("badarity"), fn]));
    }
    return fn.callable(args);
  },

  // Case expression: Interpreter.matchClauses(term, [[patFn, guardFn, bodyFn], ...])
  matchClauses(term, clauses) {
    for (const [patFn, guardFn, bodyFn] of clauses) {
      const bindings = patFn([term]);
      if (bindings !== null && guardFn(bindings)) {
        return bodyFn(bindings);
      }
    }
    Interpreter.raise("error", Type.tuple([Type.atom("case_clause"), term]));
  },

  // andalso/orelse with Erlang semantics (lazy right side).
  andalso(l, r) {
    const lv = l();
    if (lv.type === "atom" && lv.value === "false") return lv;
    if (lv.type === "atom" && lv.value === "true") return r();
    Interpreter.raise("error", Type.tuple([Type.atom("badarg"), lv]));
  },
  orelse(l, r) {
    const lv = l();
    if (lv.type === "atom" && lv.value === "true") return lv;
    if (lv.type === "atom" && lv.value === "false") return r();
    Interpreter.raise("error", Type.tuple([Type.atom("badarg"), lv]));
  },

  // Map pattern support: value for key, or undefined if absent.
  mapLookup(map, key) {
    if (!map || map.type !== "map") return undefined;
    const pair = map.data.find(([k]) => termEqual(k, key));
    return pair ? pair[1] : undefined;
  },

  // M#{k := v} / M#{k => v} — upsert pairs into a copy.
  mapUpdate(map, pairs) {
    const data = map.data.map((p) => [p[0], p[1]]);
    for (const [k, v] of pairs) {
      const idx = data.findIndex(([dk]) => termEqual(dk, k));
      if (idx === -1) data.push([k, v]);
      else data[idx] = [k, v];
    }
    return Type.map(data);
  },

  // try/of/catch/after. ofClauses/catchClauses are clause triples or
  // null; catch clauses match [ClassAtom, Reason]. afterFn maps to
  // finally. Unmatched exceptions rethrow.
  tryCatch(bodyFn, ofClauses, catchClauses, afterFn) {
    try {
      const value = bodyFn();
      return ofClauses ? Interpreter.matchClauses(value, ofClauses) : value;
    } catch (e) {
      const ex = e instanceof ErlangError
        ? e
        : new ErlangError("error",
            Type.tuple([Type.atom("js_error"),
                        Type.bitstring(String(e && e.message))]));
      if (catchClauses) {
        const args = [Type.atom(ex.erlangClass), ex.reason];
        for (const [patFn, guardFn, bodyFn2] of catchClauses) {
          const bindings = patFn(args);
          if (bindings !== null && guardFn(bindings)) {
            return bodyFn2(bindings);
          }
        }
      }
      throw e;
    } finally {
      if (afterFn) afterFn();
    }
  },

  // Generator counterpart of tryCatch, used when the encoder has
  // determined body/of/catch/after must uniformly compile as
  // generators (see concrete_encoder's try/catch blocking analysis).
  // bodyFn/afterFn are zero-arg closures returning a Generator;
  // ofClauses/catchClauses entries have generator-returning bodyFns.
  *tryCatchGen(bodyFn, ofClauses, catchClauses, afterFn) {
    try {
      const value = yield* bodyFn();
      return ofClauses ? yield* Interpreter.matchClauses(value, ofClauses) : value;
    } catch (e) {
      const ex = e instanceof ErlangError
        ? e
        : new ErlangError("error",
            Type.tuple([Type.atom("js_error"),
                        Type.bitstring(String(e && e.message))]));
      if (catchClauses) {
        const args = [Type.atom(ex.erlangClass), ex.reason];
        for (const [patFn, guardFn, bodyFn2] of catchClauses) {
          const bindings = patFn(args);
          if (bindings !== null && guardFn(bindings)) {
            return yield* bodyFn2(bindings);
          }
        }
      }
      throw e;
    } finally {
      if (afterFn) yield* afterFn();
    }
  },

  // Bitstring construction from segment descriptors:
  //   {v: term, t: "integer"|"float"|"binary", size: bits|null, little: bool}
  // Byte-aligned subset; see compiler-plan.md M9.
  buildBitstring(segs) {
    const chunks = [];
    for (const seg of segs) {
      if (seg.t === "integer") {
        const bits = seg.size === null ? 8 : seg.size;
        if (bits % 8 !== 0 || bits > 32) {
          throw new Error(`unsupported integer segment size: ${bits}`);
        }
        const n = bits / 8;
        const buf = new Uint8Array(n);
        let v = seg.v.value;
        for (let i = 0; i < n; i++) {
          const shift = seg.little ? i : n - 1 - i;
          buf[i] = (v >>> (shift * 8)) & 0xff;
        }
        chunks.push(buf);
      } else if (seg.t === "float") {
        const bits = seg.size === null ? 64 : seg.size;
        if (bits !== 64 && bits !== 32) {
          throw new Error(`unsupported float segment size: ${bits}`);
        }
        const buf = new ArrayBuffer(bits / 8);
        const view = new DataView(buf);
        if (bits === 64) view.setFloat64(0, seg.v.value, seg.little);
        else view.setFloat32(0, seg.v.value, seg.little);
        chunks.push(new Uint8Array(buf));
      } else if (seg.t === "binary" || seg.t === "utf8") {
        const bytes = bitsToBytes(seg.v.value);
        if (seg.size === null) {
          chunks.push(bytes);
        } else {
          const n = seg.size / 8;
          if (bytes.length < n) {
            throw new Error("binary segment shorter than declared size");
          }
          chunks.push(bytes.subarray(0, n));
        }
      } else {
        throw new Error(`unsupported segment type: ${seg.t}`);
      }
    }
    const total = chunks.reduce((n, c) => n + c.length, 0);
    const out = new Uint8Array(total);
    let off = 0;
    for (const c of chunks) { out.set(c, off); off += c.length; }
    return Type.bitstring(bytesToBits(out));
  },

  // Bitstring pattern matching. descs:
  //   {t, size: bits|null, little, lit: term|null}
  // Returns an array with one extracted term per segment (literal
  // segments included), or null if the subject does not match.
  matchBitstringSegments(subject, descs) {
    if (!subject || subject.type !== "bitstring") return null;
    const bytes = bitsToBytes(subject.value);
    const out = [];
    let off = 0;
    for (let i = 0; i < descs.length; i++) {
      const d = descs[i];
      let value;
      if (d.t === "integer") {
        const bits = d.size === null ? 8 : d.size;
        if (bits % 8 !== 0 || bits > 32) return null;
        const n = bits / 8;
        if (off + n > bytes.length) return null;
        let v = 0;
        for (let j = 0; j < n; j++) {
          const shift = d.little ? j : n - 1 - j;
          v += bytes[off + j] * 2 ** (shift * 8);
        }
        value = Type.integer(v);
        off += n;
      } else if (d.t === "float") {
        const bits = d.size === null ? 64 : d.size;
        if (bits !== 64 && bits !== 32) return null;
        const n = bits / 8;
        if (off + n > bytes.length) return null;
        const view = new DataView(bytes.buffer, bytes.byteOffset + off, n);
        value = Type.float(bits === 64 ? view.getFloat64(0, d.little)
                                       : view.getFloat32(0, d.little));
        off += n;
      } else if (d.t === "binary" || d.t === "utf8") {
        let n;
        if (d.size === null) {
          if (i !== descs.length - 1) return null; // rest must be last
          n = bytes.length - off;
        } else {
          n = d.size / 8;
        }
        if (off + n > bytes.length) return null;
        value = Type.bitstring(bytesToBits(bytes.subarray(off, off + n)));
        off += n;
      } else {
        return null;
      }
      if (d.lit !== null && !termEqual(value, d.lit)) return null;
      out.push(value);
    }
    if (off !== bytes.length) return null; // exact match required
    return out;
  },
};

// 'true' / 'false' atom from a JS boolean.
function boolAtom(b) {
  return Type.atom(b ? "true" : "false");
}

// Term ordering for </2 etc. — numbers only in the stub runtime.
function termLess(a, b) {
  return a.value < b.value;
}

// Arithmetic result type: float if either operand is a float.
function numType(a, b) {
  return a.type === "float" || b.type === "float" ? Type.float : Type.integer;
}

// Erlang BIF table — keyed by "module:name/arity" or just "name/arity" for erlang module.
const Erlang = {
  // Comparisons are expressions in Erlang: they return atom terms.
  "==/2":  (a, b) => boolAtom(termEqual(a, b)),
  "/=/2":  (a, b) => boolAtom(!termEqual(a, b)),
  "=:=/2": (a, b) => boolAtom(termEqual(a, b)),
  "=/=/2": (a, b) => boolAtom(!termEqual(a, b)),
  "</2":   (a, b) => boolAtom(termLess(a, b)),
  ">/2":   (a, b) => boolAtom(termLess(b, a)),
  "=</2":  (a, b) => boolAtom(!termLess(b, a)),
  ">=/2":  (a, b) => boolAtom(!termLess(a, b)),
  "not/1": (a)    => boolAtom(!Interpreter.isTrue(a)),

  // Guard BIFs.
  "is_atom/1":      (t) => boolAtom(t.type === "atom"),
  "is_boolean/1":   (t) => boolAtom(t.type === "atom" && (t.value === "true" || t.value === "false")),
  "is_integer/1":   (t) => boolAtom(t.type === "integer"),
  "is_float/1":     (t) => boolAtom(t.type === "float"),
  "is_number/1":    (t) => boolAtom(t.type === "integer" || t.type === "float"),
  "is_list/1":      (t) => boolAtom(t.type === "list"),
  "is_tuple/1":     (t) => boolAtom(t.type === "tuple"),
  "is_map/1":       (t) => boolAtom(t.type === "map"),
  "is_binary/1":    (t) => boolAtom(t.type === "bitstring"),
  "is_bitstring/1": (t) => boolAtom(t.type === "bitstring"),
  "is_function/1":  (t) => boolAtom(t.type === "anon_fun"),
  "length/1":       (l) => Type.integer(l.data.length),
  "tuple_size/1":   (t) => Type.integer(t.data.length),
  "map_size/1":     (m) => Type.integer(m.data.length),
  "byte_size/1":    (b) => Type.integer(b.value.length),
  "hd/1":           (l) => l.data[0],
  "tl/1":           (l) => Type.list(l.data.slice(1)),
  "element/2":      (n, t) => t.data[n.value - 1],
  "abs/1":          (n) => (n.type === "float" ? Type.float : Type.integer)(Math.abs(n.value)),
  "trunc/1":        (n) => Type.integer(Math.trunc(n.value)),
  "round/1":        (n) => Type.integer(Math.round(n.value)),
  "float/1":        (n) => Type.float(n.value),

  // Processes: spawn/self/make_ref/send. See Interpreter.spawnProcess
  // et al. `!` is parsed as a plain binop (concrete_transformer) and
  // falls through the encoder's generic binop case to this key.
  "self/0":     () => Type.pid(Interpreter.currentPid),
  "spawn/1":    (fun) => Interpreter.spawnProcess(fun),
  "make_ref/0": () => Type.ref(Interpreter.newRef()),
  "!/2":        (pidTerm, msg) => { Interpreter.send(pidTerm.value, msg); return msg; },

  // Exceptions.
  "throw/1": (t)     => Interpreter.raise("throw", t),
  "error/1": (t)     => Interpreter.raise("error", t),
  "error/2": (t, _a) => Interpreter.raise("error", t),
  "exit/1":  (t)     => Interpreter.raise("exit", t),

  "+/2":   (a, b) => numType(a, b)(a.value + b.value),
  "-/2":   (a, b) => numType(a, b)(a.value - b.value),
  "*/2":   (a, b) => numType(a, b)(a.value * b.value),
  "//2":   (a, b) => Type.float(a.value / b.value),
  "div/2": (a, b) => Type.integer(Math.trunc(a.value / b.value)),
  "rem/2": (a, b) => Type.integer(a.value % b.value),
  "-/1":   (a)    => Type.integer(-a.value),
  "++/2":  (a, b) => Type.list([...a.data, ...b.data]),
  "--/2":  (a, b) => {
    let data = [...a.data];
    for (const item of b.data) {
      const idx = data.findIndex(x => termEqual(x, item));
      if (idx !== -1) data.splice(idx, 1);
    }
    return Type.list(data);
  },
  "band/2":  (a, b) => Type.integer(a.value & b.value),
  "bor/2":   (a, b) => Type.integer(a.value | b.value),
  "bxor/2":  (a, b) => Type.integer(a.value ^ b.value),
  "bsl/2":   (a, b) => Type.integer(a.value << b.value),
  "bsr/2":   (a, b) => Type.integer(a.value >> b.value),
  "integer_to_binary/1": (n) => Type.bitstring(String(n.value)),
  "erlang:integer_to_binary/1": (n) => Type.bitstring(String(n.value)),
  "binary_to_integer/1": (b) => Type.integer(parseInt(b.value, 10)),
  "atom_to_binary/1": (a) => Type.bitstring(a.value),
  "binary_to_atom/1": (b) => Type.atom(b.value),
  "min/2": (a, b) => (termLess(a, b) ? a : b),
  "max/2": (a, b) => (termLess(a, b) ? b : a),

  // --- lists (higher-order fns dispatch into compiled anon funs) ---
  "lists:reverse/1": (list) => Type.list([...list.data].reverse()),
  "lists:map/2": (f, l) =>
    Type.list(l.data.map((x) => Interpreter.callAnon(f, [x]))),
  "lists:filter/2": (f, l) =>
    Type.list(l.data.filter((x) => Interpreter.isTrue(Interpreter.callAnon(f, [x])))),
  "lists:foldl/3": (f, acc0, l) =>
    l.data.reduce((acc, x) => Interpreter.callAnon(f, [x, acc]), acc0),
  "lists:foreach/2": (f, l) => {
    for (const x of l.data) Interpreter.callAnon(f, [x]);
    return Type.atom("ok");
  },
  "lists:seq/2": (from, to) => {
    const out = [];
    for (let i = from.value; i <= to.value; i++) out.push(Type.integer(i));
    return Type.list(out);
  },
  "lists:member/2": (x, l) => boolAtom(l.data.some((e) => termEqual(e, x))),
  // Generator counterparts, used only when the encoder statically sees
  // a blocking literal fun passed to one of these five (see
  // concrete_encoder:higher_order_bif/2). The plain versions above are
  // untouched and stay the default for the (overwhelmingly common)
  // non-blocking case.
  *genListsMap(f, l) {
    const out = [];
    for (const x of l.data) out.push(yield* Interpreter.callAnon(f, [x]));
    return Type.list(out);
  },
  *genListsFilter(f, l) {
    const out = [];
    for (const x of l.data) {
      if (Interpreter.isTrue(yield* Interpreter.callAnon(f, [x]))) out.push(x);
    }
    return Type.list(out);
  },
  *genListsFoldl(f, acc0, l) {
    let acc = acc0;
    for (const x of l.data) acc = yield* Interpreter.callAnon(f, [x, acc]);
    return acc;
  },
  *genListsForeach(f, l) {
    for (const x of l.data) yield* Interpreter.callAnon(f, [x]);
    return Type.atom("ok");
  },
  *genMapsFold(f, acc0, m) {
    let acc = acc0;
    for (const [k, v] of m.data) acc = yield* Interpreter.callAnon(f, [k, v, acc]);
    return acc;
  },
  "lists:sum/1": (l) =>
    l.data.reduce((acc, x) => Erlang["+/2"](acc, x), Type.integer(0)),
  "lists:nth/2": (n, l) => l.data[n.value - 1],
  "lists:sort/1": (l) =>
    Type.list([...l.data].sort((a, b) => (termLess(a, b) ? -1 : termLess(b, a) ? 1 : 0))),

  // --- maps ---
  "maps:put/3": (k, v, m) => Interpreter.mapUpdate(m, [[k, v]]),
  "maps:remove/2": (k, m) =>
    Type.map(m.data.filter(([dk]) => !termEqual(dk, k))),
  "maps:keys/1": (m) => Type.list(m.data.map(([k]) => k)),
  "maps:values/1": (m) => Type.list(m.data.map(([, v]) => v)),
  "maps:merge/2": (m1, m2) => Interpreter.mapUpdate(m1, m2.data),
  "maps:is_key/2": (k, m) =>
    boolAtom(Interpreter.mapLookup(m, k) !== undefined),
  "maps:size/1": (m) => Type.integer(m.data.length),
  "maps:fold/3": (f, acc0, m) =>
    m.data.reduce((acc, [k, v]) => Interpreter.callAnon(f, [k, v, acc]), acc0),
  "maps:to_list/1": (m) =>
    Type.list(m.data.map(([k, v]) => Type.tuple([k, v]))),
  "maps:from_list/1": (l) =>
    Interpreter.mapUpdate(Type.map([]), l.data.map((t) => [t.data[0], t.data[1]])),

  // --- dom module: the DOM exposed to compiled Erlang as BIFs ---
  // dom:append_html(ElementId, Html) — append an HTML fragment to an element.
  "dom:append_html/2": (id, html) => {
    document.getElementById(id.value).insertAdjacentHTML("beforeend", html.value);
    return Type.atom("ok");
  },
  // dom:set_text(ElementId, Text) — replace an element's text content.
  "dom:set_text/2": (id, text) => {
    document.getElementById(id.value).textContent = text.value;
    return Type.atom("ok");
  },
  // dom:set_timeout(Ms, Module, Function, Args) — schedule an Erlang call.
  "dom:set_timeout/4": (ms, mod, fn, args) => {
    setTimeout(
      () => Interpreter.callTopLevel(mod.value, fn.value, args.data.length, args.data),
      ms.value
    );
    return Type.atom("ok");
  },
  // dom:set_html(ElementId, Html) — replace an element's innerHTML.
  "dom:set_html/2": (id, html) => {
    document.getElementById(id.value).innerHTML = html.value;
    return Type.atom("ok");
  },
  // dom:scroll_to_bottom(ElementId) — scroll a scrollable container (e.g.
  // a log panel) to its bottom, so the most recent content stays visible.
  "dom:scroll_to_bottom/1": (id) => {
    const el = document.getElementById(id.value);
    el.scrollTop = el.scrollHeight;
    return Type.atom("ok");
  },
  // dom:get_value(ElementId) — read an <input>/<textarea> element's value.
  "dom:get_value/1": (id) =>
    Type.bitstring(document.getElementById(id.value).value),
  // dom:set_value(ElementId, Value) — set an <input>/<textarea> element's value.
  "dom:set_value/2": (id, value) => {
    document.getElementById(id.value).value = value.value;
    return Type.atom("ok");
  },
  // dom:on_click(ContainerId, AttrName, Module, Function) — delegated click
  // listener: clicks on any descendant with [AttrName] call
  // Module:Function/1 with that attribute's value (as a bitstring).
  "dom:on_click/4": (containerId, attrName, mod, fn) => {
    document.getElementById(containerId.value).addEventListener("click", (e) => {
      const el = e.target.closest(`[${attrName.value}]`);
      if (el) {
        e.preventDefault();
        Interpreter.callTopLevel(mod.value, fn.value, 1,
          [Type.bitstring(el.getAttribute(attrName.value))]);
      }
    });
    return Type.atom("ok");
  },
  // dom:on_keydown(ElementId, KeyName, Module, Function) — call
  // Module:Function/0 when KeyName (e.g. "Enter") is pressed while
  // ElementId has focus.
  "dom:on_keydown/4": (id, keyName, mod, fn) => {
    document.getElementById(id.value).addEventListener("keydown", (e) => {
      if (e.key === keyName.value) {
        e.preventDefault();
        Interpreter.callTopLevel(mod.value, fn.value, 0, []);
      }
    });
    return Type.atom("ok");
  },
  // dom:on_keydown_global(KeyName, Module, Function) — same as
  // dom:on_keydown/4, but listens on the whole document instead of one
  // element, so it fires no matter what has focus (or whether anything
  // does) -- the usual shape for game/global keyboard shortcuts, where
  // relying on a specific element's focus (e.g. a <canvas>, which
  // browsers don't focus reliably even with tabindex/autofocus) isn't
  // good enough.
  "dom:on_keydown_global/3": (keyName, mod, fn) => {
    document.addEventListener("keydown", (e) => {
      if (e.key === keyName.value) {
        e.preventDefault();
        Interpreter.callTopLevel(mod.value, fn.value, 0, []);
      }
    });
    return Type.atom("ok");
  },
  // dom:local_storage_get(Key) — read a localStorage key, or the atom
  // 'undefined' if it isn't set.
  "dom:local_storage_get/1": (key) => {
    const v = window.localStorage.getItem(key.value);
    return v === null ? Type.atom("undefined") : Type.bitstring(v);
  },
  // dom:local_storage_set(Key, Value) — write a localStorage key.
  "dom:local_storage_set/2": (key, value) => {
    window.localStorage.setItem(key.value, value.value);
    return Type.atom("ok");
  },
  // dom:local_storage_remove(Key) — delete a localStorage key.
  "dom:local_storage_remove/1": (key) => {
    window.localStorage.removeItem(key.value);
    return Type.atom("ok");
  },
  // --- network: SSE subscriptions and one-shot HTTP calls ---
  // sse:connect(Path, Module, Function) — open a server-sent-events
  // stream and call Module:Function/1 with each event's payload,
  // decoded from the type-tagged wire format straight into a term (see
  // wireToTerm). Each call is its own cold top-level entry point, same
  // as a dom:on_click handler.
  //
  // EventSource retries on its own for a transient drop, but gives up
  // for good (readyState settles at CLOSED) after some failures --
  // network sleep/wake, a proxy hiccup, whatever. Path is expected to
  // carry a stable per-session credential (see snake_http.erl's
  // Secret for the pattern this exists for), so reconnecting with the
  // exact same path resumes rather than starting over: watch for that
  // terminal CLOSED state and open a fresh EventSource ourselves.
  "sse:connect/3": (path, mod, fn) => {
    const RETRY_MS = 1000;
    let attempt = 0;
    const open = () => {
      attempt += 1;
      const label = `[sse:connect ${path.value}]`;
      console.log(`${label} connecting (attempt ${attempt})`);
      const source = new EventSource(path.value);
      // Fires both for this attempt's own initial connect *and* every
      // time the browser's built-in retry succeeds on the same
      // EventSource object (it doesn't get recreated for that) -- so
      // this line alone surfaces every reconnect, ours or theirs.
      source.onopen = () => {
        console.log(`${label} connected`);
      };
      source.onmessage = (e) => {
        const term = wireToTerm(JSON.parse(e.data));
        Interpreter.callTopLevel(mod.value, fn.value, 1, [term]);
      };
      source.onerror = () => {
        if (source.readyState === EventSource.CLOSED) {
          console.log(`${label} connection closed for good; reconnecting in ${RETRY_MS}ms`);
          setTimeout(open, RETRY_MS);
        } else {
          console.log(`${label} connection error (readyState=${source.readyState}); browser will retry`);
        }
      };
    };
    open();
    return Type.atom("ok");
  },
  // http:post_json(Path, ParamsMap) — fire-and-forget JSON POST; the
  // response (if any) is ignored. ParamsMap is a flat map of scalars,
  // converted to a plain JS object (see termToPlainJs) and JSON-encoded.
  "http:post_json/2": (path, paramsMap) => {
    const obj = {};
    for (const [k, v] of paramsMap.data) obj[termToPlainJs(k)] = termToPlainJs(v);
    fetch(path.value, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(obj),
    });
    return Type.atom("ok");
  },
  // --- math ---
  "math:pi/0":  () => Type.float(Math.PI),
  "math:sin/1": (x) => Type.float(Math.sin(x.value)),
  "math:cos/1": (x) => Type.float(Math.cos(x.value)),
  "math:sqrt/1": (x) => Type.float(Math.sqrt(x.value)),

  // --- canvas module: 2D canvas drawing exposed as BIFs. Each BIF takes
  // an ElementId (bitstring) identifying a <canvas> element as its first
  // argument; the 2D context is looked up (and cached) by that id.
  "canvas:clear/1": (id) => {
    const ctx = canvasCtx(id.value);
    ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
    return Type.atom("ok");
  },
  "canvas:width/1": (id) => Type.integer(canvasCtx(id.value).canvas.width),
  "canvas:height/1": (id) => Type.integer(canvasCtx(id.value).canvas.height),
  "canvas:begin_path/1": (id) => {
    canvasCtx(id.value).beginPath();
    return Type.atom("ok");
  },
  "canvas:move_to/3": (id, x, y) => {
    canvasCtx(id.value).moveTo(x.value, y.value);
    return Type.atom("ok");
  },
  "canvas:line_to/3": (id, x, y) => {
    canvasCtx(id.value).lineTo(x.value, y.value);
    return Type.atom("ok");
  },
  "canvas:arc/6": (id, x, y, r, startAngle, endAngle) => {
    canvasCtx(id.value).arc(x.value, y.value, r.value, startAngle.value, endAngle.value);
    return Type.atom("ok");
  },
  "canvas:stroke/1": (id) => {
    canvasCtx(id.value).stroke();
    return Type.atom("ok");
  },
  "canvas:fill/1": (id) => {
    canvasCtx(id.value).fill();
    return Type.atom("ok");
  },
  "canvas:set_line_width/2": (id, w) => {
    canvasCtx(id.value).lineWidth = w.value;
    return Type.atom("ok");
  },
  "canvas:set_global_alpha/2": (id, a) => {
    canvasCtx(id.value).globalAlpha = a.value;
    return Type.atom("ok");
  },
  // canvas:set_stroke_hsl(Id, Hue, Saturation, Lightness) — Hue in
  // degrees (0-360), Saturation/Lightness as percentages (0-100).
  "canvas:set_stroke_hsl/4": (id, h, s, l) => {
    canvasCtx(id.value).strokeStyle = `hsl(${h.value}, ${s.value}%, ${l.value}%)`;
    return Type.atom("ok");
  },
  "canvas:set_fill_hsl/4": (id, h, s, l) => {
    canvasCtx(id.value).fillStyle = `hsl(${h.value}, ${s.value}%, ${l.value}%)`;
    return Type.atom("ok");
  },
  // canvas:set_fill_rgba(Id, R, G, B, Alpha) — used for translucent trail
  // fades, since set_fill_hsl has no alpha channel of its own.
  "canvas:set_fill_rgba/5": (id, r, g, b, a) => {
    canvasCtx(id.value).fillStyle = `rgba(${r.value}, ${g.value}, ${b.value}, ${a.value})`;
    return Type.atom("ok");
  },
  "canvas:fill_rect/5": (id, x, y, w, h) => {
    canvasCtx(id.value).fillRect(x.value, y.value, w.value, h.value);
    return Type.atom("ok");
  },

  // --- ui module: demo-only slots for holding values across separate
  // cold top-level calls (one dom:on_click dispatch per click has no
  // shared JS closure state) -- this runtime has no process registry
  // (register/whereis) yet, so demos need *some* place to remember
  // e.g. a spawned server's pid, or a session secret.
  "ui:set_pid/1": (pid) => { uiPid = pid; return Type.atom("ok"); },
  "ui:get_pid/0": () => uiPid,
  // A general keyed version of the above, for demos juggling more than
  // one value (see snake_client.erl: session secret + own color).
  // ui:get/1 returns the atom 'undefined' for a key never set.
  "ui:set/2": (key, value) => { uiStore.set(termToPlainJs(key), value); return Type.atom("ok"); },
  "ui:get/1": (key) =>
    uiStore.has(termToPlainJs(key)) ? uiStore.get(termToPlainJs(key)) : Type.atom("undefined"),

  "maps:get/2": (key, map) => {
    const pair = map.data.find(([k]) => termEqual(k, key));
    if (!pair) throw new Error(`maps:get — key not found: ${termToString(key)}`);
    return pair[1];
  },
  "maps:get/3": (key, map, def) => {
    const pair = map.data.find(([k]) => termEqual(k, key));
    return pair ? pair[1] : def;
  },
  "maps:find/2": (key, map) => {
    const pair = map.data.find(([k]) => termEqual(k, key));
    return pair ? Type.tuple([Type.atom("ok"), pair[1]]) : Type.atom("error");
  },
};

// Expose everything on window so demo scripts can use them as globals.
window.Type        = Type;
window.Interpreter = Interpreter;
window.Erlang      = Erlang;
window.modules     = modules;
window.termToString = termToString;
