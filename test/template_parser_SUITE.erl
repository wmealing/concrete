%% Phase 3: Template parser tests.
-module(template_parser_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    parse_text_node/1,
    parse_element/1,
    parse_element_with_attrs/1,
    parse_state_interpolation/1,
    parse_nested_elements/1,
    parse_component_tag/1,
    parse_empty_element/1,
    parse_void_element_without_slash/1,
    parse_event_and_bare_attrs/1,
    parse_expr_attr/1,
    parse_expr_arithmetic/1,
    parse_mixed_content/1,
    parse_component_string_prop/1,
    parse_multiline_template/1,
    parse_slot_tag/1,
    compile_render_fun_js/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [parse_text_node,
     parse_element,
     parse_element_with_attrs,
     parse_state_interpolation,
     parse_nested_elements,
     parse_component_tag,
     parse_empty_element,
     parse_void_element_without_slash,
     parse_event_and_bare_attrs,
     parse_expr_attr,
     parse_expr_arithmetic,
     parse_mixed_content,
     parse_component_string_prop,
     parse_multiline_template,
     parse_slot_tag,
     compile_render_fun_js]}].
parse_text_node(_Config) ->
    [{text, <<"hello">>}] = parse("hello").

parse_element(_Config) ->
    [{element, <<"div">>, [], []}] = parse("<div></div>").

parse_element_with_attrs(_Config) ->
    [{element, <<"div">>, [{<<"class">>, <<"box">>}], []}] =
        parse("<div class=\"box\"></div>").

parse_state_interpolation(_Config) ->
    [{element, <<"p">>, [], [{expr, AST}]}] = parse("<p>{@count}</p>"),
    %% @count rewrites to maps:get(count, CONCRETE_STATE)
    {call, _, {remote, _, {atom, _, maps}, {atom, _, get}},
     [{atom, _, count}, {var, _, 'CONCRETE_STATE'}]} = AST.

parse_nested_elements(_Config) ->
    [{element, <<"div">>, [],
      [{element, <<"span">>, [], [{text, <<"hi">>}]}]}] =
        parse("<div><span>hi</span></div>").

parse_component_tag(_Config) ->
    [{component, counter, [{initial_value, {expr, {integer, _, 0}}}]}] =
        parse("<:component module={counter} initial_value={0} />").

parse_empty_element(_Config) ->
    [{element, <<"br">>, [], []}] = parse("<br/>").

parse_void_element_without_slash(_Config) ->
    [{element, <<"br">>, [], []}, {text, <<"x">>}] = parse("<br>x").

parse_event_and_bare_attrs(_Config) ->
    [{element, <<"button">>,
      [{<<"concrete-click">>, <<"increment">>}, {<<"disabled">>, <<>>}],
      [{text, <<"+">>}]}] =
        parse("<button concrete-click=\"increment\" disabled>+</button>").

parse_expr_attr(_Config) ->
    [{element, <<"div">>, [{<<"data-count">>, {expr, _}}], []}] =
        parse("<div data-count={@count}></div>").

parse_expr_arithmetic(_Config) ->
    [{expr, {op, _, '+', _, {integer, _, 1}}}] = parse("{@count + 1}").

parse_mixed_content(_Config) ->
    [{text, <<"a">>}, {expr, _}, {text, <<"b">>}] = parse("a{@x}b").

parse_component_string_prop(_Config) ->
    [{component, badge, [{label, <<"hi">>}]}] =
        parse("<:component module={badge} label=\"hi\" />").

parse_multiline_template(_Config) ->
    Nodes = parse("<div class=\"counter\">\n"
                  "  <p>Count: {@count}</p>\n"
                  "  <button concrete-click=\"increment\">+</button>\n"
                  "</div>"),
    [{element, <<"div">>, [{<<"class">>, <<"counter">>}], Children}] = Nodes,
    [{text, _},
     {element, <<"p">>, [], [{text, <<"Count: ">>}, {expr, _}]},
     {text, _},
     {element, <<"button">>, [{<<"concrete-click">>, <<"increment">>}], [{text, <<"+">>}]},
     {text, _}] = Children.

parse_slot_tag(_Config) ->
    [{element, <<"body">>, [], [slot]}] = parse("<body><slot /></body>"),
    [slot] = parse("<slot/>").

compile_render_fun_js(_Config) ->
    Nodes  = parse("<p>{@count}</p>"),
    FunDef = concrete_template_parser:compile_render_fun(Nodes),
    JS = iolist_to_binary(concrete_encoder:encode_function_def(page, FunDef)),
    {_, _} = binary:match(JS, <<"defineErlangFunction(\"page\", \"render\", 1">>),
    {_, _} = binary:match(JS, <<"Erlang[\"maps:get/2\"](Type.atom(\"count\"), bindings[\"CONCRETE_STATE\"])">>),
    {_, _} = binary:match(JS, <<"Type.bitstring(\"p\")">>).

parse(Input) ->
    concrete_template_parser:parse_string(Input).
