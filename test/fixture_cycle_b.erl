%% See fixture_cycle_a.erl.
-module(fixture_cycle_b).
-export([init/2, template/0]).

init(_Props, Server) ->
    {#{state => #{}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<:component module={fixture_cycle_a} />")}.
