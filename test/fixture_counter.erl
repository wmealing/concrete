%% Test fixture for client_SUITE: a component with a client-side action.
%% Its whole module is compiled to JS from the BEAM and driven by
%% client.js in Node.
-module(fixture_counter).
-export([init/2, template/0, action/3]).

init(Props, Server) ->
    State = #{label => maps:get(label, Props, <<"clicks">>),
              count => 0},
    {#{state => State}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<p>{@label}: {@count}</p>"
        "<button concrete-click=\"increment\">+</button>")}.

action(increment, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count := N + 1}}.
