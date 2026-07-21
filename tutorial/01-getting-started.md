# 01 — Getting started

Concrete compiles Erlang to JavaScript at build time and runs it in the
browser with a small runtime. No Elixir, no JavaScript frameworks, no npm.

## Build

```
rebar3 compile
```

## Run the tests

```
rebar3 ct
```

All suites run their cases in parallel. Two suites (`js_exec_SUITE`,
`client_SUITE`) execute compiled JavaScript in Node.js and skip
automatically if `node` is not on your PATH.

## Start a shell

Everything in this tutorial is driven from the Erlang shell:

```
rebar3 shell
```

The shell loads the `concrete` application and the example modules
(`concrete_demo`, `template_demo`, `scoreboard_page`).

## Where things live

```
src/               the compiler and server (transformer, encoder, renderer, ...)
include/           concrete_ir.hrl — the IR record definitions
priv/js/demo/      the JS runtime (runtime.js, client.js) and browser demos
priv/js/upstream/  unadapted upstream Hologram JS — reference only
priv/templates/    .slab templates
example/           demo modules used throughout this tutorial
```

Next: [02 — Compile Erlang to JavaScript](02-compile-erlang-to-javascript.md)
