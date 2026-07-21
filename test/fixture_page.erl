%% Test fixture: a page module rendered by renderer_SUITE.
%% Its .slab template lives in renderer_SUITE_data/ — the suite points
%% the templates_dir app env there.
-module(fixture_page).
-export([init/2, template/0]).

init(Params, Server) ->
    Name = maps:get(name, Params, <<"world">>),
    {#{state => #{name => Name, n => 3}}, Server}.

template() ->
    "fixture_page.slab".
