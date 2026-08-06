%% Test fixture: embeds fixture_badge, and is itself embedded by
%% fixture_dashboard -- makes fixture_badge reachable only
%% transitively, to exercise discover_modules/2's recursion.
-module(fixture_widget).
-export([init/2, template/0]).

init(_Props, Server) ->
    {#{state => #{n => 2}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<:component module={fixture_badge} score={@n} />")}.
