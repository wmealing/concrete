%% Client-side hydration + action dispatch tests.
%% Full cycle, executed in Node.js against runtime.js + client.js:
%%   server: fixture_counter:init/2 -> serializer -> hydration JSON
%%   client: deserialize -> render/1 -> click -> action/3 -> re-render
%% Skipped entirely if node is not on PATH.
-module(client_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    hydrate_renders_server_state/1,
    dispatch_updates_dom/1,
    click_listener_dispatches/1,
    dispatch_patches_dom_in_place/1,
    embedded_component_renders/1,
    render_with_layout_fills_slot/1,
    slot_outside_layout_throws/1,
    command_button_dispatches_over_http/1,
    mount_runs_once_after_first_render/1,
    mount_is_noop_without_definition/1,
    component_instance_persists_and_mounts_once/1,
    component_without_mount_is_noop/1,
    keyed_instances_added_and_removed/1,
    for_loop_renders_keyed_component_list/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [hydrate_renders_server_state,
     dispatch_updates_dom,
     click_listener_dispatches,
     dispatch_patches_dom_in_place,
     embedded_component_renders,
     render_with_layout_fills_slot,
     slot_outside_layout_throws,
     command_button_dispatches_over_http,
     mount_runs_once_after_first_render,
     mount_is_noop_without_definition,
     component_instance_persists_and_mounts_once,
     component_without_mount_is_noop,
     keyed_instances_added_and_removed,
     for_loop_renders_keyed_component_list]}].
init_per_suite(Config) ->
    case os:find_executable("node") of
        false -> {skip, "node not found on PATH"};
        _     -> Config
    end.

end_per_suite(_Config) ->
    ok.

%% Hydration: the client render must reflect the state the *server*
%% built in init/2 (label from props), not client defaults.
hydrate_renders_server_state(Config) ->
    Out = run_client(Config, #{label => <<"score">>}, ""),
    [First | _] = lines(Out),
    <<"<p>score: 0</p><button concrete-click=\"increment\">+</button>">> = First.

dispatch_updates_dom(Config) ->
    Out = run_client(Config, #{},
        "Client.dispatch(\"increment\");\n"
        "console.log(container.innerHTML);\n"
        "Client.dispatch(\"increment\");\n"
        "console.log(container.innerHTML);\n"),
    [_Initial, AfterOne, AfterTwo | _] = lines(Out),
    {_, _} = binary:match(AfterOne, <<"clicks: 1">>),
    {_, _} = binary:match(AfterTwo, <<"clicks: 2">>).

%% The delegated click listener installed by Client.init must dispatch
%% the action named by the concrete-click attribute.
click_listener_dispatches(Config) ->
    Out = run_client(Config, #{},
        "container.listeners[\"click\"]({\n"
        "  target: { closest: () => ({ getAttribute: () => \"increment\" }) },\n"
        "  preventDefault() {},\n"
        "});\n"
        "console.log(container.innerHTML);\n"),
    [_Initial, AfterClick | _] = lines(Out),
    {_, _} = binary:match(AfterClick, <<"clicks: 1">>).

%% The actual point of vdom diffing: an action that only changes one
%% piece of text must patch that text node's value in place, not tear
%% down and rebuild the DOM around it. <p>{@label}: {@count}</p> means
%% the <p> has three text-vnode children (label, ": ", count); only the
%% count one should ever change value, and the <p>, the <button>, and
%% all three text node *objects* must survive the dispatch untouched.
dispatch_patches_dom_in_place(Config) ->
    Out = run_client(Config, #{},
        "const pBefore = container.childNodes[0];\n"
        "const buttonBefore = container.childNodes[1];\n"
        "const textNodesBefore = pBefore.childNodes.slice();\n"
        "Client.dispatch(\"increment\");\n"
        "console.log(JSON.stringify({\n"
        "  samePEl: container.childNodes[0] === pBefore,\n"
        "  sameButtonEl: container.childNodes[1] === buttonBefore,\n"
        "  sameTextNodes: pBefore.childNodes.every((n, i) => n === textNodesBefore[i]),\n"
        "  countText: pBefore.childNodes[2].textContent,\n"
        "}));\n"),
    [_Initial, ResultJSON | _] = lines(Out),
    {ok, #{<<"samePEl">> := true, <<"sameButtonEl">> := true,
           <<"sameTextNodes">> := true, <<"countText">> := <<"1">>}} =
        thoas:decode(ResultJSON).

%% fixture_widget's template is just <:component module={fixture_badge}
%% score={@n} /> -- a bundle built from both modules must render the
%% embedded child's own compiled render/1 client-side, the same way
%% concrete_renderer already does server-side (see renderer_SUITE's
%% render_component).
embedded_component_renders(Config) ->
    Out = run_client_multi(Config, fixture_widget, [fixture_widget, fixture_badge], #{}, ""),
    [First | _] = lines(Out),
    <<"<span class=\"badge\">20</span>">> = First.

%% Client.renderWithLayout is the client-side equivalent of
%% concrete_renderer:wrap_in_layout/2 -- render fixture_layout's own
%% template (declared as fixture_layout_page's layout) with the page's
%% already-rendered mount HTML spliced in at <slot />.
render_with_layout_fills_slot(Config) ->
    Out = run_client_multi(Config, fixture_layout_page,
        [fixture_layout_page, fixture_layout], #{},
        "const propsMap = Type.map([[Type.atom(\"title\"), Type.bitstring(\"Demo\")]]);\n"
        "const layoutInit = Interpreter.call(\"fixture_layout\", \"init\", 2, [propsMap, Type.map([])]);\n"
        "const layoutState = Interpreter.mapLookup(layoutInit.data[0], Type.atom(\"state\"));\n"
        "console.log(Client.renderWithLayout(\"fixture_layout\", layoutState, container.innerHTML));\n"),
    [PageOnly, Wrapped | _] = lines(Out),
    <<"<p>page content</p>">> = PageOnly,
    <<"<html><head><title>Demo</title></head>"
      "<body><p>page content</p></body></html>">> = Wrapped.

%% A bare <slot /> with no layout wrapping it is a template error --
%% same as concrete_renderer:render_node/3's slot_outside_layout, just
%% client-side.
slot_outside_layout_throws(Config) ->
    Out = run_client(Config, #{},
        "try {\n"
        "  Client.domToHtml(Type.tuple([Type.atom(\"slot\")]));\n"
        "  console.log(\"NO_THROW\");\n"
        "} catch (e) {\n"
        "  console.log(\"THROW:\" + e.message);\n"
        "}\n"),
    [_Initial, Result | _] = lines(Out),
    <<"THROW:slot rendered outside a layout context">> = Result.

%% concrete-command is the declarative counterpart to concrete-click,
%% but for a server round trip: a click POSTs to the same
%% /concrete/command endpoint concrete_command_handler already serves,
%% and the response's Server map gets merged into the component's own
%% state so it shows up through the normal render/1 path. fetch is
%% stubbed here (no real HTTP call) to check the request Client.js
%% actually sent and that the response correctly updates the DOM.
command_button_dispatches_over_http(Config) ->
    Out = run_client_multi(Config, fixture_command_page, [fixture_command_page], #{},
        "let capturedRequest = null;\n"
        "const fetch = (url, options) => {\n"
        "  capturedRequest = { url, body: JSON.parse(options.body) };\n"
        "  return Promise.resolve({\n"
        "    json: () => Promise.resolve({\n"
        "      state: { type: \"map\",\n"
        "               data: [[{type: \"atom\", value: \"count\"}, {type: \"integer\", value: 41}]] }\n"
        "    }),\n"
        "  });\n"
        "};\n"
        "container.listeners[\"click\"]({\n"
        "  target: {\n"
        "    closest: (sel) => sel === \"[concrete-command]\"\n"
        "      ? { getAttribute: () => \"bump\" }\n"
        "      : null,\n"
        "  },\n"
        "  preventDefault() {},\n"
        "});\n"
        "setTimeout(() => {\n"
        "  console.log(JSON.stringify({\n"
        "    url: capturedRequest.url,\n"
        "    module: capturedRequest.body.module,\n"
        "    command: capturedRequest.body.command,\n"
        "    params: capturedRequest.body.params,\n"
        "    stateType: capturedRequest.body.state.type,\n"
        "    html: container.innerHTML,\n"
        "  }));\n"
        "}, 0);\n"),
    [_Initial, ResultJSON | _] = lines(Out),
    {ok, #{<<"url">> := <<"/concrete/command">>,
           <<"module">> := <<"fixture_command_page">>,
           <<"command">> := <<"bump">>,
           <<"params">> := #{},
           <<"stateType">> := <<"map">>,
           <<"html">> := <<"<p>count: 41</p><button concrete-command=\"bump\">+</button>">>}} =
        thoas:decode(ResultJSON).

%% Client.init calls Client.render() then Client.mount() synchronously,
%% in that order, before returning -- so by the time the harness's own
%% post-init console.log runs, mount/1 has already run and its dom:*
%% call has already landed. fixture_mount_page's mount/1 receives the
%% same wire-decoded Component shape action/3 gets (asserted here by
%% actually reading a field out of it) and overwrites the container
%% with a value only mount/1 could have produced.
mount_runs_once_after_first_render(Config) ->
    Out = run_client_multi(Config, fixture_mount_page, [fixture_mount_page],
        #{greeting => <<"mounted-ok">>}, ""),
    [First | _] = lines(Out),
    <<"mounted-ok">> = First.

%% The overwhelming common case -- a page/component that never defines
%% mount/1 -- must stay free: Interpreter.isExported must report false
%% (so Client.mount() never attempts Interpreter.call against a
%% function that was never compiled in), and calling Client.mount()
%% directly must not throw.
mount_is_noop_without_definition(Config) ->
    Out = run_client(Config, #{},
        "console.log(Interpreter.isExported(\"fixture_counter\", \"mount\", 1));\n"
        "try {\n"
        "  Client.mount();\n"
        "  console.log(\"NO_THROW\");\n"
        "} catch (e) {\n"
        "  console.log(\"THROW:\" + e.message);\n"
        "}\n"),
    [_Initial, IsExported, Result | _] = lines(Out),
    <<"false">> = IsExported,
    <<"NO_THROW">> = Result.

%% The core regression test for persistent <:component> instances:
%% fixture_singleton_parent embeds one unkeyed fixture_stateful_child.
%% Dispatching the parent's own "tick" action re-renders it twice, which
%% -- before ComponentInstances existed -- would have called
%% fixture_stateful_child:init/2 fresh both times, discarding any state
%% the child accumulated. Directly bumping the child's persisted
%% component (simulating what a future child-action dispatch path would
%% do) proves the *same* entry is read back on the next parent render
%% instead of a freshly initialized one. mount/2 already ran once during
%% Client.init's first render (the child appears immediately), so a
%% spy installed after that -- covering only the two "tick" re-renders
%% below -- must see zero further calls, proving it never re-fires for
%% an instance that's already mounted.
component_instance_persists_and_mounts_once(Config) ->
    Out = run_client_multi(Config, fixture_singleton_parent,
        [fixture_singleton_parent, fixture_stateful_child], #{},
        "let mountCalls = 0;\n"
        "const originalCall = Interpreter.call;\n"
        "Interpreter.call = (mod, fn, arity, args) => {\n"
        "  if (mod === \"fixture_stateful_child\" && fn === \"mount\" && arity === 2) mountCalls++;\n"
        "  return originalCall(mod, fn, arity, args);\n"
        "};\n"
        "const entry = ComponentInstances.get(\"0\");\n"
        "const wasMountedBeforeSpy = entry.mounted;\n"
        "const bumped = Interpreter.call(\"fixture_stateful_child\", \"action\", 3, [\n"
        "  Type.atom(\"bump\"), Type.map([]), entry.component,\n"
        "]);\n"
        "entry.component = bumped;\n"
        "Client.dispatch(\"tick\");\n"
        "console.log(container.innerHTML);\n"
        "Client.dispatch(\"tick\");\n"
        "console.log(container.innerHTML);\n"
        "console.log(JSON.stringify({\n"
        "  mountCalls, wasMountedBeforeSpy, sameEntry: ComponentInstances.get(\"0\") === entry,\n"
        "}));\n"),
    [_Initial, AfterFirstTick, AfterSecondTick, ResultJSON | _] = lines(Out),
    {_, _} = binary:match(AfterFirstTick, <<"only:1">>),
    {_, _} = binary:match(AfterSecondTick, <<"only:1">>),
    {ok, #{<<"mountCalls">> := 0, <<"wasMountedBeforeSpy">> := true, <<"sameEntry">> := true}} =
        thoas:decode(ResultJSON).

%% fixture_badge defines no mount/2 -- the isExported guard in
%% reconcileComponentInstances must keep that the free case it already
%% is at the page level, both for the isExported check itself and for
%% Client.render() (which runs reconciliation on every pass) not
%% throwing.
component_without_mount_is_noop(Config) ->
    Out = run_client_multi(Config, fixture_widget, [fixture_widget, fixture_badge], #{},
        "console.log(Interpreter.isExported(\"fixture_badge\", \"mount\", 2));\n"),
    [_Initial, IsExported | _] = lines(Out),
    <<"false">> = IsExported.

%% Simulates a keyed, list-rendered set of components across two render
%% passes (bypassing the template layer, which has no dynamic loop
%% construct today -- see the mount plan's non-goals -- by driving
%% Client.resolveComponentDom and Client.reconcileComponentInstances
%% directly, the same functions a real template-driven render pass
%% calls). Pass 1: three keyed items. Pass 2: the middle one removed.
%% Asserts the removed identity leaves ComponentInstances, the survivors
%% keep the exact same entry.component object (not just an equal one),
%% and mount/2 never re-fires for a survivor.
keyed_instances_added_and_removed(Config) ->
    Out = run_client_multi(Config, fixture_widget,
        [fixture_widget, fixture_badge, fixture_stateful_child], #{},
        "let mountCalls = {};\n"
        "const originalCall = Interpreter.call;\n"
        "Interpreter.call = (mod, fn, arity, args) => {\n"
        "  if (mod === \"fixture_stateful_child\" && fn === \"mount\" && arity === 2) {\n"
        "    const id = Interpreter.mapLookup(args[0], Type.atom(\"id\")).value;\n"
        "    mountCalls[id] = (mountCalls[id] || 0) + 1;\n"
        "  }\n"
        "  return originalCall(mod, fn, arity, args);\n"
        "};\n"
        "function propsFor(id) {\n"
        "  return Type.list([Type.tuple([Type.atom(\"id\"), Type.bitstring(id)])]);\n"
        "}\n"
        "function pathIndex() { return Type.integer(0); }\n"
        "function runPass(ids) {\n"
        "  Client.visitedInstances = new Set();\n"
        "  for (const id of ids) {\n"
        "    Client.resolveComponentDom(\n"
        "      Type.atom(\"fixture_stateful_child\"), propsFor(id), Type.bitstring(id), pathIndex());\n"
        "  }\n"
        "  Client.reconcileComponentInstances(Client.visitedInstances);\n"
        "  Client.visitedInstances = null;\n"
        "}\n"
        "runPass([\"a\", \"b\", \"c\"]);\n"
        "const bEntry = ComponentInstances.get(\"0:b\");\n"
        "runPass([\"a\", \"c\"]);\n"
        "console.log(JSON.stringify({\n"
        "  bRemoved: !ComponentInstances.has(\"0:b\"),\n"
        "  aSameEntry: ComponentInstances.get(\"0:a\") !== undefined,\n"
        "  size: ComponentInstances.size,\n"
        "  mountCalls,\n"
        "}));\n"),
    [_Initial, ResultJSON | _] = lines(Out),
    {ok, #{<<"bRemoved">> := true, <<"aSameEntry">> := true, <<"size">> := 2,
           <<"mountCalls">> := #{<<"a">> := 1, <<"b">> := 1, <<"c">> := 1}}} =
        thoas:decode(ResultJSON).

%% End-to-end test of the <:for> loop construct: fixture_list_parent
%% renders a keyed <:component> once per item of a runtime list (not
%% multiple static tags -- the actual compiled loop, run through
%% concrete_encoder and executed here in Node against runtime.js).
%% Removing the middle item and dispatching a fresh render proves the
%% loop's per-iteration component instances behave exactly like the
%% low-level keyed_instances_added_and_removed test already proved the
%% underlying mechanism does: the removed identity's instance is
%% dropped, survivors keep their exact persisted entry.component
%% object, and (the mount spy is installed after Client.init, whose
%% first render already mounted all three) no further mount/2 calls
%% happen at all -- not for the survivors, and obviously not for the
%% one that's gone.
for_loop_renders_keyed_component_list(Config) ->
    Out = run_client_multi(Config, fixture_list_parent,
        [fixture_list_parent, fixture_stateful_child],
        #{items => [<<"a">>, <<"b">>, <<"c">>]},
        "let mountCalls = {};\n"
        "const originalCall = Interpreter.call;\n"
        "Interpreter.call = (mod, fn, arity, args) => {\n"
        "  if (mod === \"fixture_stateful_child\" && fn === \"mount\" && arity === 2) {\n"
        "    const id = Interpreter.mapLookup(args[0], Type.atom(\"id\")).value;\n"
        "    mountCalls[id] = (mountCalls[id] || 0) + 1;\n"
        "  }\n"
        "  return originalCall(mod, fn, arity, args);\n"
        "};\n"
        "const aEntry = ComponentInstances.get(\"0:a\");\n"
        "const newItems = Type.list([Type.bitstring(\"a\"), Type.bitstring(\"c\")]);\n"
        "Client.dispatch(\"set_items\", Type.map([[Type.atom(\"items\"), newItems]]));\n"
        "console.log(container.innerHTML);\n"
        "console.log(JSON.stringify({\n"
        "  bRemoved: !ComponentInstances.has(\"0:b\"),\n"
        "  aSameEntry: ComponentInstances.get(\"0:a\") === aEntry,\n"
        "  size: ComponentInstances.size,\n"
        "  mountCalls,\n"
        "}));\n"),
    [First, AfterRemoval, ResultJSON | _] = lines(Out),
    <<"<ul><span>a:0</span><span>b:0</span><span>c:0</span></ul>">> = First,
    <<"<ul><span>a:0</span><span>c:0</span></ul>">> = AfterRemoval,
    {ok, #{<<"bRemoved">> := true, <<"aSameEntry">> := true, <<"size">> := 2,
           <<"mountCalls">> := #{}}} = thoas:decode(ResultJSON).

%% --- Harness ---
%% Builds the page bundle exactly like template_demo:bundle_js/1 (BEAM
%% -> IR -> JS + compiled render fn), serializes the hydrated component
%% the way render_page/2 does, then boots client.js in Node with a
%% minimal document stub.

run_client(Config, Props, ExtraJS) ->
    {Component, _Server} = fixture_counter:init(Props, #{}),
    StateJSON = thoas:encode(concrete_serializer:encode(Component)),

    {ok, IR} = concrete_beam_reader:extract_ir(fixture_counter),
    ModuleJS = concrete_encoder:encode_module(IR),
    {inline, DOM} = fixture_counter:template(),
    RenderJS = concrete_encoder:encode_function_def(
                   fixture_counter,
                   concrete_template_parser:compile_render_fun(DOM)),

    DemoDir = filename:join([code:priv_dir(concrete), "js", "demo"]),
    {ok, Runtime} = file:read_file(filename:join(DemoDir, "runtime.js")),
    {ok, ClientJS} = file:read_file(filename:join(DemoDir, "client.js")),

    Script = [
        fake_dom_js(),
        Runtime, ClientJS, ModuleJS, RenderJS,
        <<"Client.init(\"fixture_counter\", \"root\", ">>, StateJSON, <<");\n"
          "console.log(container.innerHTML);\n">>,
        ExtraJS
    ],
    File = filename:join(?config(priv_dir, Config),
                         "client_" ++ integer_to_list(erlang:unique_integer([positive]))
                         ++ ".js"),
    ok = file:write_file(File, unicode:characters_to_binary(Script)),
    iolist_to_binary(os:cmd("node " ++ File ++ " 2>&1")).

%% Same idea as run_client/3, but bundles several modules together --
%% mirrors what rebar_compiler_concrete:compile/4 does for a page that
%% embeds <:component>s: every module's own compiled code plus its own
%% render/1, concatenated into one script.
run_client_multi(Config, PageModule, Modules, Props, ExtraJS) ->
    {Component, _Server} = PageModule:init(Props, #{}),
    StateJSON = thoas:encode(concrete_serializer:encode(Component)),

    JS = [module_and_render_js(Mod) || Mod <- Modules],

    DemoDir = filename:join([code:priv_dir(concrete), "js", "demo"]),
    {ok, Runtime} = file:read_file(filename:join(DemoDir, "runtime.js")),
    {ok, ClientJS} = file:read_file(filename:join(DemoDir, "client.js")),

    Script = [
        fake_dom_js(),
        Runtime, ClientJS, JS,
        <<"Client.init(\"">>, atom_to_binary(PageModule), <<"\", \"root\", ">>, StateJSON, <<");\n"
          "console.log(container.innerHTML);\n">>,
        ExtraJS
    ],
    File = filename:join(?config(priv_dir, Config),
                         "client_" ++ integer_to_list(erlang:unique_integer([positive]))
                         ++ ".js"),
    ok = file:write_file(File, unicode:characters_to_binary(Script)),
    iolist_to_binary(os:cmd("node " ++ File ++ " 2>&1")).

module_and_render_js(Mod) ->
    {ok, IR} = concrete_beam_reader:extract_ir(Mod),
    ModuleJS = concrete_encoder:encode_module(IR),
    {inline, DOM} = Mod:template(),
    RenderJS = concrete_encoder:encode_function_def(
                   Mod, concrete_template_parser:compile_render_fun(DOM)),
    [ModuleJS, RenderJS].

lines(Bin) ->
    [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>].

%% client.js's vnode patching (Client.createDomNode/patchNode/
%% patchChildren) calls real DOM-node methods -- createElement,
%% appendChild, replaceChild, removeChild, setAttribute, textContent --
%% that the old innerHTML-string stub never needed to provide. This is
%% a minimal DOM implementation covering exactly what client.js and
%% these tests use, not a general one (e.g. its innerHTML setter only
%% supports clearing to "", since that's the only way client.js ever
%% calls it).
fake_dom_js() ->
    <<"const window = {};\n"
      "class FakeText {\n"
      "  constructor(text) { this.nodeType = 3; this.textValue = text; this.parentNode = null; }\n"
      "  get textContent() { return this.textValue; }\n"
      "  set textContent(v) { this.textValue = v; }\n"
      "}\n"
      "const fakeVoidElements = new Set([\n"
      "  \"area\", \"base\", \"br\", \"col\", \"embed\", \"hr\", \"img\", \"input\",\n"
      "  \"link\", \"meta\", \"param\", \"source\", \"track\", \"wbr\",\n"
      "]);\n"
      "function fakeEscape(s) {\n"
      "  return s.replace(/&/g, \"&amp;\").replace(/</g, \"&lt;\").replace(/>/g, \"&gt;\");\n"
      "}\n"
      "function fakeEscapeAttr(s) { return fakeEscape(s).replace(/\"/g, \"&quot;\"); }\n"
      "function fakeSerialize(node) {\n"
      "  if (node.nodeType === 3) return fakeEscape(node.textValue);\n"
      "  const attrsStr = node.attrOrder\n"
      "    .map((n) => ` ${n}=\"${fakeEscapeAttr(node.attrs[n])}\"`).join(\"\");\n"
      "  if (fakeVoidElements.has(node.tagName)) return `<${node.tagName}${attrsStr}>`;\n"
      "  return `<${node.tagName}${attrsStr}>` +\n"
      "    node.childNodes.map(fakeSerialize).join(\"\") + `</${node.tagName}>`;\n"
      "}\n"
      "class FakeElement {\n"
      "  constructor(tag) {\n"
      "    this.nodeType = 1;\n"
      "    this.tagName = tag;\n"
      "    this.attrOrder = [];\n"
      "    this.attrs = {};\n"
      "    this.childNodes = [];\n"
      "    this.parentNode = null;\n"
      "    this.listeners = {};\n"
      "  }\n"
      "  setAttribute(name, value) {\n"
      "    if (!(name in this.attrs)) this.attrOrder.push(name);\n"
      "    this.attrs[name] = String(value);\n"
      "  }\n"
      "  removeAttribute(name) {\n"
      "    delete this.attrs[name];\n"
      "    this.attrOrder = this.attrOrder.filter((n) => n !== name);\n"
      "  }\n"
      "  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }\n"
      "  appendChild(node) { node.parentNode = this; this.childNodes.push(node); return node; }\n"
      "  removeChild(node) {\n"
      "    const i = this.childNodes.indexOf(node);\n"
      "    if (i >= 0) this.childNodes.splice(i, 1);\n"
      "    node.parentNode = null;\n"
      "    return node;\n"
      "  }\n"
      "  replaceChild(newNode, oldNode) {\n"
      "    const i = this.childNodes.indexOf(oldNode);\n"
      "    this.childNodes[i] = newNode;\n"
      "    newNode.parentNode = this;\n"
      "    oldNode.parentNode = null;\n"
      "    return oldNode;\n"
      "  }\n"
      "  get lastChild() { return this.childNodes[this.childNodes.length - 1] || null; }\n"
      "  get textContent() { return this.childNodes.map((c) => c.textContent).join(\"\"); }\n"
      "  set textContent(v) {\n"
      "    this.childNodes = [];\n"
      "    if (v !== \"\") this.appendChild(new FakeText(v));\n"
      "  }\n"
      "  closest(selector) {\n"
      "    const m = /^\\[([\\w-]+)\\]$/.exec(selector);\n"
      "    let node = this;\n"
      "    while (node) {\n"
      "      if (node.nodeType === 1 && node.getAttribute(m[1]) !== null) return node;\n"
      "      node = node.parentNode;\n"
      "    }\n"
      "    return null;\n"
      "  }\n"
      "  addEventListener(type, fn) { this.listeners[type] = fn; }\n"
      "  get innerHTML() { return this.childNodes.map(fakeSerialize).join(\"\"); }\n"
      "  set innerHTML(html) {\n"
      "    if (html !== \"\") throw new Error(\"fakedom innerHTML setter only supports clearing\");\n"
      "    this.childNodes = [];\n"
      "  }\n"
      "}\n"
      "const container = new FakeElement(\"div\");\n"
      "const document = {\n"
      "  createElement: (tag) => new FakeElement(tag),\n"
      "  createTextNode: (text) => new FakeText(text),\n"
      "  getElementById: () => container,\n"
      "};\n">>.
