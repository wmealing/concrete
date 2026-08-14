%% Test fixture for client_SUITE: a page that re-renders itself (via its
%% own action/3) while embedding a single unkeyed <:component>, to prove
%% the child's instance -- and therefore its own accumulated state --
%% survives across the parent's re-renders instead of being reinitialized
%% from scratch every time.
-module(fixture_singleton_parent).
-behaviour(concrete_page).
-export([init/2, action/3, template/0]).

init(_Props, Server) ->
    {#{state => #{ticks => 0}}, Server}.

action(tick, _Params, #{state := #{ticks := N} = S} = C) ->
    C#{state => S#{ticks => N + 1}}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<div>{@ticks}<:component module={fixture_stateful_child} id=\"only\" /></div>")}.
