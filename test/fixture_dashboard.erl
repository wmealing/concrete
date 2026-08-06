%% Test fixture: embeds fixture_widget, which embeds fixture_badge --
%% see fixture_widget.erl.
-module(fixture_dashboard).
-export([init/2, template/0]).

init(_Props, Server) ->
    {#{state => #{}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<div><:component module={fixture_widget} /></div>")}.
