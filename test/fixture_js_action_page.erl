%% Test fixture: a page whose action/3 calls ?js:call/concrete_js:call --
%% used by rebar_compiler_concrete_SUITE to prove the real PLT-population
%% pipeline (populate_plt/2) never traces concrete_js's own body into the
%% PLT, even though concrete_js is genuinely reachable from action/3.
-module(fixture_js_action_page).
-export([init/2, template/0, action/3]).
-include_lib("concrete/include/concrete_js.hrl").

init(_Params, Server) ->
    {#{state => #{}}, Server}.

template() ->
    {inline, []}.

action(ping, _Params, C) ->
    ?js:call(<<"console.log">>, [<<"ping">>]),
    C.
