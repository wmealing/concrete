%% Execution round-trip tests: Erlang source → transformer → encoder →
%% JavaScript → executed in Node.js against priv/js/demo/runtime.js.
%% Each snippet defines m:main/0; the harness prints
%% termToString(m:main()) and the test asserts the output.
%% Skipped entirely if node is not on PATH.
-module(js_exec_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    tuple_destructure/1,
    nested_destructure/1,
    repeated_var/1,
    list_cons_recursion/1,
    map_pattern/1,
    match_expr/1,
    badmatch_caught/1,
    if_expr/1,
    guard_bifs/1,
    comparison_is_term/1,
    andalso_orelse/1,
    case_sees_outer_binding/1,
    case_clause_error/1,
    anon_fun/1,
    anon_fun_closure/1,
    anon_fun_multiclause/1,
    fun_ref_local/1,
    map_update/1,
    list_comprehension/1,
    lc_pattern_filter/1,
    lc_two_generators/1,
    try_catch_throw/1,
    try_of_clause/1,
    try_rethrow_unmatched/1,
    bitstring_match_ints/1,
    bitstring_int16/1,
    bitstring_little_endian/1,
    bitstring_rest/1,
    bitstring_literal_prefix/1,
    bitstring_construct_concat/1,
    bitstring_float/1,
    alias_pattern/1,
    action_callback/1,
    stdlib_lists_map/1,
    stdlib_lists_foldl/1,
    stdlib_lists_filter_member/1,
    stdlib_maps_fold/1,
    stdlib_maps_from_list/1,
    stdlib_pipeline/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [tuple_destructure,
     nested_destructure,
     repeated_var,
     list_cons_recursion,
     map_pattern,
     match_expr,
     badmatch_caught,
     if_expr,
     guard_bifs,
     comparison_is_term,
     andalso_orelse,
     case_sees_outer_binding,
     case_clause_error,
     anon_fun,
     anon_fun_closure,
     anon_fun_multiclause,
     fun_ref_local,
     map_update,
     list_comprehension,
     lc_pattern_filter,
     lc_two_generators,
     try_catch_throw,
     try_of_clause,
     try_rethrow_unmatched,
     bitstring_match_ints,
     bitstring_int16,
     bitstring_little_endian,
     bitstring_rest,
     bitstring_literal_prefix,
     bitstring_construct_concat,
     bitstring_float,
     alias_pattern,
     action_callback,
     stdlib_lists_map,
     stdlib_lists_foldl,
     stdlib_lists_filter_member,
     stdlib_maps_fold,
     stdlib_maps_from_list,
     stdlib_pipeline]}].
init_per_suite(Config) ->
    case os:find_executable("node") of
        false -> {skip, "node not found on PATH"};
        _     -> Config
    end.

end_per_suite(_Config) ->
    ok.

%% --- M2: pattern compilation ---

tuple_destructure(Config) ->
    <<"12">> = run(Config,
        "main() -> f({rect, 3, 4}).\n"
        "f({rect, W, H}) -> W * H.\n").

nested_destructure(Config) ->
    <<"7">> = run(Config,
        "main() -> f({point, {3, 4}}).\n"
        "f({point, {X, Y}}) -> X + Y.\n").

repeated_var(Config) ->
    <<"{same, diff}">> = run(Config,
        "main() -> {f(2, 2), f(1, 2)}.\n"
        "f(X, X) -> same;\n"
        "f(_, _) -> diff.\n").

list_cons_recursion(Config) ->
    <<"6">> = run(Config,
        "main() -> sum([1, 2, 3], 0).\n"
        "sum([H | T], Acc) -> sum(T, Acc + H);\n"
        "sum([], Acc) -> Acc.\n").

map_pattern(Config) ->
    <<"1">> = run(Config,
        "main() -> f(#{a => 1, b => 2}).\n"
        "f(#{a := A}) -> A.\n").

%% --- M3: match and if ---

match_expr(Config) ->
    <<"7">> = run(Config,
        "main() -> {ok, V} = g(), V.\n"
        "g() -> {ok, 7}.\n").

badmatch_caught(Config) ->
    <<"caught">> = run(Config,
        "main() -> try h() catch error:{badmatch, _} -> caught end.\n"
        "h() -> ok = nope.\n").

if_expr(Config) ->
    <<"{big, small}">> = run(Config,
        "main() -> {f(5), f(1)}.\n"
        "f(N) ->\n"
        "    if N > 3 -> big;\n"
        "       true  -> small\n"
        "    end.\n").

%% --- M1: guards, comparisons, truthiness ---

guard_bifs(Config) ->
    <<"{pos, other}">> = run(Config,
        "main() -> {f(5), f(x)}.\n"
        "f(N) when is_integer(N), N > 0 -> pos;\n"
        "f(_) -> other.\n").

comparison_is_term(Config) ->
    <<"{true, false}">> = run(Config,
        "main() -> {1 < 2, 1 == 2}.\n").

andalso_orelse(Config) ->
    <<"{true, true, false}">> = run(Config,
        "main() -> {true andalso true, false orelse true, false andalso true}.\n").

case_sees_outer_binding(Config) ->
    <<"5">> = run(Config,
        "main() -> X = 5, case ok of ok -> X end.\n").

case_clause_error(Config) ->
    <<"caught">> = run(Config,
        "main() -> try f(3) catch error:{case_clause, _} -> caught end.\n"
        "f(N) -> case N of 1 -> one end.\n").

%% --- M4: anonymous functions ---

anon_fun(Config) ->
    <<"42">> = run(Config,
        "main() -> F = fun(X) -> X * 2 end, F(21).\n").

anon_fun_closure(Config) ->
    <<"42">> = run(Config,
        "main() -> Y = 10, F = fun(X) -> X + Y end, F(32).\n").

anon_fun_multiclause(Config) ->
    <<"{zero, other}">> = run(Config,
        "main() ->\n"
        "    F = fun(0) -> zero; (_) -> other end,\n"
        "    {F(0), F(9)}.\n").

fun_ref_local(Config) ->
    <<"42">> = run(Config,
        "main() -> F = fun double/1, F(21).\n"
        "double(X) -> X * 2.\n").

%% --- M5: map update ---

map_update(Config) ->
    <<"5">> = run(Config,
        "main() ->\n"
        "    M = #{a => 1},\n"
        "    M2 = M#{a := 2, b => 3},\n"
        "    maps:get(a, M2) + maps:get(b, M2).\n").

%% --- M6: list comprehensions ---

list_comprehension(Config) ->
    <<"[4, 6]">> = run(Config,
        "main() -> [X * 2 || X <- [1, 2, 3], X > 1].\n").

lc_pattern_filter(Config) ->
    <<"[1, 3]">> = run(Config,
        "main() -> [V || {ok, V} <- [{ok, 1}, {error, 2}, {ok, 3}]].\n").

lc_two_generators(Config) ->
    <<"[{1, 3}, {1, 4}, {2, 3}, {2, 4}]">> = run(Config,
        "main() -> [{X, Y} || X <- [1, 2], Y <- [3, 4]].\n").

%% --- M7: try/catch/throw ---

try_catch_throw(Config) ->
    <<"caught">> = run(Config,
        "main() -> try throw(ball) catch throw:ball -> caught end.\n").

try_of_clause(Config) ->
    <<"42">> = run(Config,
        "main() -> try 40 + 2 of X -> X catch error:_ -> err end.\n").

try_rethrow_unmatched(Config) ->
    <<"outer">> = run(Config,
        "main() ->\n"
        "    try\n"
        "        try throw(ball) catch error:_ -> inner end\n"
        "    catch throw:ball -> outer\n"
        "    end.\n").

%% --- M9: bitstrings ---

bitstring_match_ints(Config) ->
    <<"{1, 2}">> = run(Config,
        "main() -> f(<<1:8, 2:8>>).\n"
        "f(<<A:8, B:8>>) -> {A, B}.\n").

bitstring_int16(Config) ->
    <<"258">> = run(Config,
        "main() -> <<A:16>> = <<258:16>>, A.\n").

bitstring_little_endian(Config) ->
    <<"1">> = run(Config,
        "main() -> <<A:16/little>> = <<1, 0>>, A.\n").

bitstring_rest(Config) ->
    <<"{97, <<\"bc\">>}">> = run(Config,
        "main() -> <<H:8, Rest/binary>> = <<\"abc\">>, {H, Rest}.\n").

bitstring_literal_prefix(Config) ->
    <<"{matched, nomatch}">> = run(Config,
        "main() -> {f(<<\"ab:x\">>), f(<<\"zz:x\">>)}.\n"
        "f(<<\"ab:\", _Rest/binary>>) -> matched;\n"
        "f(_) -> nomatch.\n").

bitstring_construct_concat(Config) ->
    <<"<<\"abc\">>">> = run(Config,
        "main() -> A = <<\"ab\">>, <<A/binary, \"c\">>.\n").

bitstring_float(Config) ->
    <<"2.5">> = run(Config,
        "main() -> <<F:64/float>> = <<2.5:64/float>>, F.\n").

%% --- The payoff: a real component action callback ---

alias_pattern(Config) ->
    <<"{2, {1, 2}}">> = run(Config,
        "main() -> f({1, 2}).\n"
        "f({_, B} = T) -> {B, T}.\n").

action_callback(Config) ->
    %% the exact action/3 shape from the component model in CLAUDE.md:
    %% nested map patterns, alias patterns, and map update syntax
    <<"#{state => #{count => 42}}">> = run(Config,
        "main() -> action(increment, #{}, #{state => #{count => 41}}).\n"
        "action(increment, _Params, #{state := #{count := N} = S} = C) ->\n"
        "    C#{state => S#{count := N + 1}};\n"
        "action(decrement, _Params, #{state := #{count := N} = S} = C) ->\n"
        "    C#{state => S#{count := N - 1}}.\n").

%% --- Phase 5: stdlib BIFs driving compiled anonymous functions ---

stdlib_lists_map(Config) ->
    <<"[1, 4, 9, 16]">> = run(Config,
        "main() -> lists:map(fun(X) -> X * X end, lists:seq(1, 4)).\n").

stdlib_lists_foldl(Config) ->
    <<"10">> = run(Config,
        "main() -> lists:foldl(fun(X, Acc) -> Acc + X end, 0, [1, 2, 3, 4]).\n").

stdlib_lists_filter_member(Config) ->
    <<"{[2, 4], true, false}">> = run(Config,
        "main() ->\n"
        "    Evens = lists:filter(fun(X) -> X rem 2 == 0 end, [1, 2, 3, 4]),\n"
        "    {Evens, lists:member(2, Evens), lists:member(3, Evens)}.\n").

stdlib_maps_fold(Config) ->
    <<"3">> = run(Config,
        "main() ->\n"
        "    M = maps:put(b, 2, #{a => 1}),\n"
        "    maps:fold(fun(_K, V, Acc) -> Acc + V end, 0, M).\n").

stdlib_maps_from_list(Config) ->
    <<"{1, [a, b]}">> = run(Config,
        "main() ->\n"
        "    M = maps:from_list([{a, 1}, {b, 2}]),\n"
        "    {maps:get(a, M), maps:keys(M)}.\n").

stdlib_pipeline(Config) ->
    %% comprehension + higher-order + stdlib composed; expected value
    %% verified against the BEAM (JS/BEAM parity)
    <<"27">> = run(Config,
        "main() ->\n"
        "    Sq = [X * X || X <- lists:seq(1, 5), X rem 2 == 1],\n"
        "    lists:sum(Sq) - lists:nth(2, Sq) + maps:size(#{a => 1}).\n").

%% --- Harness ---

run(Config, Body) ->
    Src = "-module(m).\n" ++ Body,
    JS = compile(Src),
    RuntimePath = filename:join([code:priv_dir(concrete), "js", "demo", "runtime.js"]),
    {ok, Runtime} = file:read_file(RuntimePath),
    Script = [
        <<"const window = {};\n">>,
        Runtime,
        JS,
        <<"console.log(termToString(Interpreter.call(\"m\", \"main\", 0, [])));\n">>
    ],
    File = filename:join(?config(priv_dir, Config),
                         atom_to_list(?FUNCTION_NAME) ++ "_"
                         ++ integer_to_list(erlang:unique_integer([positive]))
                         ++ ".js"),
    ok = file:write_file(File, unicode:characters_to_binary(Script)),
    Out = os:cmd("node " ++ File ++ " 2>&1"),
    iolist_to_binary(string:trim(Out)).

compile(Src) ->
    {ok, Tokens, _} = erl_scan:string(Src),
    Forms = parse_all(Tokens, []),
    Ctx = concrete_transformer:new_ctx(m),
    IR = concrete_transformer:transform_module(Forms, Ctx),
    iolist_to_binary(concrete_encoder:encode_module(IR)).

parse_all([], Acc) -> lists:reverse(Acc);
parse_all(Tokens, Acc) ->
    case split_dot(Tokens) of
        {[], _} -> lists:reverse(Acc);
        {FormToks, Rest} ->
            case erl_parse:parse_form(FormToks) of
                {ok, Form} -> parse_all(Rest, [Form | Acc]);
                _ -> parse_all(Rest, Acc)
            end
    end.

split_dot(Tokens) -> split_dot(Tokens, []).
split_dot([], Acc) -> {lists:reverse(Acc), []};
split_dot([{dot, _} = D | Rest], Acc) -> {lists:reverse([D | Acc]), Rest};
split_dot([H | T], Acc) -> split_dot(T, [H | Acc]).
