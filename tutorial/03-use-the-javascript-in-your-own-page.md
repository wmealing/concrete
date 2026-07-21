# 03 — Use the JavaScript in your own page

This chapter extracts everything you need to run compiled Erlang inside
any web page you own — no Concrete server involved.

A page needs exactly two script files:

1. **`runtime.js`** — the Concrete runtime: term constructors (`Type`),
   the clause interpreter (`Interpreter`), and the BIF table (`Erlang`).
2. **your compiled module** — the output of `concrete:compile/1` (or
   `compile_module/1`).

## Step 1 — generate the files

From `rebar3 shell`, in a fresh directory `my_page/`:

```erlang
ok = filelib:ensure_dir("my_page/"),
ok = concrete:compile_to_file(
    "-module(greeter).\n"
    "greeting(Name) -> <<\"Hello, \", Name/binary, \"!\">>.\n"
    "count_chars(Name) -> byte_size(Name).\n",
    "my_page/greeter.js"),
{ok, _} = file:copy(concrete:runtime_path(), "my_page/runtime.js").
```

`concrete:runtime_path()` points at the runtime shipped in
`priv/js/demo/runtime.js`; copying it keeps your page self-contained.

## Step 2 — write the page

`my_page/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Compiled Erlang</title></head>
<body>
  <div id="out"></div>

  <script src="runtime.js"></script>
  <script src="greeter.js"></script>
  <script>
    // Call compiled Erlang: Interpreter.call(Module, Function, Arity, Args)
    const name = Type.bitstring("world");
    const result = Interpreter.call("greeter", "greeting", 1, [name]);

    // result is a term object: {type: "bitstring", value: "Hello, world!"}
    document.getElementById("out").textContent = result.value;
  </script>
</body>
</html>
```

Open `index.html` in a browser (double-click works — no server needed):
the page shows **Hello, world!**, computed by the compiled Erlang
`greeting/1`, including the binary construction `<<"Hello, ",
Name/binary, "!">>` executing in JavaScript.

## The calling convention

- `Interpreter.call(Module, Function, Arity, ArgsArray)` — modules and
  functions are strings (plain atom names), args are term objects.
- Build arguments with `Type.*`: `Type.integer(42)`,
  `Type.atom("ok")`, `Type.bitstring("text")`,
  `Type.list([...])`, `Type.tuple([...])`,
  `Type.map([[key, value], ...])`.
- Read results from the term objects: `.value` for scalars, `.data` for
  tuples/lists/maps. `termToString(term)` pretty-prints any term in
  Erlang syntax — handy for debugging.

## Verifying without a browser

The same files run headlessly in Node.js (this is exactly how the test
suite verifies compiled output):

```
node -e '
const fs = require("fs");
const window = {};
eval(fs.readFileSync("my_page/runtime.js", "utf8")
   + fs.readFileSync("my_page/greeter.js", "utf8")
   + `console.log(Interpreter.call("greeter", "greeting", 1,
        [Type.bitstring("world")]).value);`);
'
```

Prints `Hello, world!`.

Two notes:

- The `const window = {};` shim is only needed outside a browser —
  `runtime.js` publishes its globals on `window`.
- Everything must load in one scope, in order: runtime first, then your
  modules (they register themselves via `Interpreter.defineErlangFunction`).

Next: [04 — Language features](04-language-features.md)
