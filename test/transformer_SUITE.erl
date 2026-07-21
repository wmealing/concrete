%% Phase 1: Erlang AST → Concrete IR transformer tests.
%% Each test exercises one or more AST node types from erl_parse.
-module(transformer_SUITE).
-include_lib("common_test/include/ct.hrl").
-include("concrete_ir.hrl").

-export([all/0, groups/0]).
-export([
    atom/1,
    integer/1,
    float/1,
    string_to_binary/1,
    nil/1,
    wildcard/1,
    variable/1,
    tuple/1,
    cons/1,
    match/1,
    map_literal/1,
    map_update/1,
    local_call/1,
    remote_call/1,
    case_expr/1,
    if_expr/1,
    block/1,
    receive_no_after/1,
    receive_with_after/1,
    anon_fun/1,
    fun_ref_local/1,
    fun_ref_remote/1,
    binop/1,
    unop/1,
    list_comprehension/1,
    function_clause/1,
    full_module/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [
        atom, integer, float, string_to_binary, nil, wildcard, variable,
        tuple, cons, match, map_literal, map_update,
        local_call, remote_call,
        case_expr, if_expr, block,
        receive_no_after, receive_with_after,
        anon_fun, fun_ref_local, fun_ref_remote,
        binop, unop, list_comprehension,
        function_clause, full_module
    ]}].
ctx() -> concrete_transformer:new_ctx(test_module).

%% --- Primitive types ---

atom(_Config) ->
    #ir_atom{value = ok} = tx({atom, 1, ok}).

integer(_Config) ->
    #ir_integer{value = 42} = tx({integer, 1, 42}).

float(_Config) ->
    #ir_float{value = 3.14} = tx({float, 1, 3.14}).

%% "hello" in Erlang AST is a charlist; must become a binary in IR.
string_to_binary(_Config) ->
    #ir_string{value = <<"hello">>} = tx({string, 1, "hello"}).

nil(_Config) ->
    #ir_nil{} = tx({nil, 1}).

wildcard(_Config) ->
    #ir_wildcard{} = tx({var, 1, '_'}).

variable(_Config) ->
    #ir_variable{name = 'X'} = tx({var, 1, 'X'}).

%% --- Compound types ---

tuple(_Config) ->
    AST = {tuple, 1, [{atom, 1, a}, {integer, 1, 1}]},
    #ir_tuple{elements = [#ir_atom{value = a}, #ir_integer{value = 1}]} = tx(AST).

cons(_Config) ->
    AST = {cons, 1, {integer, 1, 1}, {nil, 1}},
    #ir_cons{head = #ir_integer{value = 1}, tail = #ir_nil{}} = tx(AST).

match(_Config) ->
    AST = {match, 1, {var, 1, 'X'}, {integer, 1, 5}},
    #ir_match{pattern = #ir_variable{name = 'X'},
              expr    = #ir_integer{value = 5}} = tx(AST).

map_literal(_Config) ->
    AST = {map, 1, [{map_field_assoc, 1, {atom, 1, key}, {integer, 1, 1}}]},
    #ir_map{pairs = [{#ir_atom{value = key}, #ir_integer{value = 1}}]} = tx(AST).

map_update(_Config) ->
    AST = {map, 1, {var, 1, 'M'},
           [{map_field_exact, 1, {atom, 1, k}, {integer, 1, 2}}]},
    #ir_map_update{map   = #ir_variable{name = 'M'},
                   pairs = [{#ir_atom{value = k}, #ir_integer{value = 2}}]} = tx(AST).

%% --- Calls ---

local_call(_Config) ->
    AST = {call, 1, {atom, 1, foo}, [{integer, 1, 1}]},
    #ir_local_call{name = foo, arity = 1,
                   args = [#ir_integer{value = 1}]} = tx(AST).

remote_call(_Config) ->
    AST = {call, 1, {remote, 1, {atom, 1, lists}, {atom, 1, reverse}},
           [{nil, 1}]},
    #ir_remote_call{module   = #ir_atom{value = lists},
                    function = #ir_atom{value = reverse},
                    arity    = 1,
                    args     = [#ir_nil{}]} = tx(AST).

%% --- Control flow ---

case_expr(_Config) ->
    AST = {'case', 1, {var, 1, 'X'},
           [{clause, 1, [{atom, 1, ok}], [], [{atom, 1, done}]}]},
    #ir_case{expr    = #ir_variable{name = 'X'},
             clauses = [#ir_clause{patterns = [#ir_atom{value = ok}],
                                   guards   = [],
                                   body     = [#ir_atom{value = done}]}]} = tx(AST).

if_expr(_Config) ->
    AST = {'if', 1,
           [{clause, 1, [], [[{atom, 1, true}]], [{atom, 1, yes}]}]},
    #ir_if{clauses = [#ir_clause{patterns = [],
                                 guards   = [[#ir_atom{value = true}]],
                                 body     = [#ir_atom{value = yes}]}]} = tx(AST).

block(_Config) ->
    AST = {block, 1, [{integer, 1, 1}, {integer, 1, 2}]},
    #ir_block{exprs = [#ir_integer{value = 1}, #ir_integer{value = 2}]} = tx(AST).

receive_no_after(_Config) ->
    AST = {'receive', 1,
           [{clause, 1, [{atom, 1, ping}], [], [{atom, 1, pong}]}]},
    #ir_receive{clauses    = [_],
                after_expr = nil,
                after_body = nil} = tx(AST).

receive_with_after(_Config) ->
    AST = {'receive', 1,
           [{clause, 1, [{atom, 1, ping}], [], [{atom, 1, pong}]}],
           {integer, 1, 5000},
           [{atom, 1, timeout}]},
    #ir_receive{after_expr = #ir_integer{value = 5000},
                after_body = [#ir_atom{value = timeout}]} = tx(AST).

%% --- Anonymous funs and references ---

anon_fun(_Config) ->
    AST = {'fun', 1,
           {clauses, [{clause, 1, [{var, 1, 'X'}], [],
                       [{var, 1, 'X'}]}]}},
    #ir_anon_fun{arity = 1, clauses = [_]} = tx(AST).

fun_ref_local(_Config) ->
    AST = {'fun', 1, {function, foo, 2}},
    #ir_fun_ref{module = current_module, function = foo, arity = 2} = tx(AST).

fun_ref_remote(_Config) ->
    AST = {'fun', 1, {function, lists, reverse, 1}},
    #ir_fun_ref{module = lists, function = reverse, arity = 1} = tx(AST).

%% --- Operators ---

binop(_Config) ->
    AST = {op, 1, '+', {integer, 1, 1}, {integer, 1, 2}},
    #ir_binop{op = '+', left = #ir_integer{value = 1},
              right = #ir_integer{value = 2}} = tx(AST).

unop(_Config) ->
    AST = {op, 1, '-', {integer, 1, 5}},
    #ir_unop{op = '-', operand = #ir_integer{value = 5}} = tx(AST).

%% --- Comprehensions ---

list_comprehension(_Config) ->
    AST = {lc, 1, {var, 1, 'X'},
           [{generate, 1, {var, 1, 'X'}, {nil, 1}}]},
    #ir_lc{template   = #ir_variable{name = 'X'},
           qualifiers = [#ir_lc_gen{pattern = #ir_variable{name = 'X'},
                                    expr    = #ir_nil{}}]} = tx(AST).

%% --- Clauses and full module ---

function_clause(_Config) ->
    Clause = {clause, 1, [{var, 1, 'X'}], [], [{var, 1, 'X'}]},
    #ir_clause{patterns = [#ir_variable{name = 'X'}],
               guards   = [],
               body     = [#ir_variable{name = 'X'}]} =
        concrete_transformer:transform_clause(Clause, ctx()).

full_module(_Config) ->
    Forms = [
        {attribute, 1, module, my_mod},
        {function,  2, id, 1,
         [{clause, 2, [{var, 2, 'X'}], [], [{var, 2, 'X'}]}]}
    ],
    Ctx = ctx(),
    #ir_module{name        = my_mod,
               definitions = [#ir_function_def{name = id, arity = 1}]} =
        concrete_transformer:transform_module(Forms, Ctx).

%% Helper — wraps transform_expr with a default context.
tx(AST) ->
    concrete_transformer:transform_expr(AST, ctx()).
