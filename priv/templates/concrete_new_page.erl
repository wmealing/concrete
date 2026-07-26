-module({{name}}_page).
-behaviour(concrete_page).
-concrete([{route, "/"}]).
-export([init/2, template/0, action/3]).

init(_Params, Server) ->
    {#{state => #{count => 0}}, Server}.

template() ->
    "page.slab".

%% Compiled to JavaScript and dispatched in the browser by client.js --
%% this clause never runs on the server for button clicks.
action(increment, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count := N + 1}};
action(decrement, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count := N - 1}}.
