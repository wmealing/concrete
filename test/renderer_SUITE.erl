%% Phase 3: Server-side renderer tests.
-module(renderer_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    render_text/1,
    render_element_with_attrs/1,
    render_state_expr/1,
    render_expr_arithmetic/1,
    render_expr_attr/1,
    render_escapes_values/1,
    render_void_element/1,
    render_component/1,
    render_for_loop/1,
    render_for_loop_keeps_state_visible/1,
    render_page_from_file/1,
    render_wrap_in_layout/1,
    render_no_layout_passthrough/1,
    render_slot_outside_layout_errors/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [render_text,
     render_element_with_attrs,
     render_state_expr,
     render_expr_arithmetic,
     render_expr_attr,
     render_escapes_values,
     render_void_element,
     render_component,
     render_for_loop,
     render_for_loop_keeps_state_visible,
     render_page_from_file,
     render_wrap_in_layout,
     render_no_layout_passthrough,
     render_slot_outside_layout_errors]}].
init_per_suite(Config) ->
    %% fixture_page:template() returns a relative filename; resolve it
    %% against this suite's data dir.
    DataDir = ?config(data_dir, Config),
    application:set_env(concrete, templates_dir, DataDir),
    Config.

end_per_suite(_Config) ->
    application:unset_env(concrete, templates_dir),
    ok.

render_text(_Config) ->
    <<"hello">> = render("hello", #{}).

render_element_with_attrs(_Config) ->
    <<"<div class=\"box\">hi</div>">> =
        render("<div class=\"box\">hi</div>", #{}).

render_state_expr(_Config) ->
    <<"<p>42</p>">> = render("<p>{@count}</p>", #{count => 42}).

render_expr_arithmetic(_Config) ->
    <<"<p>43</p>">> = render("<p>{@count + 1}</p>", #{count => 42}).

render_expr_attr(_Config) ->
    <<"<div data-n=\"7\"></div>">> =
        render("<div data-n={@n}></div>", #{n => 7}).

render_escapes_values(_Config) ->
    %% evaluated values are escaped; static template text is not
    <<"<p>&lt;b&gt;&amp;</p>">> =
        render("<p>{@html}</p>", #{html => <<"<b>&">>}).

render_void_element(_Config) ->
    <<"a<br>b">> = render("a<br>b", #{}).

render_component(_Config) ->
    <<"<span class=\"badge\">50</span>">> =
        render("<:component module={fixture_badge} score={@n} />", #{n => 5}).

render_for_loop(_Config) ->
    <<"<li>a</li><li>b</li><li>c</li>">> =
        render("<:for item=\"X\" in={@items}><li>{X}</li></:for>",
               #{items => [<<"a">>, <<"b">>, <<"c">>]}).

%% A loop body can read @state fields alongside its own loop variable --
%% ExtraBindings adds to erl_eval's bindings, it doesn't replace them.
render_for_loop_keeps_state_visible(_Config) ->
    <<"<li>x:1</li><li>x:2</li>">> =
        render("<:for item=\"N\" in={@ns}><li>{@label}:{N}</li></:for>",
               #{ns => [1, 2], label => <<"x">>}).

render_page_from_file(_Config) ->
    {HTML, StateJSON, _Server} = concrete_renderer:render_page(fixture_page, #{}),
    Bin = iolist_to_binary(HTML),
    <<"<div class=\"page\"><h1>Hello world</h1>"
      "<span class=\"badge\">30</span></div>\n">> = Bin,
    %% hydration payload is type-tagged wire JSON of the component map
    {_, _} = binary:match(StateJSON, <<"\"type\":\"map\"">>),
    {_, _} = binary:match(StateJSON, <<"\"value\":\"name\"">>).

render_wrap_in_layout(_Config) ->
    {HTML, _StateJSON, _Server} = concrete_renderer:render_page(fixture_layout_page, #{}),
    Wrapped = iolist_to_binary(concrete_renderer:wrap_in_layout(fixture_layout_page, HTML)),
    <<"<html><head><title>Demo</title></head><body><p>page content</p></body></html>">> =
        Wrapped.

render_no_layout_passthrough(_Config) ->
    {HTML, _StateJSON, _Server} = concrete_renderer:render_page(fixture_page, #{}),
    Bin = iolist_to_binary(HTML),
    Bin = iolist_to_binary(concrete_renderer:wrap_in_layout(fixture_page, HTML)).

render_slot_outside_layout_errors(_Config) ->
    Nodes = concrete_template_parser:parse_string("<slot/>"),
    try
        concrete_renderer:render_nodes(Nodes, #{state => #{}}),
        error(should_have_raised)
    catch
        error:{render_error, slot_outside_layout} -> ok
    end.

render(Template, StateMap) ->
    Nodes = concrete_template_parser:parse_string(Template),
    iolist_to_binary(concrete_renderer:render_nodes(Nodes, #{state => StateMap})).
