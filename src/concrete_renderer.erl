%% Server-side HTML renderer. Walks the DOM AST produced by
%% concrete_template_parser and evaluates {expr, _} nodes against the
%% component's state via erl_eval, with CONCRETE_STATE bound to the
%% state map. Evaluated values are HTML-escaped; static template text
%% is emitted verbatim.
-module(concrete_renderer).

-export([render_page/2, render_nodes/2, render_node/2, wrap_in_layout/2]).

-spec render_page(module(), map()) -> {iodata(), binary(), map()}.
render_page(PageModule, Params) ->
    _ = code:ensure_loaded(PageModule),
    {Component, Server} = case erlang:function_exported(PageModule, init, 2) of
        true  -> PageModule:init(Params, #{});
        false -> {#{state => #{}}, #{}}
    end,
    HTML = render_nodes(template_dom(PageModule), Component),
    StateJSON = encode_state(Component),
    {HTML, StateJSON, Server}.

%% Wraps already-rendered page/mount HTML in the page's declared layout,
%% substituting the layout template's <slot /> node with it verbatim
%% (not HTML-escaped -- it's markup, not an expression value). Pages
%% without a {layout, Module} (or {layout, Module, Props}) entry in
%% their -concrete(...) attribute are returned unchanged.
-spec wrap_in_layout(module(), iodata()) -> iodata().
wrap_in_layout(PageModule, MountHTML) ->
    case layout_for(PageModule) of
        undefined ->
            MountHTML;
        {LayoutModule, Props} ->
            _ = code:ensure_loaded(LayoutModule),
            {LayoutComponent, _Server} = case erlang:function_exported(LayoutModule, init, 2) of
                true  -> LayoutModule:init(Props, #{});
                false -> {#{state => #{}}, #{}}
            end,
            render_nodes(template_dom(LayoutModule), LayoutComponent, MountHTML)
    end.

%% Reads {layout, Module} / {layout, Module, Props} out of the page
%% module's -concrete([...]) attribute, mirroring how concrete_router
%% reads {route, Path} out of the same attribute.
layout_for(Module) ->
    Attrs = Module:module_info(attributes),
    case [V || {concrete, V} <- Attrs] of
        [Opts | _] -> layout_opt(Opts);
        []         -> undefined
    end.

layout_opt(Opts) ->
    case [T || T <- Opts, is_tuple(T), tuple_size(T) >= 2, element(1, T) =:= layout] of
        [{layout, LayoutModule}]       -> {LayoutModule, #{}};
        [{layout, LayoutModule, Props}] -> {LayoutModule, Props};
        [] -> undefined
    end.

%% template/0 returns either {inline, DOM} or a .slab filename.
%% Relative filenames resolve against the templates_dir app env
%% (default "priv/templates").
template_dom(Module) ->
    case Module:template() of
        {inline, DOM} -> DOM;
        File          -> concrete_template_parser:parse_file(template_path(File))
    end.

template_path(File) ->
    case filename:pathtype(File) of
        absolute -> File;
        _ ->
            Dir = application:get_env(concrete, templates_dir, "priv/templates"),
            filename:join(Dir, File)
    end.

-spec render_nodes([concrete_template_parser:dom_node()], map()) -> iodata().
render_nodes(Nodes, Component) ->
    render_nodes(Nodes, Component, no_slot).

-spec render_node(concrete_template_parser:dom_node(), map()) -> iodata().
render_node(Node, Component) ->
    render_node(Node, Component, no_slot).

%% SlotContent is the already-rendered HTML a <slot /> node is replaced
%% with -- only meaningful while rendering a layout template via
%% wrap_in_layout/2. Elsewhere (plain pages/components) it's `no_slot`,
%% and a stray <slot /> is a template error.
render_nodes(Nodes, Component, SlotContent) ->
    [render_node(N, Component, SlotContent) || N <- Nodes].

render_node({element, Tag, Attrs, Children}, Component, SlotContent) ->
    RenderedAttrs = [render_attr(A, Component) || A <- Attrs],
    case concrete_template_parser:is_void_element(Tag) of
        true ->
            [<<"<">>, Tag, RenderedAttrs, <<">">>];
        false ->
            [<<"<">>, Tag, RenderedAttrs, <<">">>,
             render_nodes(Children, Component, SlotContent),
             <<"</">>, Tag, <<">">>]
    end;
render_node({text, Text}, _Component, _SlotContent) ->
    Text;
render_node({expr, AST}, Component, _SlotContent) ->
    escape(term_to_iodata(eval_expr(AST, Component)));
render_node({component, Module, Props}, Component, _SlotContent) ->
    ResolvedProps = resolve_props(Props, Component),
    {Child, _Server} = Module:init(ResolvedProps, #{}),
    render_nodes(template_dom(Module), Child);
render_node(slot, _Component, no_slot) ->
    error({render_error, slot_outside_layout});
render_node(slot, _Component, SlotContent) ->
    SlotContent.

render_attr({Name, {expr, AST}}, Component) ->
    Val = escape(term_to_iodata(eval_expr(AST, Component))),
    [<<" ">>, Name, <<"=\"">>, Val, <<"\"">>];
render_attr({Name, Value}, _Component) ->
    [<<" ">>, Name, <<"=\"">>, Value, <<"\"">>].

resolve_props(Props, Component) ->
    maps:from_list([{K, eval_prop(V, Component)} || {K, V} <- Props]).

eval_prop({expr, AST}, Component) -> eval_expr(AST, Component);
eval_prop(Val, _Component)        -> Val.

eval_expr(AST, Component) ->
    State = maps:get(state, Component, #{}),
    Bindings = erl_eval:add_binding('CONCRETE_STATE', State, erl_eval:new_bindings()),
    {value, Val, _} = erl_eval:expr(AST, Bindings),
    Val.

term_to_iodata(V) when is_binary(V)  -> V;
term_to_iodata(V) when is_integer(V) -> integer_to_binary(V);
term_to_iodata(V) when is_float(V)   -> float_to_binary(V, [{decimals, 10}, compact]);
term_to_iodata(V) when is_atom(V)    -> atom_to_binary(V);
term_to_iodata(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

escape(IoData) ->
    Bin = iolist_to_binary(IoData),
    << <<(escape_char(C))/binary>> || <<C>> <= Bin >>.

escape_char($&) -> <<"&amp;">>;
escape_char($<) -> <<"&lt;">>;
escape_char($>) -> <<"&gt;">>;
escape_char($") -> <<"&quot;">>;
escape_char(C)  -> <<C>>.

encode_state(State) ->
    thoas:encode(concrete_serializer:encode(State)).
