%% Phase 4: cowboy dispatch table tests.
-module(router_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    page_route_from_concrete_attribute/1,
    module_without_route_is_skipped/1,
    sse_route_carries_an_id_binding/1,
    system_routes_present/1
]).

all() ->
    [{group, all_parallel}].

groups() ->
    [{all_parallel, [parallel], [
        page_route_from_concrete_attribute,
        module_without_route_is_skipped,
        sse_route_carries_an_id_binding,
        system_routes_present
    ]}].

page_route_from_concrete_attribute(_Config) ->
    Routes = concrete_router:routes([fixture_layout_page]),
    {"/layout-demo", concrete_page_handler, #{module := fixture_layout_page}} =
        lists:keyfind("/layout-demo", 1, Routes).

module_without_route_is_skipped(_Config) ->
    %% fixture_page has no -concrete(...) attribute at all.
    Routes = concrete_router:routes([fixture_page]),
    false = lists:keymember(fixture_page, 3, [{R, H, #{module => fixture_page}} || {R, H, _} <- Routes]),
    %% Only the four fixed system routes remain.
    4 = length(Routes).

%% concrete_sse_handler:init/2 reads the "id" path binding to scope a
%% subscription to one component -- the route must actually carry that
%% binding, or the id is always undefined and every stream ends up on
%% the same (wrong) channel.
sse_route_carries_an_id_binding(_Config) ->
    Routes = concrete_router:routes([]),
    {"/concrete/sse/:id", concrete_sse_handler, _} =
        lists:keyfind(concrete_sse_handler, 2, Routes),
    %% cowboy's own router is the real authority on path-segment syntax;
    %% round-trip a request through it and confirm "id" resolves for a
    %% concrete path.
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    {ok, #{bindings := #{id := <<"widget-1">>}},
         #{handler := concrete_sse_handler}} =
        cowboy_router:execute(
            #{host => <<"localhost">>, path => <<"/concrete/sse/widget-1">>},
            #{dispatch => Dispatch}).

system_routes_present(_Config) ->
    Routes = concrete_router:routes([]),
    true = lists:keymember(concrete_command_handler, 2, Routes),
    true = lists:keymember(concrete_ws_handler, 2, Routes),
    true = lists:keymember(concrete_asset_handler, 2, Routes).
