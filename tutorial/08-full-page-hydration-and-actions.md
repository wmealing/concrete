# 08 — Full page: hydration and actions

This is everything wired together: a page that renders on the server,
hydrates in the browser, and has buttons that dispatch to compiled
Erlang with no server round-trip.

## See it run first

```
rebar3 shell
```
```erlang
template_demo:serve().    %% http://localhost:8766
```

Click **+** / **−**: `Score:` and the derived `Next score:` update
instantly. Try http://localhost:8766/?player=sam&score=100 — query
params seed the *server* state, which flows into the client via
hydration, so the counter starts at 100.

## The page module

A page implements `init/2` (server: params → state), `template/0`, and
`action/3` (client: compiled to JS):

```erlang
-module(scoreboard_page).
-export([init/2, template/0, action/3]).

init(Params, Server) ->
    State = #{title  => <<"Scores">>,
              player => maps:get(player, Params, <<"anonymous">>),
              score  => int_param(score, Params, 41)},
    {#{state => State}, Server}.

template() ->
    "scoreboard.slab".

action(increment, _Params, #{state := #{score := N} = S} = C) ->
    C#{state => S#{score := N + 1}};
action(decrement, _Params, #{state := #{score := N} = S} = C) ->
    C#{state => S#{score := N - 1}}.
```

## The request lifecycle

1. **Server render** — the cowboy handler calls
   `concrete_renderer:render_page(scoreboard_page, Params)`: `init/2`
   builds state, the template renders to HTML, and the component map is
   serialized to type-tagged JSON (the *hydration payload*).
2. **Bundle** — `/bundle.js` is generated from the page module's BEAM
   (`concrete_beam_reader` → IR → encoder) plus the template compiled to
   `render/1`. See `template_demo:bundle_js/1`.
3. **Hydrate** — the page loads `runtime.js`, `client.js`, the bundle,
   then boots:
   ```javascript
   Client.init("scoreboard_page", "concrete-root", {"type":"map", ...});
   ```
   `client.js` deserializes the JSON back into terms and installs one
   delegated click listener on the root element.
4. **Dispatch** — a click on `concrete-click="increment"` runs:
   ```
   Client.dispatch → compiled action/3 → new component map
                   → compiled render/1 → container.innerHTML
   ```
   The same Erlang clauses you wrote in the module, executing in the
   browser. (Full re-render per action for now; vdom diffing is the
   planned Phase 5 upgrade.)

## Wire format

State crosses the wire as type-tagged JSON
(`concrete_serializer` / `concrete_deserializer` on the server,
`Client.deserialize` in the browser):

```json
{"type":"map","data":[
  [{"type":"atom","value":"state"},
   {"type":"map","data":[
     [{"type":"atom","value":"score"},{"type":"integer","value":41}]]}]]}
```

Binaries travel base64-encoded. Round-trip it in the shell:

```erlang
concrete_demo:wire().
```

## Building your own

For a page of your own, the recipe is `template_demo` + chapter 03:

1. Write a page module (`init/2`, `template/0`, `action/3`) and a
   `.slab` template.
2. Serve HTML that wraps the server render in a container div and loads
   `runtime.js`, `client.js` (`concrete:client_path()`), and your
   bundle.
3. Boot `Client.init(ModuleName, ContainerId, StateJSON)`.

Next: [09 — Testing your code](09-testing-your-code.md)
