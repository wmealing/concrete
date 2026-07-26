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

// Registry of all compiled modules: modules["hello"]["greet/1"] = fn
const modules = {};

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
  defineErlangFunction(moduleName, funcName, arity, clauses) {
    if (!modules[moduleName]) modules[moduleName] = {};
    const key = `${funcName}/${arity}`;
    modules[moduleName][key] = (args) => Interpreter.callClauses(args, clauses);
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
      () => Interpreter.call(mod.value, fn.value, args.data.length, args.data),
      ms.value
    );
    return Type.atom("ok");
  },
  // dom:set_html(ElementId, Html) — replace an element's innerHTML.
  "dom:set_html/2": (id, html) => {
    document.getElementById(id.value).innerHTML = html.value;
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
        Interpreter.call(mod.value, fn.value, 1,
          [Type.bitstring(el.getAttribute(attrName.value))]);
      }
    });
    return Type.atom("ok");
  },
  // dom:on_keydown(ElementId, KeyName, Module, Function) — call
  // Module:Function/0 when KeyName (e.g. "Enter") is pressed in ElementId.
  "dom:on_keydown/4": (id, keyName, mod, fn) => {
    document.getElementById(id.value).addEventListener("keydown", (e) => {
      if (e.key === keyName.value) {
        e.preventDefault();
        Interpreter.call(mod.value, fn.value, 0, []);
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
  "maps:get/2": (key, map) => {
    const pair = map.data.find(([k]) => termEqual(k, key));
    if (!pair) throw new Error(`maps:get — key not found: ${termToString(key)}`);
    return pair[1];
  },
  "maps:get/3": (key, map, def) => {
    const pair = map.data.find(([k]) => termEqual(k, key));
    return pair ? pair[1] : def;
  },
};

// Expose everything on window so demo scripts can use them as globals.
window.Type        = Type;
window.Interpreter = Interpreter;
window.Erlang      = Erlang;
window.modules     = modules;
window.termToString = termToString;
