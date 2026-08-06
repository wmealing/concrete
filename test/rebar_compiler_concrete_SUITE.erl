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
    bundle_digest_reflects_template_file_changes/1
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
        bundle_digest_reflects_template_file_changes
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
