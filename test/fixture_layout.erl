%% Test fixture: a layout component wrapping fixture_layout_page.
-module(fixture_layout).
-export([init/2, template/0]).

init(Props, Server) ->
    {#{state => #{title => maps:get(title, Props, <<"Default">>)}}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<html><head><title>{@title}</title></head>"
        "<body><slot /></body></html>")}.
