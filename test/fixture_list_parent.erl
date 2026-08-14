%% Test fixture for client_SUITE: a page that renders a keyed, dynamic
%% list of <:component> children via <:for>, to exercise the loop
%% construct end to end -- compiled through concrete_encoder, executed
%% in the JS runtime -- together with per-iteration component identity
%% (each iteration's <:component> shares one compile-time path index,
%% disambiguated only by key={Item}, exactly the case the component-
%% mount plan requires an explicit key for).
-module(fixture_list_parent).
-behaviour(concrete_page).
-export([init/2, action/3, template/0]).

init(Props, Server) ->
    Items = maps:get(items, Props, [<<"a">>, <<"b">>, <<"c">>]),
    {#{state => #{items => Items}}, Server}.

action(set_items, Params, #{state := S} = C) ->
    C#{state => S#{items => maps:get(items, Params)}}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<ul><:for item=\"Item\" in={@items}>"
        "<:component module={fixture_stateful_child} key={Item} id={Item} />"
        "</:for></ul>")}.
