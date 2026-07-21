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
    click_listener_dispatches/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [hydrate_renders_server_state,
     dispatch_updates_dom,
     click_listener_dispatches]}].
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
        <<"const window = {};\n"
          "const container = {\n"
          "  innerHTML: \"\",\n"
          "  listeners: {},\n"
          "  addEventListener(type, fn) { this.listeners[type] = fn; },\n"
          "};\n"
          "const document = { getElementById: () => container };\n">>,
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

lines(Bin) ->
    [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>].
