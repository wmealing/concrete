%% Test fixture for client_SUITE: a component with its own action/3 and
%% mount/2, embedded via <:component> to exercise persistent per-instance
%% state (ComponentInstances) and mount timing.
-module(fixture_stateful_child).
-behaviour(concrete_component).
-export([init/2, action/3, mount/2, template/0]).

init(Props, Server) ->
    State = #{id => maps:get(id, Props, <<"">>), count => 0},
    {#{state => State}, Server}.

action(bump, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count => N + 1}}.

mount(_Props, _Component) ->
    ok.

template() ->
    {inline, concrete_template_parser:parse_string("<span>{@id}:{@count}</span>")}.
