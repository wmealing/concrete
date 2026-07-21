# 07 — Templates

Pages and components describe their markup in `.slab` templates
(concrete gets poured into a slab). Syntax:

```html
<div class="scoreboard">
  <h1>{@title}</h1>                      <!-- state interpolation -->
  <p>Next: {@score + 1}</p>              <!-- any Erlang expression -->
  <button concrete-click="increment">+</button>
  <:component module={badge} score={@score} />   <!-- embed a child -->
</div>
```

- `{@name}` reads `name` from component state. It's rewritten to
  `maps:get(name, CONCRETE_STATE)` and parsed as real Erlang, which is
  why arbitrary expressions like `{@score + 1}` work.
- `concrete-click="action"` names the action a click dispatches
  (chapter 08).
- `<:component module={mod} prop={expr} />` embeds a child component;
  props are evaluated against the parent's state, then passed to the
  child's `init/2`.

Templates live in `priv/templates/` (configurable via the
`templates_dir` app env) or inline:
`template() -> {inline, concrete_template_parser:parse_string("...")}.`

## One template, two renderers

The same parsed DOM AST renders in both places:

**Server side** — `concrete_renderer` walks the AST and evaluates
expressions with `erl_eval` for the initial HTML response. Evaluated
values are HTML-escaped; void elements (`<br>`, `<img>`) render without
closing tags.

**Client side** — `concrete_template_parser:compile_render_fun/1`
compiles the AST into an IR `render/1` function, which the encoder emits
as JavaScript. In the browser it rebuilds the DOM tree with all
expressions evaluated — same markup as the server, byte for byte.

## See it run

```
rebar3 shell
```
```erlang
concrete_demo:render().
```

prints the template, its DOM AST, the server-rendered HTML (with state
`#{title => <<"Scores">>, score => 41}` — note `Next score: 42`
computed from `{@score + 1}`), and the compiled client render function.

To render a full page module:

```erlang
{HTML, StateJSON, _Server} = concrete_renderer:render_page(scoreboard_page, #{}),
```

`HTML` is the page body; `StateJSON` is the type-tagged hydration
payload the client uses in chapter 08.

Next: [08 — Full page: hydration and actions](08-full-page-hydration-and-actions.md)
