# {{name}}

A [Concrete](https://github.com/wmealing/concrete) app.

## Run

    rebar3 shell

Then visit http://localhost:{{port}}/ -- click the counter buttons; the
click dispatches `{{name}}_page:action/3`, compiled to JS at build time by
`rebar_compiler_concrete` and executed in the browser, then patches the DOM.

## Structure

- `src/{{name}}_page.erl` -- page module, routed at `/`, with the counter's
  `action/3` right on it (a page module can act like a component)
- `priv/templates/page.slab` -- template
