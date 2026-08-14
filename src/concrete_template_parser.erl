%% Parses .slab template files into a DOM AST.
%%
%% Syntax:
%%   <div class="box">text</div>          elements + static attributes
%%   {@name}                              state interpolation
%%   {Expr}                               any Erlang expression; @name inside
%%                                        it reads from component state
%%   <button concrete-click="incr">       event attributes pass through
%%   <:component module={mod} k={v} />    embedded child component
%%   <:component module={mod} key={k} />  keyed instance (list-rendered components)
%%   <:for item="X" in={@items}>...</:for>  repeat body once per list element,
%%                                          binding the Erlang variable named
%%                                          by `item` (e.g. {X}) inside it
%%   <slot />                             layout placeholder for page/child content
%%
%% `@name` is rewritten to `maps:get(name, CONCRETE_STATE)` before the
%% expression is parsed with erl_scan/erl_parse. The server renderer and
%% the compiled client render function both bind CONCRETE_STATE to the
%% component's state map.
%%
%% Known v1 limitations: a literal `{` in text must be written as an
%% expression ({<<"{">>}), and `@word` sequences inside string literals
%% within expressions are also rewritten.
%% Tells concrete_beam_reader:extract_ir/1 to refuse to trace into this
%% module. It's compiler-internal code -- a hand-rolled recursive-descent
%% parser full of raw character-literal patterns concrete_transformer/
%% concrete_encoder were never written to handle -- never meant to run
%% client-side. Without this tag, a template/0 using the documented
%% {inline, concrete_template_parser:parse_string(...)} pattern makes
%% this module a real call-graph compile root the moment its layout/page
%% is actually reachable, and the encoder chokes on its own source.
-module(concrete_template_parser).
-include("concrete_ir.hrl").
-concrete([{compiler_internal, true}]).

-export([parse_file/1, parse_string/1, compile_render_fun/1, is_void_element/1,
         component_modules/1]).

-type dom_node() ::
    {element, binary(), [attr()], [dom_node()]}
  | {text, binary()}
  | {expr, erl_parse:abstract_expr()}
  | {component, module(), key(), [{atom(), binary() | {expr, erl_parse:abstract_expr()}}]}
  | {for, atom(), erl_parse:abstract_expr(), [dom_node()]}
  | slot.

-type attr() :: {binary(), binary() | {expr, erl_parse:abstract_expr()}}.

%% `undefined` means the tag had no `key` prop -- the singleton case.
-type key() :: undefined | binary() | {expr, erl_parse:abstract_expr()}.

-export_type([dom_node/0, attr/0]).

-spec parse_file(file:filename()) -> [dom_node()].
parse_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    parse_string(Bin).

-spec parse_string(string() | binary()) -> [dom_node()].
parse_string(Input) when is_binary(Input) ->
    parse_string(unicode:characters_to_list(Input));
parse_string(Input) ->
    case parse_nodes(Input, []) of
        {Nodes, []}   -> Nodes;
        {_Nodes, Rest} -> error({parse_error, {unexpected_input, Rest}})
    end.

%% --- Node parsing ---

parse_nodes([], Acc) ->
    {lists:reverse(Acc), []};
parse_nodes("</" ++ _ = Cs, Acc) ->
    {lists:reverse(Acc), Cs};
parse_nodes("<:component" ++ Cs, Acc) ->
    {Node, Rest} = parse_component(Cs),
    parse_nodes(Rest, [Node | Acc]);
parse_nodes("<:for" ++ Cs, Acc) ->
    {Node, Rest} = parse_for(Cs),
    parse_nodes(Rest, [Node | Acc]);
parse_nodes("<slot" ++ Cs, Acc) when hd(Cs) =:= $\s; hd(Cs) =:= $/ ->
    Rest = parse_slot(Cs),
    parse_nodes(Rest, [slot | Acc]);
parse_nodes("<" ++ Cs, Acc) ->
    {Node, Rest} = parse_element(Cs),
    parse_nodes(Rest, [Node | Acc]);
parse_nodes("{" ++ Cs, Acc) ->
    {AST, Rest} = take_expr(Cs),
    parse_nodes(Rest, [{expr, AST} | Acc]);
parse_nodes(Cs, Acc) ->
    {Text, Rest} = take_text(Cs, []),
    parse_nodes(Rest, [{text, unicode:characters_to_binary(Text)} | Acc]).

take_text([C | _] = Cs, Acc) when C =:= $<; C =:= ${ ->
    {lists:reverse(Acc), Cs};
take_text([C | Cs], Acc) ->
    take_text(Cs, [C | Acc]);
take_text([], Acc) ->
    {lists:reverse(Acc), []}.

%% --- Elements ---

parse_element(Cs) ->
    {Tag, Cs1} = take_name(Cs, []),
    Tag =/= [] orelse error({parse_error, {bad_tag, Cs}}),
    {Attrs, Cs2} = parse_attrs(Cs1, []),
    TagBin = unicode:characters_to_binary(Tag),
    case Cs2 of
        "/>" ++ Rest ->
            {{element, TagBin, Attrs, []}, Rest};
        ">" ++ Rest ->
            case is_void_element(TagBin) of
                true ->
                    {{element, TagBin, Attrs, []}, Rest};
                false ->
                    {Children, Rest1} = parse_nodes(Rest, []),
                    Rest2 = expect_close(Rest1, Tag),
                    {{element, TagBin, Attrs, Children}, Rest2}
            end;
        _ ->
            error({parse_error, {expected_tag_end, Cs2}})
    end.

expect_close("</" ++ Cs, Tag) ->
    {Name, Cs1} = take_name(Cs, []),
    Name =:= Tag orelse error({parse_error, {mismatched_close_tag, Tag, Name}}),
    case skip_ws(Cs1) of
        ">" ++ Rest -> Rest;
        Other       -> error({parse_error, {expected_close_bracket, Other}})
    end;
expect_close(Cs, Tag) ->
    error({parse_error, {missing_close_tag, Tag, Cs}}).

%% HTML void elements have no closing tag and no children.
-spec is_void_element(binary()) -> boolean().
is_void_element(Tag) ->
    lists:member(Tag, [<<"area">>, <<"base">>, <<"br">>, <<"col">>,
                       <<"embed">>, <<"hr">>, <<"img">>, <<"input">>,
                       <<"link">>, <<"meta">>, <<"param">>, <<"source">>,
                       <<"track">>, <<"wbr">>]).

%% --- Attributes ---

parse_attrs(Cs0, Acc) ->
    case skip_ws(Cs0) of
        "/>" ++ _ = Cs -> {lists:reverse(Acc), Cs};
        ">" ++ _ = Cs  -> {lists:reverse(Acc), Cs};
        []             -> error({parse_error, unexpected_eof_in_tag});
        Cs ->
            {Name, Cs1} = take_name(Cs, []),
            Name =/= [] orelse error({parse_error, {bad_attribute, Cs}}),
            NameBin = unicode:characters_to_binary(Name),
            case Cs1 of
                "=\"" ++ Cs2 ->
                    {Val, Cs3} = take_quoted(Cs2, []),
                    parse_attrs(Cs3, [{NameBin, unicode:characters_to_binary(Val)} | Acc]);
                "={" ++ Cs2 ->
                    {AST, Cs3} = take_expr(Cs2),
                    parse_attrs(Cs3, [{NameBin, {expr, AST}} | Acc]);
                _ ->
                    %% bare attribute (e.g. disabled)
                    parse_attrs(Cs1, [{NameBin, <<>>} | Acc])
            end
    end.

take_quoted([$" | Cs], Acc) -> {lists:reverse(Acc), Cs};
take_quoted([C | Cs], Acc)  -> take_quoted(Cs, [C | Acc]);
take_quoted([], _Acc)       -> error({parse_error, unterminated_attribute}).

%% --- Slots ---

%% <slot /> is self-closing only; it carries no attributes or children.
parse_slot(Cs) ->
    case skip_ws(Cs) of
        "/>" ++ Rest -> Rest;
        Other        -> error({parse_error, {slot_must_be_self_closing, Other}})
    end.

%% --- Components ---

%% `module` and `key` are reserved props: identity/routing metadata,
%% not part of the child's own Props map -- both stripped out here
%% before what's left is treated as ordinary props, same handling.
parse_component(Cs) ->
    {Attrs, Cs1} = parse_attrs(Cs, []),
    Rest = case Cs1 of
        "/>" ++ R -> R;
        Other     -> error({parse_error, {component_must_be_self_closing, Other}})
    end,
    Props0 = [{binary_to_atom(N), V} || {N, V} <- Attrs],
    case lists:keytake(module, 1, Props0) of
        {value, {module, ModVal}, Props1} ->
            {KeyVal, Props} = case lists:keytake(key, 1, Props1) of
                {value, {key, KV}, P} -> {KV, P};
                false                 -> {undefined, Props1}
            end,
            {{component, module_value(ModVal), KeyVal, Props}, Rest};
        false ->
            error({parse_error, component_missing_module})
    end.

module_value({expr, {atom, _, M}})   -> M;
module_value(Bin) when is_binary(Bin) -> binary_to_atom(Bin);
module_value(Other)                   -> error({parse_error, {bad_module_prop, Other}}).

%% --- Loops ---

%% <:for item="X" in={ListExpr}>Body</:for> -- repeats Body once per
%% element of ListExpr, evaluated once (not per iteration); `item`
%% names the Erlang variable (a literal identifier, not an expression --
%% it's a binding site, not a value) that Body's own {X} expressions
%% read the current element from. Always a block form (no self-closing
%% shorthand -- an empty loop body is never useful) so parsing continues
%% into ordinary parse_nodes/2 for the children, then expects the
%% matching </:for>.
parse_for(Cs) ->
    {Attrs, Cs1} = parse_attrs(Cs, []),
    case Cs1 of
        ">" ++ Rest0 ->
            ItemVar = for_item_var(Attrs),
            ListAST = for_in_expr(Attrs),
            {Children, Rest1} = parse_nodes(Rest0, []),
            Rest2 = expect_close_for(Rest1),
            {{for, ItemVar, ListAST, Children}, Rest2};
        "/>" ++ _ ->
            error({parse_error, for_requires_body})
    end.

for_item_var(Attrs) ->
    case lists:keyfind(<<"item">>, 1, Attrs) of
        {<<"item">>, Bin} when is_binary(Bin) -> binary_to_atom(Bin);
        {<<"item">>, _}                       -> error({parse_error, for_item_must_be_literal});
        false                                 -> error({parse_error, for_missing_item})
    end.

for_in_expr(Attrs) ->
    case lists:keyfind(<<"in">>, 1, Attrs) of
        {<<"in">>, {expr, AST}} -> AST;
        {<<"in">>, _}           -> error({parse_error, for_in_must_be_expr});
        false                   -> error({parse_error, for_missing_in})
    end.

expect_close_for("</:for" ++ Cs) ->
    case skip_ws(Cs) of
        ">" ++ Rest -> Rest;
        Other       -> error({parse_error, {expected_close_bracket, Other}})
    end;
expect_close_for(Cs) ->
    error({parse_error, {missing_close_tag, 'for', Cs}}).

%% --- Expressions ---

%% Called just past the opening brace; consumes up to the matching close
%% brace (brace-depth aware, skips string literals) and parses the
%% contents as one Erlang expression.
take_expr(Cs) ->
    {ExprStr, Rest} = take_balanced(Cs, [], 0),
    {parse_erlang_expr(ExprStr), Rest}.

take_balanced([$} | Cs], Acc, 0) -> {lists:reverse(Acc), Cs};
take_balanced([$} | Cs], Acc, D) -> take_balanced(Cs, [$} | Acc], D - 1);
take_balanced([${ | Cs], Acc, D) -> take_balanced(Cs, [${ | Acc], D + 1);
take_balanced([$" | Cs], Acc, D) ->
    {Acc1, Rest} = take_literal(Cs, [$" | Acc], $"),
    take_balanced(Rest, Acc1, D);
take_balanced([$' | Cs], Acc, D) ->
    {Acc1, Rest} = take_literal(Cs, [$' | Acc], $'),
    take_balanced(Rest, Acc1, D);
take_balanced([C | Cs], Acc, D) -> take_balanced(Cs, [C | Acc], D);
take_balanced([], _Acc, _D)     -> error({parse_error, unterminated_expression}).

take_literal([$\\, C | Cs], Acc, Q) -> take_literal(Cs, [C, $\\ | Acc], Q);
take_literal([Q | Cs], Acc, Q)      -> {[Q | Acc], Cs};
take_literal([C | Cs], Acc, Q)      -> take_literal(Cs, [C | Acc], Q);
take_literal([], _Acc, _Q)          -> error({parse_error, unterminated_string}).

parse_erlang_expr(Str0) ->
    Str = rewrite_state_refs(Str0),
    case erl_scan:string(Str ++ ".") of
        {ok, Tokens, _} ->
            case erl_parse:parse_exprs(Tokens) of
                {ok, [Expr]} -> Expr;
                {ok, _Many}  -> error({parse_error, {multiple_expressions, Str0}});
                {error, E}   -> error({parse_error, {bad_expression, Str0, E}})
            end;
        {error, E, _} ->
            error({parse_error, {bad_expression, Str0, E}})
    end.

%% name -> maps:get(name, CONCRETE_STATE)
rewrite_state_refs(Str) ->
    re:replace(Str, "@([a-z][a-zA-Z0-9_]*)", "maps:get(\\1, CONCRETE_STATE)",
               [global, {return, list}]).

%% Every module directly embedded via <:component> anywhere in a DOM
%% tree (recursing into element children; a component tag itself has no
%% children in this syntax, so this does not walk into a component's
%% own template -- the caller does that separately, one module's DOM
%% at a time, to also catch components embedded transitively).
-spec component_modules([dom_node()]) -> [module()].
component_modules(Nodes) ->
    lists:usort(component_modules(Nodes, [])).

component_modules([], Acc) ->
    Acc;
component_modules([{component, Module, _Key, _Props} | Rest], Acc) ->
    component_modules(Rest, [Module | Acc]);
component_modules([{element, _Tag, _Attrs, Children} | Rest], Acc) ->
    component_modules(Rest, component_modules(Children, Acc));
component_modules([{for, _Var, _ListAST, Children} | Rest], Acc) ->
    component_modules(Rest, component_modules(Children, Acc));
component_modules([_ | Rest], Acc) ->
    component_modules(Rest, Acc).

%% --- Client-side adapter ---

%% Compiles a parsed DOM AST into an IR render/1 function definition.
%% The generated function takes CONCRETE_STATE (the component state map)
%% and rebuilds the DOM AST as Erlang terms in the browser, with all
%% {expr, _} nodes evaluated. Encode it with
%% concrete_encoder:encode_function_def(Module, FunDef).
-spec compile_render_fun([dom_node()]) -> #ir_function_def{}.
compile_render_fun(Nodes) ->
    {IR, _NextPathIndex} = dom_ir_list(Nodes, 0),
    #ir_function_def{
        name   = render,
        arity  = 1,
        clauses = [#ir_clause{
            patterns = [#ir_variable{name = 'CONCRETE_STATE'}],
            guards   = [],
            body     = [IR]
        }]
    }.

%% PathIndex is a depth-first counter over <:component> occurrences
%% only, assigned once here at compile time (the template is fixed
%% across renders, so the same tag always gets the same index) --
%% baked into the compiled DOM as a literal integer, alongside the
%% explicit `key` (if any), so the client runtime can tell "same call
%% site, evaluated again" apart from "different call site" without
%% re-deriving tree position at runtime.
dom_ir_list(Nodes, PathIndex0) ->
    {ElementsRev, PathIndexN} =
        lists:foldl(fun(N, {Acc, PI0}) ->
            {IR, PI1} = dom_ir(N, PI0),
            {[IR | Acc], PI1}
        end, {[], PathIndex0}, Nodes),
    {#ir_list{elements = lists:reverse(ElementsRev), tail = nil}, PathIndexN}.

dom_ir({text, Bin}, PathIndex) ->
    {#ir_tuple{elements = [#ir_atom{value = text}, #ir_string{value = Bin}]}, PathIndex};
dom_ir({expr, AST}, PathIndex) ->
    {#ir_tuple{elements = [#ir_atom{value = expr}, expr_ir(AST)]}, PathIndex};
dom_ir({element, Tag, Attrs, Children}, PathIndex0) ->
    {ChildrenIR, PathIndex1} = dom_ir_list(Children, PathIndex0),
    {#ir_tuple{elements = [
        #ir_atom{value = element},
        #ir_string{value = Tag},
        #ir_list{elements = [attr_ir(A) || A <- Attrs], tail = nil},
        ChildrenIR
    ]}, PathIndex1};
dom_ir(slot, PathIndex) ->
    {#ir_tuple{elements = [#ir_atom{value = slot}]}, PathIndex};
%% Body is compiled once, not once per iteration -- every <:component>
%% inside a <:for> body therefore shares a single path index across all
%% iterations of the loop, which is exactly why an explicit `key` (see
%% the component-mount plan) is required to tell those iterations'
%% instances apart; the path index alone can't. At runtime this becomes
%% an ir_lc (list comprehension) whose template is the body's own
%% #ir_list{} -- i.e. a list of per-iteration node-lists, one level more
%% nested than a plain sibling run of nodes. client.js's buildVNode and
%% the server-side renderer both splice a nested list transparently
%% (see resolveComponentDom's sibling comment / concrete_renderer),
%% exactly the same way a <:component>'s own multi-node output already
%% does, so no other encoder or runtime change is needed for this to
%% render correctly.
dom_ir({for, VarName, ListAST, Children}, PathIndex0) ->
    {ChildrenIR, PathIndex1} = dom_ir_list(Children, PathIndex0),
    {#ir_lc{
        template = ChildrenIR,
        qualifiers = [#ir_lc_gen{pattern = #ir_variable{name = VarName}, expr = expr_ir(ListAST)}]
    }, PathIndex1};
dom_ir({component, Module, Key, Props}, PathIndex) ->
    {#ir_tuple{elements = [
        #ir_atom{value = component},
        #ir_atom{value = Module},
        #ir_list{elements = [prop_ir(P) || P <- Props], tail = nil},
        key_ir(Key),
        #ir_integer{value = PathIndex}
    ]}, PathIndex + 1}.

key_ir(undefined)             -> #ir_atom{value = undefined};
key_ir({expr, AST})           -> expr_ir(AST);
key_ir(Bin) when is_binary(Bin) -> #ir_string{value = Bin}.

attr_ir({Name, {expr, AST}}) ->
    #ir_tuple{elements = [#ir_string{value = Name}, expr_ir(AST)]};
attr_ir({Name, Value}) ->
    #ir_tuple{elements = [#ir_string{value = Name}, #ir_string{value = Value}]}.

prop_ir({Key, {expr, AST}}) ->
    #ir_tuple{elements = [#ir_atom{value = Key}, expr_ir(AST)]};
prop_ir({Key, Value}) ->
    #ir_tuple{elements = [#ir_atom{value = Key}, #ir_string{value = Value}]}.

expr_ir(AST) ->
    concrete_transformer:transform_expr(AST, concrete_transformer:new_ctx(template)).

%% --- Lexing helpers ---

%% Tag and attribute names: letters, digits, -, _
take_name([C | Cs], Acc) when (C >= $a andalso C =< $z);
                              (C >= $A andalso C =< $Z);
                              (C >= $0 andalso C =< $9);
                              C =:= $-; C =:= $_ ->
    take_name(Cs, [C | Acc]);
take_name(Cs, Acc) ->
    {lists:reverse(Acc), Cs}.

skip_ws([C | Cs]) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    skip_ws(Cs);
skip_ws(Cs) ->
    Cs.
