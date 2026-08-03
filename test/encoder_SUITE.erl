%% Phase 1: Concrete IR → JavaScript encoder tests.
%% Each test verifies that an IR node produces the expected JS fragment.
-module(encoder_SUITE).
-include_lib("common_test/include/ct.hrl").
-include("concrete_ir.hrl").

-export([all/0, groups/0]).
-export([
    encode_atom/1,
    encode_atom_true/1,
    encode_atom_false/1,
    encode_integer/1,
    encode_float/1,
    encode_string/1,
    encode_nil/1,
    encode_wildcard/1,
    encode_variable/1,
    encode_tuple/1,
    encode_map/1,
    encode_remote_call/1,
    encode_local_call/1,
    encode_binop_plus/1,
    encode_binop_eq/1,
    encode_binop_strict_eq/1,
    encode_binop_andalso/1,
    encode_unop_neg/1,
    encode_block/1,
    encode_case/1,
    encode_function_def/1,
    encode_module/1,
    encode_tuple_pattern_destructures/1,
    encode_if/1,
    encode_match/1,
    encode_map_update/1,
    encode_anon_fun/1,
    encode_fun_ref/1,
    encode_lc/1,
    encode_try/1,
    encode_bitstring_build/1,
    encode_receive_after_is_error/1,
    encode_receive_smoke/1,
    encode_bc_is_error/1,
    encode_dynamic_bs_size_is_error/1,
    encode_plain_module_names/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [
        encode_atom, encode_atom_true, encode_atom_false,
        encode_integer, encode_float, encode_string, encode_nil,
        encode_wildcard, encode_variable,
        encode_tuple, encode_map,
        encode_remote_call, encode_local_call,
        encode_binop_plus, encode_binop_eq, encode_binop_strict_eq, encode_binop_andalso,
        encode_unop_neg,
        encode_block, encode_case,
        encode_function_def, encode_module,
        encode_tuple_pattern_destructures,
        encode_if, encode_match, encode_map_update,
        encode_anon_fun, encode_fun_ref, encode_lc, encode_try,
        encode_bitstring_build,
        encode_receive_after_is_error, encode_receive_smoke, encode_bc_is_error,
        encode_dynamic_bs_size_is_error,
        encode_plain_module_names
    ]}].
js(IR) -> iolist_to_binary(concrete_encoder:encode_ir(IR)).

%% --- Primitives ---

encode_atom(_Config) ->
    <<"Type.atom(\"ok\")">> = js(#ir_atom{value = ok}).

encode_atom_true(_Config) ->
    <<"Type.atom(\"true\")">> = js(#ir_atom{value = true}).

encode_atom_false(_Config) ->
    <<"Type.atom(\"false\")">> = js(#ir_atom{value = false}).

encode_integer(_Config) ->
    <<"Type.integer(42)">> = js(#ir_integer{value = 42}).

encode_float(_Config) ->
    JS = js(#ir_float{value = 3.14}),
    true = binary:match(JS, <<"Type.float(">>) =/= nomatch.

encode_string(_Config) ->
    <<"Type.bitstring(\"hello\")">> = js(#ir_string{value = <<"hello">>}).

encode_nil(_Config) ->
    <<"Type.list([])">> = js(#ir_nil{}).

encode_wildcard(_Config) ->
    <<"_">> = js(#ir_wildcard{}).

encode_variable(_Config) ->
    JS = js(#ir_variable{name = 'Count'}),
    <<"bindings[\"Count\"]">> = JS.

%% --- Compound ---

encode_tuple(_Config) ->
    IR = #ir_tuple{elements = [#ir_atom{value = ok}, #ir_integer{value = 1}]},
    <<"Type.tuple([Type.atom(\"ok\"), Type.integer(1)])">> = js(IR).

encode_map(_Config) ->
    IR = #ir_map{pairs = [{#ir_atom{value = key}, #ir_integer{value = 42}}]},
    <<"Type.map([[Type.atom(\"key\"), Type.integer(42)]])">> = js(IR).

%% --- Calls ---

encode_remote_call(_Config) ->
    IR = #ir_remote_call{
        module   = #ir_atom{value = lists},
        function = #ir_atom{value = reverse},
        arity    = 1,
        args     = [#ir_nil{}]
    },
    JS = js(IR),
    true = binary:match(JS, <<"Erlang[\"lists:reverse/1\"]">>) =/= nomatch.

encode_local_call(_Config) ->
    IR = #ir_local_call{name = foo, arity = 1, args = [#ir_integer{value = 0}]},
    JS = js(IR),
    true = binary:match(JS, <<"Interpreter.call(">>) =/= nomatch,
    true = binary:match(JS, <<"\"foo\"">>) =/= nomatch.

%% --- Operators ---

encode_binop_plus(_Config) ->
    IR = #ir_binop{op = '+', left = #ir_integer{value = 1}, right = #ir_integer{value = 2}},
    JS = js(IR),
    true = binary:match(JS, <<"Erlang[\"+/2\"]">>) =/= nomatch.

%% comparisons return atom terms (Erlang expression semantics), so they
%% encode as Erlang BIF calls, not JS boolean helpers
encode_binop_eq(_Config) ->
    IR = #ir_binop{op = '==', left = #ir_atom{value = a}, right = #ir_atom{value = b}},
    JS = js(IR),
    true = binary:match(JS, <<"Erlang[\"==/2\"]">>) =/= nomatch.

encode_binop_strict_eq(_Config) ->
    IR = #ir_binop{op = '=:=', left = #ir_integer{value = 1}, right = #ir_integer{value = 1}},
    JS = js(IR),
    true = binary:match(JS, <<"Erlang[\"=:=/2\"]">>) =/= nomatch.

encode_binop_andalso(_Config) ->
    IR = #ir_binop{op = 'andalso', left = #ir_atom{value = true}, right = #ir_atom{value = false}},
    JS = js(IR),
    true = binary:match(JS, <<"Interpreter.andalso(() =>">>) =/= nomatch.

encode_unop_neg(_Config) ->
    IR = #ir_unop{op = '-', operand = #ir_integer{value = 5}},
    JS = js(IR),
    true = binary:match(JS, <<"Erlang[\"-/1\"]">>) =/= nomatch.

%% --- Control flow ---

encode_block(_Config) ->
    IR = #ir_block{exprs = [#ir_integer{value = 1}, #ir_integer{value = 2}]},
    JS = js(IR),
    true = binary:match(JS, <<"=>">>) =/= nomatch.

encode_case(_Config) ->
    Clause = #ir_clause{
        patterns = [#ir_atom{value = ok}],
        guards   = [],
        body     = [#ir_atom{value = done}]
    },
    IR = #ir_case{expr = #ir_variable{name = 'X'}, clauses = [Clause]},
    JS = iolist_to_binary(concrete_encoder:encode_ir(IR)),
    true = binary:match(JS, <<"Interpreter.matchClauses(">>) =/= nomatch.

%% --- Functions and modules ---

encode_function_def(_Config) ->
    Clause = #ir_clause{
        patterns = [#ir_variable{name = 'X'}],
        guards   = [],
        body     = [#ir_variable{name = 'X'}]
    },
    FunDef = #ir_function_def{name = id, arity = 1, clauses = [Clause]},
    JS = iolist_to_binary(concrete_encoder:encode_function_def(my_mod, FunDef)),
    true = binary:match(JS, <<"defineErlangFunction">>) =/= nomatch,
    true = binary:match(JS, <<"\"my_mod\"">>) =/= nomatch,
    true = binary:match(JS, <<"\"id\"">>) =/= nomatch,
    true = binary:match(JS, <<"1">>) =/= nomatch.

encode_module(_Config) ->
    Clause = #ir_clause{patterns = [], guards = [], body = [#ir_atom{value = ok}]},
    Mod = #ir_module{
        name = my_mod,
        definitions = [
            #ir_function_def{name = go, arity = 0, clauses = [Clause]}
        ]
    },
    JS = iolist_to_binary(concrete_encoder:encode_module(Mod)),
    true = binary:match(JS, <<"// Module: my_mod">>) =/= nomatch,
    true = binary:match(JS, <<"defineErlangFunction">>) =/= nomatch.

%% --- New nodes (see compiler-plan.md) ---

encode_tuple_pattern_destructures(_Config) ->
    %% tuple patterns with variables must destructure, not equality-check
    Clause = #ir_clause{
        patterns = [#ir_tuple{elements = [#ir_atom{value = rect},
                                          #ir_variable{name = 'W'}]}],
        guards   = [],
        body     = [#ir_variable{name = 'W'}]
    },
    FunDef = #ir_function_def{name = f, arity = 1, clauses = [Clause]},
    JS = iolist_to_binary(concrete_encoder:encode_function_def(m, FunDef)),
    true = binary:match(JS, <<".type !== \"tuple\"">>) =/= nomatch,
    true = binary:match(JS, <<".data.length !== 2">>) =/= nomatch,
    true = binary:match(JS, <<"bindings[\"W\"] = ">>) =/= nomatch.

encode_if(_Config) ->
    IR = #ir_if{clauses = [
        #ir_clause{patterns = [], guards = [[#ir_atom{value = true}]],
                   body = [#ir_atom{value = yes}]}
    ]},
    JS = js(IR),
    true = binary:match(JS, <<"if_clause">>) =/= nomatch,
    true = binary:match(JS, <<"Interpreter.isTrue(">>) =/= nomatch.

encode_match(_Config) ->
    IR = #ir_match{pattern = #ir_variable{name = 'X'},
                   expr = #ir_integer{value = 1}},
    JS = js(IR),
    true = binary:match(JS, <<"Interpreter.matchError(">>) =/= nomatch.

encode_map_update(_Config) ->
    IR = #ir_map_update{map = #ir_variable{name = 'M'},
                        pairs = [{#ir_atom{value = k}, #ir_integer{value = 1}}]},
    <<"Interpreter.mapUpdate(bindings[\"M\"], [[Type.atom(\"k\"), Type.integer(1)]])">> = js(IR).

encode_anon_fun(_Config) ->
    IR = #ir_anon_fun{arity = 1, clauses = [
        #ir_clause{patterns = [#ir_variable{name = 'X'}], guards = [],
                   body = [#ir_variable{name = 'X'}]}
    ]},
    JS = js(IR),
    true = binary:match(JS, <<"Type.anonFun(1,">>) =/= nomatch,
    true = binary:match(JS, <<"parentBindings">>) =/= nomatch.

encode_fun_ref(_Config) ->
    JS1 = js(#ir_fun_ref{module = current_module, function = f, arity = 2}),
    true = binary:match(JS1, <<"Interpreter.call(currentModule, \"f\", 2, args)">>) =/= nomatch,
    JS2 = js(#ir_fun_ref{module = lists, function = reverse, arity = 1}),
    true = binary:match(JS2, <<"Interpreter.call(\"lists\", \"reverse\", 1, args)">>) =/= nomatch.

encode_lc(_Config) ->
    IR = #ir_lc{template = #ir_variable{name = 'X'},
                qualifiers = [#ir_lc_gen{pattern = #ir_variable{name = 'X'},
                                         expr = #ir_nil{}},
                              #ir_lc_filter{expr = #ir_atom{value = true}}]},
    JS = js(IR),
    true = binary:match(JS, <<"result.push(">>) =/= nomatch,
    true = binary:match(JS, <<"for (const">>) =/= nomatch.

encode_try(_Config) ->
    IR = #ir_try{
        body = [#ir_atom{value = ok}],
        of_clauses = [],
        catch_clauses = [#ir_catch_clause{class = #ir_atom{value = error},
                                          pattern = #ir_wildcard{},
                                          guards = [],
                                          body = [#ir_atom{value = caught}]}],
        after_body = []
    },
    JS = js(IR),
    true = binary:match(JS, <<"Interpreter.tryCatch(">>) =/= nomatch.

encode_bitstring_build(_Config) ->
    IR = #ir_bitstring{segments = [
        #ir_bs_segment{value = #ir_variable{name = 'A'}, size = default,
                       type = integer, unit = default,
                       signedness = unsigned, endianness = big}
    ]},
    JS = js(IR),
    true = binary:match(JS, <<"Interpreter.buildBitstring(">>) =/= nomatch,
    true = binary:match(JS, <<"t: \"integer\", size: 8, little: false">>) =/= nomatch.

%% receive itself is supported now (see process_SUITE for execution
%% tests); only receive...after (timeouts) remains unsupported in v1.
encode_receive_after_is_error(_Config) ->
    IR = #ir_receive{clauses = [], after_expr = #ir_integer{value = 100},
                     after_body = [#ir_atom{value = ok}]},
    {'EXIT', {{receive_after_not_supported_in_client_code, _}, _}} =
        (catch concrete_encoder:encode_ir(IR)),
    ok.

encode_receive_smoke(_Config) ->
    %% A bare receive compiles to a yield*-delegated generator IIFE
    %% that calls Interpreter.receiveMatch; full behavioral coverage
    %% (spawn/send/receive round trips) lives in process_SUITE.
    IR = #ir_receive{
        clauses = [#ir_clause{patterns = [#ir_atom{value = ping}],
                              guards = [], body = [#ir_atom{value = pong}]}],
        after_expr = nil, after_body = nil},
    JS = js(IR),
    true = binary:match(JS, <<"Interpreter.receiveMatch">>) =/= nomatch,
    true = binary:match(JS, <<"yield*">>) =/= nomatch,
    ok.

encode_bc_is_error(_Config) ->
    IR = #ir_bc{template = #ir_variable{name = 'X'}, qualifiers = []},
    {'EXIT', {{binary_comprehensions_not_supported, _}, _}} =
        (catch concrete_encoder:encode_ir(IR)),
    ok.

%% Phase 5 guarantee: module names encode as plain atoms — never with
%% the upstream "Elixir." prefix.
encode_plain_module_names(_Config) ->
    Clause = #ir_clause{patterns = [], guards = [], body = [#ir_atom{value = ok}]},
    Mod = #ir_module{name = counter, definitions = [
        #ir_function_def{name = go, arity = 0, clauses = [Clause]}
    ]},
    JS = iolist_to_binary(concrete_encoder:encode_module(Mod)),
    true = binary:match(JS, <<"defineErlangFunction(\"counter\"">>) =/= nomatch,
    nomatch = binary:match(JS, <<"Elixir">>).

encode_dynamic_bs_size_is_error(_Config) ->
    IR = #ir_bitstring{segments = [
        #ir_bs_segment{value = #ir_variable{name = 'D'},
                       size = #ir_variable{name = 'Len'},
                       type = binary, unit = default,
                       signedness = unsigned, endianness = big}
    ]},
    {'EXIT', {{bitstring_dynamic_size_not_supported, _}, _}} =
        (catch concrete_encoder:encode_ir(IR)),
    ok.
