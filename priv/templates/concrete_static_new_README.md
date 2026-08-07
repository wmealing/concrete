# {{name}}

A [Concrete](https://github.com/wmealing/concrete) app compiled to a static
HTML/JS page -- no cowboy, no gproc, no server. Unlike the `concrete_app`
template, `src/{{name}}.erl` is a plain module (no `concrete_page`/
`concrete_component` behaviour, no `.slab` template) that drives the DOM
directly via the `dom:*` BIFs.

## Build

    rebar3 shell
    {{name}}_build:build().

This writes `priv/{{name}}.js` (your compiled Erlang) and `priv/runtime.js`
(the `Type`/`Interpreter`/`Erlang` BIF runtime it needs).

## Run

Open `priv/index.html` directly in a browser -- click the button. No server
required: the generated scripts are classic `<script src=...>` tags, not ES
modules, so this works straight from `file://`. You can also serve `priv/`
with any static file server (`python3 -m http.server`, `npx serve`, etc.) if
you prefer.

## Structure

- `src/{{name}}.erl` -- the app, compiled to JS by `{{name}}_build:build/0`
- `src/{{name}}_build.erl` -- the build step (`concrete:compile_module/1`)
- `priv/index.html` -- static page that loads the compiled bundle
