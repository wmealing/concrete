%% Tests for rebar_compiler_concrete's <:component>-and-layout-aware
%% bundling: discover_modules/2 (which modules a page's bundle needs)
%% and bundle_digest/2 (staleness detection over that whole set).
-module(rebar_compiler_concrete_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    discovers_embedded_component/1,
    discovers_transitively_embedded_component/1,
    discover_modules_terminates_on_cycle/1,
    discovers_page_layout/1,
    no_layout_discovers_page_only/1,
    bundle_digest_is_deterministic/1,
    bundle_digest_reflects_template_file_changes/1,
    populate_plt_never_traces_concrete_js/1,
    populate_plt_never_traces_unreachable_command/1,
    bundle_with_io_format_in_command_compiles/1,
    bundle_with_inline_layout_template_compiles/1,
    bundle_never_traces_compiler_internal_modules/1,
    bundle_with_maps_get_in_init_compiles/1,
    bundle_never_emits_native_bif_definitions/1,
    mount_root_helper_reaches_bundle_without_dead_branch/1
]).

all() ->
    [{group, all_parallel}].

groups() ->
    [{all_parallel, [parallel], [
        discovers_embedded_component,
        discovers_transitively_embedded_component,
        discover_modules_terminates_on_cycle,
        discovers_page_layout,
        no_layout_discovers_page_only,
        bundle_digest_is_deterministic,
        bundle_digest_reflects_template_file_changes,
        populate_plt_never_traces_concrete_js,
        populate_plt_never_traces_unreachable_command,
        bundle_with_io_format_in_command_compiles,
        bundle_with_inline_layout_template_compiles,
        bundle_never_traces_compiler_internal_modules,
        bundle_with_maps_get_in_init_compiles,
        bundle_never_emits_native_bif_definitions,
        mount_root_helper_reaches_bundle_without_dead_branch
    ]}].

discovers_embedded_component(_Config) ->
    {Modules, DOMs} = rebar_compiler_concrete:discover_modules(fixture_widget, "unused"),
    [fixture_widget, fixture_badge] = Modules,
    true = maps:is_key(fixture_widget, DOMs),
    true = maps:is_key(fixture_badge, DOMs).

discovers_transitively_embedded_component(_Config) ->
    %% fixture_dashboard embeds fixture_widget, which embeds
    %% fixture_badge -- badge is only reachable two levels down.
    {Modules, _DOMs} = rebar_compiler_concrete:discover_modules(fixture_dashboard, "unused"),
    [fixture_dashboard, fixture_widget, fixture_badge] = Modules.

discover_modules_terminates_on_cycle(_Config) ->
    {Modules, _DOMs} = rebar_compiler_concrete:discover_modules(fixture_cycle_a, "unused"),
    [fixture_cycle_a, fixture_cycle_b] = Modules.

%% fixture_layout_page declares {layout, fixture_layout, ...} in its
%% -concrete(...) attribute -- a reference component_modules/1 alone
%% can never find, since it lives outside the template entirely.
discovers_page_layout(_Config) ->
    {Modules, DOMs} = rebar_compiler_concrete:discover_modules(fixture_layout_page, "unused"),
    [fixture_layout_page, fixture_layout] = Modules,
    true = maps:is_key(fixture_layout, DOMs).

no_layout_discovers_page_only(_Config) ->
    %% fixture_badge has no -concrete(...) attribute (so no layout) and
    %% embeds nothing itself.
    {Modules, _DOMs} = rebar_compiler_concrete:discover_modules(fixture_badge, "unused"),
    [fixture_badge] = Modules.

bundle_digest_is_deterministic(_Config) ->
    D1 = rebar_compiler_concrete:bundle_digest([fixture_widget, fixture_badge], "unused"),
    D2 = rebar_compiler_concrete:bundle_digest([fixture_widget, fixture_badge], "unused"),
    D1 = D2,
    true = D1 =/= undefined.

%% fixture_page:template/0 returns a relative filename ("fixture_page.slab"),
%% resolved against whatever TemplatesDir is passed in -- plant one in a
%% scratch dir and edit it between two digest calls.
bundle_digest_reflects_template_file_changes(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Path = filename:join(PrivDir, "fixture_page.slab"),
    ok = file:write_file(Path, "<p>v1</p>"),
    D1 = rebar_compiler_concrete:bundle_digest([fixture_page], PrivDir),
    ok = file:write_file(Path, "<p>v2</p>"),
    D2 = rebar_compiler_concrete:bundle_digest([fixture_page], PrivDir),
    true = D1 =/= D2.

%% Regression test for the concrete_js shadowing bug, through the real
%% pipeline: fixture_js_action_page's action/3 genuinely calls
%% concrete_js:call/2, so it's a real entry in the reachable set
%% concrete_call_graph builds. Before the fix, populate_plt/2 would
%% happily cache concrete_js's own (harmless pass-through) function
%% bodies alongside it -- which concrete_encoder would then emit as
%% Interpreter.defineErlangFunction("concrete_js", ...) calls that
%% clobber the hand-written native BIFs in runtime.js. After the fix,
%% concrete_beam_reader refuses to trace concrete_js at all, so none of
%% its MFAs ever make it into the PLT, no matter how it's reached.
populate_plt_never_traces_concrete_js(_Config) ->
    PLT = concrete_plt:new(),
    ok = rebar_compiler_concrete:populate_plt(PLT, [fixture_js_action_page]),
    not_found = concrete_plt:get(PLT, {concrete_js, call, 2}),
    not_found = concrete_plt:get(PLT, {concrete_js, call, 3}),
    %% Sanity check the walk actually reached real code (the page's own
    %% action/3), so "nothing got cached" isn't just an artifact of the
    %% walk never running.
    {ok, _} = concrete_plt:get(PLT, {fixture_js_action_page, action, 3}).

%% Regression test for command/3 no longer being a call-graph root
%% (concrete_call_graph:page_entries/2). fixture_io_command_page has a
%% real action/3 and a real command/3, and nothing in action/3 calls
%% command/3 -- so command/3 is only reachable the way a browser
%% actually reaches it: over HTTP/WebSocket to the real BEAM function,
%% never through the JS-bundle call graph.
%%
%% Note this is NOT about PLT presence: populate_mfa/2's caching is
%% coarse-grained by design (populating one MFA of a module caches that
%% whole module's IR, see populate_plt/2's own comment), so
%% command/3 legitimately ends up in the PLT once action/3 does --
%% same as concrete_js's *would* have, if extract_ir/1 didn't refuse it
%% outright at a different layer. What actually decides whether
%% command/3's body reaches the JS encoder is reachable/1, built from
%% page_entries/2's roots -- that's what this test (and
%% bundle_with_io_format_in_command_compiles below) actually checks.
populate_plt_never_traces_unreachable_command(_Config) ->
    PLT = concrete_plt:new(),
    ok = rebar_compiler_concrete:populate_plt(PLT, [fixture_io_command_page]),
    {ok, _} = concrete_plt:get(PLT, {fixture_io_command_page, action, 3}),
    Entries   = concrete_call_graph:page_entries(fixture_io_command_page, PLT),
    Graph     = concrete_call_graph:build_from_entries(Entries, PLT),
    Reachable = concrete_call_graph:reachable(Graph),
    true  = lists:member({fixture_io_command_page, action, 3}, Reachable),
    false = lists:member({fixture_io_command_page, command, 3}, Reachable).

%% The actual regression this whole fix is for: before command/3 was
%% excluded from page_entries/2, encoding a bundle for a page whose
%% command/3 calls io:format/2 would crash concrete_encoder trying to
%% compile io:format/2's own IR into JS -- even though command/3 only
%% ever runs server-side. With command/3 no longer a root, the bundle
%% encodes cleanly and command/3's body never gets anywhere near the
%% encoder.
bundle_with_io_format_in_command_compiles(_Config) ->
    PLT = concrete_plt:new(),
    ok = rebar_compiler_concrete:populate_plt(PLT, [fixture_io_command_page]),
    Entries = concrete_call_graph:page_entries(fixture_io_command_page, PLT),
    Graph   = concrete_call_graph:build_from_entries(Entries, PLT),
    Bundle  = concrete_encoder:encode_bundle(Graph, PLT),
    true = is_binary(Bundle),
    true = byte_size(Bundle) > 0.

%% Two more call-graph-root bugs, same family as populate_plt_never_traces_concrete_js
%% above. fixture_layout_page/fixture_layout is the exact real-pipeline
%% shape rebar_compiler_concrete:discover_modules/2 produces for a page
%% with a declared layout: both modules' template/0 uses the documented
%% {inline, concrete_template_parser:parse_string(...)} pattern, and
%% fixture_layout's init/2 uses maps:get/3. discovers_page_layout/1
%% above only exercises discover_modules/2, which never calls
%% encode_bundle/2 -- so it never hit either bug. These do, through the
%% real populate_plt/2 -> build_from_entries/2 -> encode_bundle/2 path.
layout_bundle(_Config) ->
    Modules = [fixture_layout_page, fixture_layout],
    PLT = concrete_plt:new(),
    ok = rebar_compiler_concrete:populate_plt(PLT, Modules),
    Entries = lists:flatmap(fun(Mod) -> concrete_call_graph:page_entries(Mod, PLT) end, Modules),
    Graph   = concrete_call_graph:build_from_entries(Entries, PLT),
    {Graph, PLT}.

%% Bug 1: template/0 calling concrete_template_parser:parse_string/1
%% used to crash concrete_encoder with {unhandled_ast_node, ...} trying
%% to compile the parser's own character-literal-heavy source. With
%% concrete_template_parser tagged compiler_internal, it's never traced
%% and the bundle just encodes without it.
bundle_with_inline_layout_template_compiles(_Config) ->
    {Graph, PLT} = layout_bundle(_Config),
    Bundle = concrete_encoder:encode_bundle(Graph, PLT),
    true = is_binary(Bundle),
    true = byte_size(Bundle) > 0.

%% concrete_template_parser:parse_string/1 (called from both fixtures'
%% template/0) is reachable -- it's a genuine callee -- but must never
%% get populated into the PLT with its real (untraceable) source, since
%% concrete_beam_reader:extract_ir/1 refuses to trace a compiler_internal
%% module. encode_mfa/3 then emits nothing for it instead of crashing.
bundle_never_traces_compiler_internal_modules(_Config) ->
    {Graph, PLT} = layout_bundle(_Config),
    Reachable = concrete_call_graph:reachable(Graph),
    true = lists:member({concrete_template_parser, parse_string, 1}, Reachable),
    not_found = concrete_plt:get(PLT, {concrete_template_parser, parse_string, 1}).

%% Bug 2: init/2 calling maps:get/3 used to compile clean but throw at
%% first client-side use ("Refusing to overwrite native BIF
%% Erlang[\"maps:get/3\"]..."), because maps:get/3 has real,
%% debug_info-compiled stdlib source that traced and compiled cleanly,
%% clobbering the hand-written native BIF's runtime.js key. With
%% concrete_native_bifs filtering it out of the call graph, the bundle
%% still compiles clean.
bundle_with_maps_get_in_init_compiles(_Config) ->
    {Graph, PLT} = layout_bundle(_Config),
    Bundle = concrete_encoder:encode_bundle(Graph, PLT),
    true = is_binary(Bundle),
    true = byte_size(Bundle) > 0.

%% The actual regression: the bundle must never contain a compiled
%% definition for maps:get/3 (or any other native-shadowed MFA) that
%% would clobber runtime.js's hand-written version at load time.
bundle_never_emits_native_bif_definitions(_Config) ->
    {Graph, PLT} = layout_bundle(_Config),
    Reachable = concrete_call_graph:reachable(Graph),
    false = lists:member({maps, get, 3}, Reachable),
    Bundle = concrete_encoder:encode_bundle(Graph, PLT),
    nomatch = binary:match(Bundle, <<"defineErlangFunction(\"maps\"">>).

%% The reachability-anchor workaround docs/on-mount-plan.md removes:
%% fixture_mount_reachability_page's on_event/1 is only ever reached,
%% in real usage, through a bare-atom Module/Function pair handed to
%% sse:connect/3 -- something concrete_call_graph:collect_calls/2 can't
%% trace (it only follows literal call nodes, never data flowing
%% through a call's own arguments). Before mount/1 was a call-graph
%% root, on_event/1 needed a second, fake call site elsewhere just to
%% survive dead-code elimination. Here it's reached the ordinary way,
%% through mount/1's own literal call to it -- and mount/1 itself is
%% only reachable because page_entries/2 now roots the graph there,
%% the same way it already does for action/3.
mount_root_helper_reaches_bundle_without_dead_branch(_Config) ->
    PLT = concrete_plt:new(),
    ok = rebar_compiler_concrete:populate_plt(PLT, [fixture_mount_reachability_page]),
    Entries = concrete_call_graph:page_entries(fixture_mount_reachability_page, PLT),
    true = lists:member({fixture_mount_reachability_page, mount, 1}, Entries),
    Graph = concrete_call_graph:build_from_entries(Entries, PLT),
    Reachable = concrete_call_graph:reachable(Graph),
    true = lists:member({fixture_mount_reachability_page, on_event, 1}, Reachable),
    Bundle = concrete_encoder:encode_bundle(Graph, PLT),
    {_, _} = binary:match(Bundle,
        <<"defineErlangFunction(\"fixture_mount_reachability_page\", \"on_event\"">>).
