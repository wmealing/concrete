%% Test fixture: a page module declaring a layout via -concrete(...).
-module(fixture_layout_page).
-behaviour(concrete_page).
-concrete([{route, "/layout-demo"}, {layout, fixture_layout, #{title => <<"Demo">>}}]).
-export([init/2, template/0]).

init(_Params, Server) ->
    {#{state => #{}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string("<p>page content</p>")}.
