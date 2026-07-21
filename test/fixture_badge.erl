%% Test fixture: a child component embedded by fixture_page.
-module(fixture_badge).
-export([init/2, template/0]).

init(Props, Server) ->
    {#{state => #{score => maps:get(score, Props, 0)}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<span class=\"badge\">{@score * 10}</span>")}.
