# Concrete Tutorial

A guided tour of everything currently implemented, in the order it makes
sense to learn it. Each chapter is self-contained and every code block is
runnable as shown.

| Chapter | What you'll learn |
|---|---|
| [01 — Getting started](01-getting-started.md) | Build the project, start a shell, run the tests |
| [02 — Compile Erlang to JavaScript](02-compile-erlang-to-javascript.md) | The compiler pipeline and what the generated JS looks like |
| [03 — Use the JavaScript in your own page](03-use-the-javascript-in-your-own-page.md) | Extract the JS + runtime and call compiled Erlang from any web page |
| [04 — Language features](04-language-features.md) | What compiles today: patterns, funs, comprehensions, try/catch, bitstrings — and what doesn't |
| [05 — Talking to the DOM](05-talking-to-the-dom.md) | The `dom` BIF module; a self-scheduling Erlang loop in the browser |
| [06 — Bundles and dead-code elimination](06-bundles-and-dead-code-elimination.md) | BEAM → IR → call graph → minimal bundle |
| [07 — Templates](07-templates.md) | `.slab` syntax, server-side rendering, compiling templates for the client |
| [08 — Full page: hydration and actions](08-full-page-hydration-and-actions.md) | The whole loop: server render → hydrate → buttons dispatch compiled `action/3` |
| [09 — Testing your code](09-testing-your-code.md) | The test suites, and how to round-trip your own code through Node.js |

Prerequisites: Erlang/OTP 25+, rebar3, and Node.js (only needed for the
headless verification steps — a browser works too).
