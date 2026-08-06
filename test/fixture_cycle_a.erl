%% Test fixture: embeds fixture_cycle_b, which embeds this module back --
%% used to prove rebar_compiler_concrete:discover_modules/2 terminates
%% on a component reference cycle instead of looping forever.
-module(fixture_cycle_a).
-export([init/2, template/0]).

init(_Props, Server) ->
    {#{state => #{}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<:component module={fixture_cycle_b} />")}.
