%% Transforms Erlang erl_parse AST into Concrete IR records.
%%
%% Tagged compiler_internal for the same reason
%% concrete_template_parser is: it's the compiler's own AST walker, not
%% something meant to be called from a compile root, and its own source
%% is not something concrete_encoder can compile into JS.
-module(concrete_transformer).
-include("concrete_ir.hrl").
-concrete([{compiler_internal, true}]).

-export([transform_module/2, transform_expr/2, transform_clause/2, new_ctx/1]).

-record(ctx, {
    module     :: atom(),
    imports    :: [{atom(), non_neg_integer()}],
    in_pattern = false :: boolean()
}).

-spec new_ctx(atom()) -> #ctx{}.
new_ctx(Module) ->
    #ctx{module = Module, imports = []}.

transform_module(Forms, Ctx) ->
    Defs = [transform_form(F, Ctx) || F <- Forms, is_function_form(F)],
    ModName = module_name(Forms),
    #ir_module{name = ModName, definitions = lists:flatten(Defs)}.

-spec transform_form(term(), #ctx{}) -> #ir_function_def{}.
transform_form({function, _L, Name, _Arity, Clauses}, Ctx) ->
    IRClauses = [transform_clause(C, Ctx) || C <- Clauses],
    Arity = length(element(3, hd(Clauses))),
    #ir_function_def{name = Name, arity = Arity, clauses = IRClauses}.

-spec transform_clause(term(), #ctx{}) -> #ir_clause{}.
transform_clause({clause, _L, Patterns, Guards, Body}, Ctx) ->
    #ir_clause{
        patterns   = [transform_expr(P, Ctx#ctx{in_pattern = true}) || P <- Patterns],
        guards     = [[transform_expr(G, Ctx) || G <- Seq] || Seq <- Guards],
        body       = [transform_expr(E, Ctx) || E <- Body],
        param_srcs = [pp_expr(P) || P <- Patterns],
        guard_srcs = [[pp_expr(G) || G <- Seq] || Seq <- Guards]
    }.

%% Renders a single erl_parse expression form back to Erlang source text
%% via OTP's own pretty printer -- used only to build human-readable
%% function_clause diagnostics (see concrete_encoder:encode_clause_blame/1),
%% never for code generation.
pp_expr(Form) ->
    string:trim(iolist_to_binary(erl_pp:expr(Form))).

-spec transform_expr(term(), #ctx{}) -> ir().
transform_expr({atom, _, V}, _Ctx)    -> #ir_atom{value = V};
transform_expr({integer, _, V}, _Ctx) -> #ir_integer{value = V};
transform_expr({float, _, V}, _Ctx)   -> #ir_float{value = V};
transform_expr({string, _, Chars}, _Ctx) ->
    #ir_string{value = list_to_binary(Chars)};
transform_expr({nil, _}, _Ctx)        -> #ir_nil{};
transform_expr({var, _, '_'}, _Ctx)   -> #ir_wildcard{};
transform_expr({var, _, Name}, _Ctx)  -> #ir_variable{name = Name};
transform_expr({tuple, _, Es}, Ctx)   ->
    #ir_tuple{elements = [transform_expr(E, Ctx) || E <- Es]};
transform_expr({cons, _, H, T}, Ctx)  ->
    #ir_cons{head = transform_expr(H, Ctx), tail = transform_expr(T, Ctx)};
transform_expr({match, _, P, E}, Ctx) ->
    #ir_match{
        pattern = transform_expr(P, Ctx#ctx{in_pattern = true}),
        expr    = transform_expr(E, Ctx)
    };
transform_expr({map, _, Assocs}, Ctx) ->
    #ir_map{pairs = [transform_assoc(A, Ctx) || A <- Assocs]};
transform_expr({map, _, Expr, Assocs}, Ctx) ->
    #ir_map_update{map   = transform_expr(Expr, Ctx),
                   pairs = [transform_assoc(A, Ctx) || A <- Assocs]};
transform_expr({'case', _, E, Cls}, Ctx) ->
    #ir_case{expr    = transform_expr(E, Ctx),
             clauses = [transform_clause(C, Ctx) || C <- Cls]};
transform_expr({'if', _, Cls}, Ctx) ->
    #ir_if{clauses = [transform_clause(C, Ctx) || C <- Cls]};
transform_expr({block, _, Exprs}, Ctx) ->
    #ir_block{exprs = [transform_expr(E, Ctx) || E <- Exprs]};
transform_expr({'receive', _, Cls}, Ctx) ->
    #ir_receive{clauses    = [transform_clause(C, Ctx) || C <- Cls],
                after_expr = nil,
                after_body = nil};
transform_expr({'receive', _, Cls, AfterExpr, AfterBody}, Ctx) ->
    #ir_receive{clauses    = [transform_clause(C, Ctx) || C <- Cls],
                after_expr = transform_expr(AfterExpr, Ctx),
                after_body = [transform_expr(E, Ctx) || E <- AfterBody]};
transform_expr({'try', _, Body, OfCls, CatchCls, AfterBody}, Ctx) ->
    #ir_try{body          = [transform_expr(E, Ctx) || E <- Body],
            of_clauses    = [transform_clause(C, Ctx) || C <- OfCls],
            catch_clauses = [transform_catch_clause(C, Ctx) || C <- CatchCls],
            after_body    = [transform_expr(E, Ctx) || E <- AfterBody]};
transform_expr({lc, _, Template, Qualifiers}, Ctx) ->
    #ir_lc{template   = transform_expr(Template, Ctx),
           qualifiers = [transform_qualifier(Q, Ctx) || Q <- Qualifiers]};
transform_expr({bc, _, Template, Qualifiers}, Ctx) ->
    #ir_bc{template   = transform_expr(Template, Ctx),
           qualifiers = [transform_qualifier(Q, Ctx) || Q <- Qualifiers]};
transform_expr({op, _, Op, L, R}, Ctx) ->
    #ir_binop{op = Op, left = transform_expr(L, Ctx), right = transform_expr(R, Ctx)};
transform_expr({op, _, Op, E}, Ctx) ->
    #ir_unop{op = Op, operand = transform_expr(E, Ctx)};
transform_expr({call, _, {remote, _, {atom,_,M}, {atom,_,F}}, Args}, Ctx) ->
    #ir_remote_call{module   = #ir_atom{value = M},
                    function = #ir_atom{value = F},
                    arity    = length(Args),
                    args     = [transform_expr(A, Ctx) || A <- Args]};
transform_expr({call, _, {atom, _, F}, Args}, Ctx) ->
    #ir_local_call{name  = F,
                   arity = length(Args),
                   args  = [transform_expr(A, Ctx) || A <- Args]};
%% Dynamic dispatch: Module:Function(Args) where the module and/or
%% function name is a runtime expression (e.g. a variable holding a
%% callback module atom), not a literal atom pair. Used by gen_server
%% -style generic loops calling back into a callback module. Always
%% treated as non-blocking by the encoder's blocking-set analysis (its
%% target isn't statically known) -- see concrete_encoder.
transform_expr({call, _, {remote, _, ModExpr, FunExpr}, Args}, Ctx) ->
    #ir_dynamic_call{module   = transform_expr(ModExpr, Ctx),
                     function = transform_expr(FunExpr, Ctx),
                     arity    = length(Args),
                     args     = [transform_expr(A, Ctx) || A <- Args]};
transform_expr({call, _, FunExpr, Args}, Ctx) ->
    #ir_anon_call{function = transform_expr(FunExpr, Ctx),
                  args     = [transform_expr(A, Ctx) || A <- Args]};
transform_expr({'fun', _, {clauses, Cls}}, Ctx) ->
    #ir_anon_fun{clauses = [transform_clause(C, Ctx) || C <- Cls],
                 arity   = clause_arity(hd(Cls))};
transform_expr({'fun', _, {function, F, A}}, _Ctx) ->
    #ir_fun_ref{module = current_module, function = F, arity = A};
transform_expr({'fun', _, {function, M, F, A}}, _Ctx) ->
    #ir_fun_ref{module = M, function = F, arity = A};
transform_expr({bin, _, Elements}, Ctx) ->
    case bin_literal(Elements, <<>>) of
        {ok, Bin} -> #ir_string{value = Bin};
        error ->
            #ir_bitstring{segments = [transform_bin_element(E, Ctx) || E <- Elements]}
    end;
transform_expr(Node, _Ctx) ->
    error({unhandled_ast_node, Node}).

%% Literal-only binaries (<<"text">>) become bitstring constants.
bin_literal([], Acc) ->
    {ok, Acc};
bin_literal([{bin_element, _, {string, _, Chars}, default, default} | Rest], Acc) ->
    bin_literal(Rest, <<Acc/binary, (list_to_binary(Chars))/binary>>);
bin_literal([{bin_element, _, {integer, _, Int}, default, default} | Rest], Acc)
  when Int >= 0, Int =< 255 ->
    bin_literal(Rest, <<Acc/binary, Int>>);
bin_literal(_, _Acc) ->
    error.

%% General bitstring segment: <<Value:Size/Type-Specifiers>>
transform_bin_element({bin_element, _, Value, Size, TSL}, Ctx) ->
    Specs = case TSL of
        default -> [];
        _       -> TSL
    end,
    #ir_bs_segment{
        value      = transform_expr(Value, Ctx),
        size       = case Size of
                         default -> default;
                         _       -> transform_expr(Size, Ctx)
                     end,
        type       = segment_type(Specs),
        unit       = proplists:get_value(unit, [S || S = {unit, _} <- Specs], default),
        signedness = spec_choice(Specs, [signed, unsigned], unsigned),
        endianness = spec_choice(Specs, [big, little, native], big)
    }.

segment_type(Specs) ->
    Types = [T || T <- Specs,
                  lists:member(T, [integer, float, binary, bytes,
                                   bitstring, bits, utf8, utf16, utf32])],
    case Types of
        []            -> integer;
        [bytes | _]   -> binary;
        [bits | _]    -> bitstring;
        [T | _]       -> T
    end.

spec_choice(Specs, Choices, Default) ->
    case [S || S <- Specs, lists:member(S, Choices)] of
        [S | _] -> S;
        []      -> Default
    end.

transform_assoc({map_field_assoc, _, K, V}, Ctx) ->
    {transform_expr(K, Ctx), transform_expr(V, Ctx)};
transform_assoc({map_field_exact, _, K, V}, Ctx) ->
    {transform_expr(K, Ctx), transform_expr(V, Ctx)}.

transform_catch_clause({clause, _, [{tuple, _, [Class, Pat, _Stack]}], Guards, Body}, Ctx) ->
    #ir_catch_clause{
        class   = transform_expr(Class, Ctx),
        pattern = transform_expr(Pat, Ctx#ctx{in_pattern = true}),
        guards  = [[transform_expr(G, Ctx) || G <- Seq] || Seq <- Guards],
        body    = [transform_expr(E, Ctx) || E <- Body]
    }.

transform_qualifier({generate, _, Pat, Expr}, Ctx) ->
    #ir_lc_gen{pattern = transform_expr(Pat, Ctx#ctx{in_pattern = true}),
               expr    = transform_expr(Expr, Ctx)};
transform_qualifier({b_generate, _, Pat, Expr}, Ctx) ->
    #ir_bc_gen{pattern = transform_expr(Pat, Ctx#ctx{in_pattern = true}),
               expr    = transform_expr(Expr, Ctx)};
transform_qualifier(Filter, Ctx) ->
    #ir_lc_filter{expr = transform_expr(Filter, Ctx)}.

is_function_form({function, _, _, _, _}) -> true;
is_function_form(_) -> false.

module_name(Forms) ->
    hd([Name || {attribute, _, module, Name} <- Forms]).

clause_arity({clause, _, Patterns, _, _}) -> length(Patterns).
