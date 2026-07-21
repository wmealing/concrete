# 05 — Talking to the DOM

Erlang talks to the DOM the same way it talks to anything outside the
VM: through BIFs. The runtime exposes a `dom` module — implemented in
JavaScript, called like any Erlang module:

| Erlang call | Effect |
|---|---|
| `dom:append_html(Id, Html)` | `insertAdjacentHTML("beforeend", ...)` on element `Id` |
| `dom:set_text(Id, Text)` | replace the element's `textContent` |
| `dom:set_timeout(Ms, M, F, Args)` | schedule an Erlang MFA call — the browser analogue of `erlang:send_after/3` |

## A loop that runs forever

The browser is single-threaded, so a tail-recursive infinite loop would
freeze the tab. The idiom (same shape as upstream Hologram's event
loop): each step does its work and *schedules the next step*, returning
control to the browser in between:

```erlang
-module(counter).
-export([start/0, tick/1]).

start() ->
    tick(0).

tick(N) ->
    dom:append_html(<<"output">>, integer_to_binary(N)),
    dom:append_html(<<"output">>, <<"<br>">>),
    dom:set_timeout(250, counter, tick, [N + 1]).
```

All the logic — the DOM writes, the increment, the rescheduling — is
Erlang. The page's only JavaScript is one bootstrap line:

```javascript
Interpreter.call("counter", "start", 0, []);
```

## See it run

```
rebar3 shell
```
```erlang
concrete_demo:build().    %% compiles the counter to priv/js/demo/counter.js
concrete_demo:serve().    %% serves the demo on http://localhost:8765
```

Open http://localhost:8765 — a number appends forever, one line per
250ms tick.

To build this into your own page (chapter 03 layout): compile the module
with `concrete:compile_to_file/2`, load `runtime.js` + your module, and
bootstrap with the one-liner above. Make sure an element with the id
your Erlang code targets (here `output`) exists.

Next: [06 — Bundles and dead-code elimination](06-bundles-and-dead-code-elimination.md)
