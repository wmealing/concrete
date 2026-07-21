%% Encodes Concrete IR nodes into JavaScript string fragments.
%%
%% Generation model:
%% - Every Erlang term is a tagged JS object built via Type.*.
%% - Function clauses become [patternFn, guardFn, bodyFn] triples; the
%%   runtime tries them in order (Interpreter.callClauses).
%% - Patterns compile to ordered statements: type/shape checks
%%   interleaved with bindings, so nested destructuring and repeated
%%   variables work. Clause sets nested inside a body (case, anonymous
%%   funs, try) inherit the enclosing scope via
%%   Object.assign({}, parentBindings).
%% - Comparisons return atom terms ('true'/'false'), matching Erlang
%%   expression semantics; guard positions unwrap with
%%   Interpreter.isTrue.
%%
%% See compiler-plan.md for the milestone breakdown and the v1
%% limitations (byte-aligned bitstrings, no receive, no binary
%% comprehensions).
-module(concrete_encoder).
-include("concrete_ir.hrl").

-export([encode_module/1, encode_ir/1, encode_bundle/2, encode_function_def/2]).

encode_bundle(Graph, PLT) ->
    MFAs = concrete_call_graph:reachable(Graph),
    Fragments = [encode_mfa(MFA, PLT) || MFA <- MFAs],
    iolist_to_binary(Fragments).

encode_mfa({M, _F, _A} = MFA, PLT) ->
    case concrete_plt:get(PLT, MFA) of
        {ok, FunDef} -> encode_function_def(M, FunDef);
        not_found    -> []
    end.

encode_module(#ir_module{name = Name, definitions = Defs}) ->
    Header = io_lib:format("// Module: ~s\n", [Name]),
    Body = [encode_function_def(Name, D) || D <- Defs],
    [Header | Body].

encode_function_def(ModName, #ir_function_def{name = Fun, arity = Arity, clauses = Clauses}) ->
    reset_tmp(),
    ClausesJS = [encode_clause(C, top) || C <- Clauses],
    ModJS = encode_string(atom_to_binary(ModName)),
    io_lib:format(
        "Interpreter.defineErlangFunction(~s, ~s, ~w, ((currentModule) => [\n~s])(~s));\n",
        [ModJS,
         encode_string(atom_to_binary(Fun)),
         Arity,
         join(ClausesJS, ",\n"),
         ModJS]
    ).

%% --- Clauses ---
%% Mode is top (function head: fresh bindings) or nested (case / anon
%% fun / try clauses: inherit enclosing scope through parentBindings).

encode_clause(#ir_clause{patterns = Pats, guards = Guards, body = Body}, Mode) ->
    PatJS   = encode_pattern_fn(Pats, Mode),
    GuardJS = encode_guard_fn(Guards),
    BodyJS  = encode_body_fn(Body),
    io_lib:format("  [~s, ~s, ~s]", [PatJS, GuardJS, BodyJS]).

%% A nested clause list wrapped so patterns/bodies can see the enclosing
%% bindings object.
encode_nested_clauses(Clauses) ->
    io_lib:format("((parentBindings) => [\n~s])(bindings)",
        [join([encode_clause(C, nested) || C <- Clauses], ",\n")]).

encode_pattern_fn(Pats, Mode) ->
    Init = case Mode of
        top    -> "const bindings = {};";
        nested -> "const bindings = Object.assign({}, parentBindings);"
    end,
    {Stmts, _Seen} = compile_patterns(Pats, Mode),
    io_lib:format("(args) => { ~s ~sreturn bindings; }", [Init, Stmts]).

%% Compile a clause's argument patterns to ordered statements.
%% Seen tracks vars bound so far in this clause head (top mode) so a
%% second occurrence becomes an equality check.
compile_patterns(Pats, Mode) ->
    Indexed = lists:zip(lists:seq(0, length(Pats) - 1), Pats),
    lists:foldl(
        fun({I, P}, {Acc, Seen}) ->
            Access = io_lib:format("args[~w]", [I]),
            {S, Seen2} = compile_pattern(P, Access, "return null;", Mode, Seen),
            {[Acc, S], Seen2}
        end,
        {[], sets:new()}, Indexed).

%% compile_pattern(IR, AccessJS, FailJS, Mode, Seen) -> {StmtsIodata, Seen'}
%% FailJS is the statement to run when the pattern does not match
%% ("return null;" in clauses, a throw in match expressions, "return;"
%% in comprehension generators).

compile_pattern(#ir_wildcard{}, _Acc, _Fail, _Mode, Seen) ->
    {[], Seen};
compile_pattern(#ir_variable{name = Name}, Acc, Fail, Mode, Seen) ->
    NameJS = encode_string(atom_to_binary(Name)),
    case Mode =:= top andalso not sets:is_element(Name, Seen) of
        true ->
            %% function head, first occurrence: plain bind
            {io_lib:format("bindings[~s] = ~s; ", [NameJS, Acc]),
             sets:add_element(Name, Seen)};
        false ->
            %% may already be bound (repeated var, or enclosing scope in
            %% nested contexts): bind or check equality at runtime
            {io_lib:format(
                "if (~s in bindings) { if (!Interpreter.isEqual(bindings[~s], ~s)) { ~s } } "
                "else { bindings[~s] = ~s; } ",
                [NameJS, NameJS, Acc, Fail, NameJS, Acc]),
             sets:add_element(Name, Seen)}
    end;
compile_pattern(#ir_tuple{elements = Es}, Acc, Fail, Mode, Seen) ->
    T = next_tmp(),
    Head = io_lib:format(
        "const ~s = ~s; if (~s.type !== \"tuple\" || ~s.data.length !== ~w) { ~s } ",
        [T, Acc, T, T, length(Es), Fail]),
    compile_children(Es, T, Head, Fail, Mode, Seen);
compile_pattern(#ir_list{elements = Es, tail = nil}, Acc, Fail, Mode, Seen) ->
    T = next_tmp(),
    Head = io_lib:format(
        "const ~s = ~s; if (~s.type !== \"list\" || ~s.data.length !== ~w) { ~s } ",
        [T, Acc, T, T, length(Es), Fail]),
    compile_children(Es, T, Head, Fail, Mode, Seen);
compile_pattern(#ir_nil{}, Acc, Fail, _Mode, Seen) ->
    T = next_tmp(),
    {io_lib:format(
        "const ~s = ~s; if (~s.type !== \"list\" || ~s.data.length !== 0) { ~s } ",
        [T, Acc, T, T, Fail]),
     Seen};
compile_pattern(#ir_cons{head = H, tail = Tl}, Acc, Fail, Mode, Seen) ->
    T = next_tmp(),
    Head = io_lib:format(
        "const ~s = ~s; if (~s.type !== \"list\" || ~s.data.length === 0) { ~s } ",
        [T, Acc, T, T, Fail]),
    {HS, Seen2} = compile_pattern(H, io_lib:format("~s.data[0]", [T]), Fail, Mode, Seen),
    TailTmp = next_tmp(),
    TailStmt = io_lib:format("const ~s = Type.list(~s.data.slice(1)); ", [TailTmp, T]),
    {TS, Seen3} = compile_pattern(Tl, TailTmp, Fail, Mode, Seen2),
    {[Head, HS, TailStmt, TS], Seen3};
compile_pattern(#ir_map{pairs = Pairs}, Acc, Fail, Mode, Seen) ->
    T = next_tmp(),
    Head = io_lib:format("const ~s = ~s; if (~s.type !== \"map\") { ~s } ",
                         [T, Acc, T, Fail]),
    lists:foldl(
        fun({K, V}, {SAcc, S}) ->
            VT = next_tmp(),
            Lookup = io_lib:format(
                "const ~s = Interpreter.mapLookup(~s, ~s); if (~s === undefined) { ~s } ",
                [VT, T, encode_ir(K), VT, Fail]),
            {VS, S2} = compile_pattern(V, VT, Fail, Mode, S),
            {[SAcc, Lookup, VS], S2}
        end,
        {Head, Seen}, Pairs);
compile_pattern(#ir_match{pattern = P1, expr = P2}, Acc, Fail, Mode, Seen) ->
    %% alias pattern (P1 = P2): both match the same value
    {S1, Seen2} = compile_pattern(P1, Acc, Fail, Mode, Seen),
    {S2, Seen3} = compile_pattern(P2, Acc, Fail, Mode, Seen2),
    {[S1, S2], Seen3};
compile_pattern(#ir_bitstring{segments = Segs}, Acc, Fail, Mode, Seen) ->
    T = next_tmp(),
    Descs = [pattern_segment_desc(S) || S <- Segs],
    Head = io_lib:format(
        "const ~s = Interpreter.matchBitstringSegments(~s, [~s]); if (~s === null) { ~s } ",
        [T, Acc, join([D || {D, _} <- Descs], ", "), T, Fail]),
    Indexed = lists:zip(lists:seq(0, length(Descs) - 1), [P || {_, P} <- Descs]),
    lists:foldl(
        fun({_I, none}, {SAcc, S}) -> {SAcc, S};
           ({I, Pat}, {SAcc, S}) ->
                {PS, S2} = compile_pattern(Pat, io_lib:format("~s[~w]", [T, I]),
                                           Fail, Mode, S),
                {[SAcc, PS], S2}
        end,
        {Head, Seen}, Indexed);
compile_pattern(Literal, Acc, Fail, _Mode, Seen) ->
    %% atoms, integers, floats, strings: structural equality
    {io_lib:format("if (!Interpreter.isEqual(~s, ~s)) { ~s } ",
                   [Acc, encode_ir(Literal), Fail]),
     Seen}.

compile_children(Es, Tmp, Head, Fail, Mode, Seen) ->
    Indexed = lists:zip(lists:seq(0, length(Es) - 1), Es),
    lists:foldl(
        fun({I, E}, {Acc, S}) ->
            {ES, S2} = compile_pattern(E, io_lib:format("~s.data[~w]", [Tmp, I]),
                                       Fail, Mode, S),
            {[Acc, ES], S2}
        end,
        {Head, Seen}, Indexed).

%% --- Guards ---
%% Guard sequences: seqs are OR-ed, exprs within a seq are AND-ed.
%% Every guard expression is unwrapped with Interpreter.isTrue since
%% comparisons and guard BIFs return atom terms.

encode_guard_fn([]) ->
    "(_bindings) => true";
encode_guard_fn(Guards) ->
    Seqs = [io_lib:format("(~s)",
                [join([["Interpreter.isTrue(", encode_ir(G), ")"] || G <- Seq],
                      " && ")])
            || Seq <- Guards],
    io_lib:format("(bindings) => ~s", [join(Seqs, " || ")]).

encode_body_fn(Body) ->
    io_lib:format("(bindings) => { ~s }", [encode_body_stmts(Body)]).

%% statements; the last expression is returned
encode_body_stmts(Body) ->
    Stmts = [encode_ir(E) || E <- Body],
    Last  = lists:last(Stmts),
    Init  = [[S, "; "] || S <- lists:droplast(Stmts)],
    io_lib:format("~sreturn ~s;", [Init, Last]).

%% --- Expressions ---

encode_ir(#ir_atom{value = V}) ->
    io_lib:format("Type.atom(~s)", [encode_string(atom_to_binary(V))]);
encode_ir(#ir_integer{value = V}) ->
    io_lib:format("Type.integer(~w)", [V]);
encode_ir(#ir_float{value = V}) ->
    io_lib:format("Type.float(~w)", [V]);
encode_ir(#ir_string{value = V}) ->
    io_lib:format("Type.bitstring(~s)", [encode_string(V)]);
encode_ir(#ir_nil{}) ->
    "Type.list([])";
encode_ir(#ir_wildcard{}) ->
    "_";
encode_ir(#ir_variable{name = N}) ->
    io_lib:format("bindings[~s]", [encode_string(atom_to_binary(N))]);
encode_ir(#ir_tuple{elements = Es}) ->
    io_lib:format("Type.tuple([~s])", [join([encode_ir(E) || E <- Es], ", ")]);
encode_ir(#ir_list{elements = Es, tail = nil}) ->
    io_lib:format("Type.list([~s])", [join([encode_ir(E) || E <- Es], ", ")]);
encode_ir(#ir_map{pairs = Pairs}) ->
    io_lib:format("Type.map([~s])", [join([encode_pair(P) || P <- Pairs], ", ")]);
encode_ir(#ir_map_update{map = M, pairs = Pairs}) ->
    io_lib:format("Interpreter.mapUpdate(~s, [~s])",
        [encode_ir(M), join([encode_pair(P) || P <- Pairs], ", ")]);
encode_ir(#ir_cons{head = H, tail = T}) ->
    io_lib:format("Erlang[\"++/2\"](Type.list([~s]), ~s)", [encode_ir(H), encode_ir(T)]);
encode_ir(#ir_remote_call{module = #ir_atom{value = M}, function = #ir_atom{value = F},
                           arity = A, args = Args}) ->
    io_lib:format("Erlang[~s](~s)",
        [encode_string(io_lib:format("~s:~s/~w", [M, F, A])),
         join([encode_ir(Arg) || Arg <- Args], ", ")]);
encode_ir(#ir_local_call{name = F, arity = A, args = Args}) ->
    io_lib:format("Interpreter.call(currentModule, ~s, ~w, [~s])",
        [encode_string(atom_to_binary(F)), A,
         join([encode_ir(Arg) || Arg <- Args], ", ")]);
encode_ir(#ir_anon_call{function = F, args = Args}) ->
    io_lib:format("Interpreter.callAnon(~s, [~s])",
        [encode_ir(F), join([encode_ir(A) || A <- Args], ", ")]);
encode_ir(#ir_anon_fun{clauses = Cls, arity = Arity}) ->
    io_lib:format(
        "Type.anonFun(~w, ((parentBindings) => (args) => Interpreter.callClauses(args, [\n~s]))(bindings))",
        [Arity, join([encode_clause(C, nested) || C <- Cls], ",\n")]);
encode_ir(#ir_fun_ref{module = current_module, function = F, arity = A}) ->
    io_lib:format("Type.anonFun(~w, (args) => Interpreter.call(currentModule, ~s, ~w, args))",
        [A, encode_string(atom_to_binary(F)), A]);
encode_ir(#ir_fun_ref{module = M, function = F, arity = A}) ->
    io_lib:format("Type.anonFun(~w, (args) => Interpreter.call(~s, ~s, ~w, args))",
        [A, encode_string(atom_to_binary(M)), encode_string(atom_to_binary(F)), A]);
encode_ir(#ir_match{pattern = P, expr = E}) ->
    T = next_tmp(),
    Fail = io_lib:format("throw Interpreter.matchError(~s);", [T]),
    {Stmts, _} = compile_pattern(P, T, lists:flatten(Fail), nested, sets:new()),
    io_lib:format("(() => { const ~s = ~s; ~sreturn ~s; })()",
        [T, encode_ir(E), Stmts, T]);
encode_ir(#ir_case{expr = E, clauses = Cls}) ->
    io_lib:format("Interpreter.matchClauses(~s, ~s)",
        [encode_ir(E), encode_nested_clauses(Cls)]);
encode_ir(#ir_if{clauses = Cls}) ->
    Branches = [begin
        Guard = case Guards of
            [] -> "true";
            _  -> join([io_lib:format("(~s)",
                          [join([["Interpreter.isTrue(", encode_ir(G), ")"]
                                 || G <- Seq], " && ")])
                        || Seq <- Guards], " || ")
        end,
        io_lib:format("if (~s) { ~s } ", [Guard, encode_body_stmts(Body)])
    end || #ir_clause{guards = Guards, body = Body} <- Cls],
    io_lib:format("(() => { ~sthrow Interpreter.raise(\"error\", Type.atom(\"if_clause\")); })()",
        [Branches]);
encode_ir(#ir_try{body = Body, of_clauses = OfCls, catch_clauses = CatchCls,
                  after_body = AfterBody}) ->
    OfJS = case OfCls of
        [] -> "null";
        _  -> encode_nested_clauses(OfCls)
    end,
    CatchJS = case CatchCls of
        [] -> "null";
        _  -> encode_nested_clauses([catch_to_clause(C) || C <- CatchCls])
    end,
    AfterJS = case AfterBody of
        [] -> "null";
        _  -> io_lib:format("() => { ~s }", [encode_body_stmts(AfterBody)])
    end,
    io_lib:format("Interpreter.tryCatch(() => { ~s }, ~s, ~s, ~s)",
        [encode_body_stmts(Body), OfJS, CatchJS, AfterJS]);
encode_ir(#ir_lc{template = T, qualifiers = Qs}) ->
    Inner = io_lib:format("result.push(~s); ", [encode_ir(T)]),
    Loop = encode_lc_qualifiers(Qs, Inner),
    io_lib:format("(() => { const result = []; ~sreturn Type.list(result); })()",
        [Loop]);
encode_ir(#ir_bc{}) ->
    error({binary_comprehensions_not_supported,
           "binary comprehensions are not supported in client-compiled code yet "
           "(see compiler-plan.md M6)"});
encode_ir(#ir_receive{}) ->
    error({receive_not_supported_in_client_code,
           "receive cannot run in browser-compiled code; move message handling "
           "into a server-side command (command/3 callback)"});
encode_ir(#ir_bitstring{segments = Segs}) ->
    io_lib:format("Interpreter.buildBitstring([~s])",
        [join([build_segment_desc(S) || S <- Segs], ", ")]);
encode_ir(#ir_binop{op = Op, left = L, right = R}) ->
    encode_binop(Op, L, R);
encode_ir(#ir_unop{op = 'not', operand = E}) ->
    io_lib:format("Erlang[\"not/1\"](~s)", [encode_ir(E)]);
encode_ir(#ir_unop{op = '-', operand = E}) ->
    io_lib:format("Erlang[\"-/1\"](~s)", [encode_ir(E)]);
encode_ir(#ir_block{exprs = Exprs}) ->
    io_lib:format("(() => { ~s })()", [encode_body_stmts(Exprs)]);
encode_ir(Node) ->
    error({unhandled_ir_node, Node}).

catch_to_clause(#ir_catch_clause{class = Class, pattern = Pat,
                                 guards = Guards, body = Body}) ->
    #ir_clause{patterns = [Class, Pat], guards = Guards, body = Body}.

%% --- Comprehension qualifiers ---
%% Each generator level shadows bindings for its scope; non-matching
%% elements and false filters skip via return.

encode_lc_qualifiers([], Inner) ->
    Inner;
encode_lc_qualifiers([#ir_lc_gen{pattern = P, expr = E} | Rest], Inner) ->
    T = next_tmp(),
    {PatStmts, _} = compile_pattern(P, T, "return;", nested, sets:new()),
    Body = encode_lc_qualifiers(Rest, Inner),
    io_lib:format(
        "for (const ~s of (~s).data) { ((bindings) => { ~s~s })(Object.assign({}, bindings)); } ",
        [T, encode_ir(E), PatStmts, Body]);
encode_lc_qualifiers([#ir_lc_filter{expr = F} | Rest], Inner) ->
    Body = encode_lc_qualifiers(Rest, Inner),
    io_lib:format("if (!Interpreter.isTrue(~s)) { return; } ~s",
        [encode_ir(F), Body]).

%% --- Bitstring segments ---
%% Byte-aligned subset; see compiler-plan.md M9 for limitations.

%% Construction: {v: term, t: type, size: bits|null, little: bool}
build_segment_desc(#ir_bs_segment{value = V} = Seg) ->
    {T, Bits} = segment_layout(Seg),
    io_lib:format("{v: ~s, t: ~s, size: ~s, little: ~s}",
        [encode_ir(V), encode_string(atom_to_binary(T)), Bits, seg_little(Seg)]).

%% Pattern: {t, size, little, lit} plus the sub-pattern to bind (or none
%% for literal segments, which the matcher compares itself).
pattern_segment_desc(#ir_bs_segment{value = V} = Seg) ->
    {T, Bits} = segment_layout(Seg),
    case is_literal_segment(V) of
        true ->
            LitBits = literal_segment_bits(V, T, Bits),
            {io_lib:format("{t: ~s, size: ~s, little: ~s, lit: ~s}",
                 [encode_string(atom_to_binary(T)), LitBits, seg_little(Seg),
                  encode_ir(V)]),
             none};
        false ->
            {io_lib:format("{t: ~s, size: ~s, little: ~s, lit: null}",
                 [encode_string(atom_to_binary(T)), Bits, seg_little(Seg)]),
             V}
    end.

is_literal_segment(#ir_integer{}) -> true;
is_literal_segment(#ir_float{})   -> true;
is_literal_segment(#ir_string{})  -> true;
is_literal_segment(_)             -> false.

%% string literal segments occupy their text length regardless of the
%% declared per-element size
literal_segment_bits(#ir_string{value = S}, _T, _Bits) ->
    integer_to_list(byte_size(S) * 8);
literal_segment_bits(_, _T, Bits) ->
    Bits.

segment_layout(#ir_bs_segment{value = V, size = Size, type = Type, unit = Unit}) ->
    T = case {Type, V} of
        {integer, #ir_string{}} -> binary;   % <<"text">> element inside a bin
        _ -> Type
    end,
    UnitN = case Unit of
        default -> default_unit(T);
        N when is_integer(N) -> N
    end,
    Bits = case {Size, T} of
        {default, integer}   -> "8";
        {default, float}     -> "64";
        {default, binary}    -> "null";     % whole value / rest
        {default, utf8}      -> "null";
        {#ir_integer{value = S}, _} -> integer_to_list(S * UnitN);
        {_, _} ->
            error({bitstring_dynamic_size_not_supported,
                   "bitstring segment sizes must be integer literals in "
                   "client-compiled code (see compiler-plan.md M9)"})
    end,
    case T of
        bitstring ->
            error({bit_level_segments_not_supported,
                   "bit-level (non-byte-aligned) segments are not supported in "
                   "client-compiled code (see compiler-plan.md M9)"});
        utf16 -> error({utf16_segments_not_supported, T});
        utf32 -> error({utf32_segments_not_supported, T});
        _ -> ok
    end,
    {T, Bits}.

default_unit(integer) -> 1;
default_unit(float)   -> 1;
default_unit(binary)  -> 8;
default_unit(_)       -> 1.

seg_little(#ir_bs_segment{endianness = little}) -> "true";
seg_little(#ir_bs_segment{})                    -> "false".

%% --- Operators ---

encode_binop('+',      L, R) -> binop_call("+/2",      L, R);
encode_binop('-',      L, R) -> binop_call("-/2",      L, R);
encode_binop('*',      L, R) -> binop_call("*/2",      L, R);
encode_binop('/',      L, R) -> binop_call("//2",      L, R);
encode_binop('div',    L, R) -> binop_call("div/2",    L, R);
encode_binop('rem',    L, R) -> binop_call("rem/2",    L, R);
encode_binop('++',     L, R) -> binop_call("++/2",     L, R);
encode_binop('--',     L, R) -> binop_call("--/2",     L, R);
encode_binop('band',   L, R) -> binop_call("band/2",   L, R);
encode_binop('bor',    L, R) -> binop_call("bor/2",    L, R);
encode_binop('bxor',   L, R) -> binop_call("bxor/2",   L, R);
encode_binop('bsl',    L, R) -> binop_call("bsl/2",    L, R);
encode_binop('bsr',    L, R) -> binop_call("bsr/2",    L, R);
encode_binop('==',     L, R) -> binop_call("==/2",     L, R);
encode_binop('/=',     L, R) -> binop_call("/=/2",     L, R);
encode_binop('=:=',    L, R) -> binop_call("=:=/2",    L, R);
encode_binop('=/=',    L, R) -> binop_call("=/=/2",    L, R);
encode_binop('<',      L, R) -> binop_call("</2",      L, R);
encode_binop('>',      L, R) -> binop_call(">/2",      L, R);
encode_binop('=<',     L, R) -> binop_call("=</2",     L, R);
encode_binop('>=',     L, R) -> binop_call(">=/2",     L, R);
encode_binop('andalso', L, R) ->
    io_lib:format("Interpreter.andalso(() => ~s, () => ~s)",
        [encode_ir(L), encode_ir(R)]);
encode_binop('orelse', L, R) ->
    io_lib:format("Interpreter.orelse(() => ~s, () => ~s)",
        [encode_ir(L), encode_ir(R)]);
encode_binop(Op,       L, R) -> binop_call(io_lib:format("~s/2", [Op]), L, R).

binop_call(Name, L, R) ->
    io_lib:format("Erlang[~s](~s, ~s)", [encode_string(Name), encode_ir(L), encode_ir(R)]).

encode_pair({K, V}) ->
    io_lib:format("[~s, ~s]", [encode_ir(K), encode_ir(V)]).

%% --- Helpers ---

encode_string(S) when is_binary(S) ->
    [$", escape_js(binary_to_list(S)), $"];
encode_string(S) when is_list(S) ->
    [$", escape_js(lists:flatten(S)), $"].

escape_js([])          -> [];
escape_js([$\\ | Cs])  -> [$\\, $\\ | escape_js(Cs)];
escape_js([$"  | Cs])  -> [$\\, $"  | escape_js(Cs)];
escape_js([$\n | Cs])  -> [$\\, $n  | escape_js(Cs)];
escape_js([$\r | Cs])  -> [$\\, $r  | escape_js(Cs)];
escape_js([$\t | Cs])  -> [$\\, $t  | escape_js(Cs)];
escape_js([C   | Cs])  -> [C | escape_js(Cs)].

%% deterministic per-function-def temp names for generated locals
next_tmp() ->
    N = case get(concrete_encoder_tmp) of
        undefined -> 0;
        X -> X
    end,
    put(concrete_encoder_tmp, N + 1),
    lists:flatten(io_lib:format("p~w", [N])).

reset_tmp() ->
    put(concrete_encoder_tmp, 0).

join([], _Sep) -> [];
join([H | T], Sep) -> [H | [[Sep, E] || E <- T]].
