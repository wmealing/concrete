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
    stdlib_pipeline/1,
    js_call_global_function/1,
    js_call_method_via_handle/1,
    js_get_set_roundtrip/1,
    js_instanceof_and_typeof/1,
    js_error_caught/1,
    js_list_arg_unboxed_as_array/1,
    js_map_arg_unboxed_as_object/1,
    js_atom_paths_work_like_binaries/1,
    js_await_resolved_promise/1,
    js_await_deferred_promise/1,
    js_await_rejected_promise/1,
    js_await_outside_spawn_errors/1,
    js_callback_fun_receives_one_arg/1,
    js_callback_fun_receives_two_args/1,
    js_callback_fun_closure/1,
    js_callback_fun_blocking_errors/1,
    js_callback_fun_arity_mismatch_errors/1
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
     stdlib_pipeline,
     js_call_global_function,
     js_call_method_via_handle,
     js_get_set_roundtrip,
     js_instanceof_and_typeof,
     js_error_caught,
     js_list_arg_unboxed_as_array,
     js_map_arg_unboxed_as_object,
     js_atom_paths_work_like_binaries,
     js_await_resolved_promise,
     js_await_deferred_promise,
     js_await_rejected_promise,
     js_await_outside_spawn_errors,
     js_callback_fun_receives_one_arg,
     js_callback_fun_receives_two_args,
     js_callback_fun_closure,
     js_callback_fun_blocking_errors,
     js_callback_fun_arity_mismatch_errors]}].
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

%% --- concrete_js: interop with arbitrary already-loaded JS ---
%% Each snippet mocks a "loaded via <script>" global the same way a real
%% page would get one -- plain globalThis.X = ... assignment, injected
%% before runtime.js loads (see run/3).

js_call_global_function(Config) ->
    <<"3">> = run(Config,
        "globalThis.add = (a, b) => a + b;\n",
        "main() -> concrete_js:call(<<\"add\">>, [1, 2]).\n").

js_call_method_via_handle(Config) ->
    <<"7">> = run(Config,
        "globalThis.Counter = class {\n"
        "  constructor(n) { this.n = n; }\n"
        "  add(x) { this.n += x; return this.n; }\n"
        "};\n",
        "main() ->\n"
        "    C = concrete_js:new(<<\"Counter\">>, [3]),\n"
        "    concrete_js:call(C, <<\"add\">>, [4]).\n").

js_get_set_roundtrip(Config) ->
    <<"99">> = run(Config,
        "globalThis.Box = class { constructor() { this.value = 1; } };\n",
        "main() ->\n"
        "    B = concrete_js:new(<<\"Box\">>, []),\n"
        "    concrete_js:set(B, <<\"value\">>, 99),\n"
        "    concrete_js:get(B, <<\"value\">>).\n").

js_instanceof_and_typeof(Config) ->
    <<"{true, <<\"number\">>}">> = run(Config,
        "globalThis.Box = class {};\n",
        "main() ->\n"
        "    B = concrete_js:new(<<\"Box\">>, []),\n"
        "    {concrete_js:instanceof(B, <<\"Box\">>), concrete_js:typeof(42)}.\n").

%% A native call that throws surfaces as the same {js_error, Reason}
%% tagged error an uncaught native exception in a plain try/catch
%% already raises (runtime.js's Interpreter.tryCatch) -- catchable with
%% ordinary Erlang try/catch, not a special interop-only mechanism.
js_error_caught(Config) ->
    <<"caught">> = run(Config, "",
        "main() ->\n"
        "    try concrete_js:call(<<\"Math.doesNotExist\">>, []) of\n"
        "        _ -> ok\n"
        "    catch error:{js_error, _} -> caught\n"
        "    end.\n").

%% Proves Args is unboxed to a real JS array, not a boxed Concrete list
%% -- .reduce is a native Array method that would throw on a
%% {type:"list", data:[...]} object.
js_list_arg_unboxed_as_array(Config) ->
    <<"6">> = run(Config,
        "globalThis.sum = (arr) => arr.reduce((a, b) => a + b, 0);\n",
        "main() -> concrete_js:call(<<\"sum\">>, [[1, 2, 3]]).\n").

%% Proves a Concrete map argument becomes a plain JS object with string
%% keys, not a boxed map term.
js_map_arg_unboxed_as_object(Config) ->
    <<"5">> = run(Config,
        "globalThis.readX = (obj) => obj.x;\n",
        "main() -> concrete_js:call(<<\"readX\">>, [#{x => 5}]).\n").

%% Receiver/ClassPath/Method/Prop accept atoms as well as binaries --
%% 'THREE.Scene' (quoted, not a valid bare atom) and a plain unquoted
%% atom (add) for a method name known at compile time.
js_atom_paths_work_like_binaries(Config) ->
    <<"7">> = run(Config,
        "globalThis.THREE = { Counter: class {\n"
        "  constructor(n) { this.n = n; }\n"
        "  add(x) { this.n += x; return this.n; }\n"
        "} };\n",
        "main() ->\n"
        "    C = concrete_js:new('THREE.Counter', [3]),\n"
        "    concrete_js:call(C, add, [4]).\n").

%% --- concrete_js:await/1 ---
%%
%% await/1 only registers interest and returns a ref; it never blocks
%% on its own. Its receiver is what actually blocks -- and it can be
%% main/0 itself here, no inner spawn/1 needed in the test source,
%% because run_spawned/3 (below) spawns main/0 as a real process
%% directly, the same way compiled spawn/1 would. A real process can
%% suspend across genuine async time and be resumed later by an
%% out-of-band message; that's exactly what a promise settling later
%% is. Node's event loop keeps running as long as that promise has a
%% pending .then(), so the process (and the script) doesn't exit until
%% it resolves and main/0's own receive completes.

js_await_resolved_promise(Config) ->
    Out = run_spawned(Config,
        "globalThis.resolvedPromise = () => Promise.resolve(42);\n",
        "main() ->\n"
        "    Promise = concrete_js:call(<<\"resolvedPromise\">>, []),\n"
        "    Ref = concrete_js:await(Promise),\n"
        "    receive\n"
        "        {Ref, ok, Value} -> debug:log(Value)\n"
        "    end.\n"),
    {_, _} = binary:match(Out, <<"42">>).

%% Same shape, but the promise resolves via a real setTimeout, proving
%% the "message arrives arbitrarily later" path actually works, not
%% just the same-tick (still-a-microtask) resolved case above.
js_await_deferred_promise(Config) ->
    Out = run_spawned(Config,
        "globalThis.deferredPromise = () =>\n"
        "  new Promise((resolve) => setTimeout(() => resolve(99), 20));\n",
        "main() ->\n"
        "    Promise = concrete_js:call(<<\"deferredPromise\">>, []),\n"
        "    Ref = concrete_js:await(Promise),\n"
        "    receive\n"
        "        {Ref, ok, Value} -> debug:log(Value)\n"
        "    end.\n"),
    {_, _} = binary:match(Out, <<"99">>).

js_await_rejected_promise(Config) ->
    Out = run_spawned(Config,
        "globalThis.rejectedPromise = () => Promise.reject(\"boom\");\n",
        "main() ->\n"
        "    Promise = concrete_js:call(<<\"rejectedPromise\">>, []),\n"
        "    Ref = concrete_js:await(Promise),\n"
        "    receive\n"
        "        {Ref, error, Reason} -> debug:log(Reason)\n"
        "    end.\n"),
    {_, _} = binary:match(Out, <<"boom">>).

%% await/1 is only meaningful inside a spawned process -- calling it
%% directly raises {js_error, _} instead of silently sending a reply
%% nothing will ever receive. Non-blocking (no receive needed), so a
%% plain callTopLevel round trip is enough to check it.
js_await_outside_spawn_errors(Config) ->
    <<"caught">> = run_blocking(Config, "",
        "main() ->\n"
        "    try concrete_js:await(dummy) of\n"
        "        _ -> ok\n"
        "    catch error:{js_error, _} -> caught\n"
        "    end.\n").

%% --- Erlang funs as JS callbacks ---
%%
%% jsUnbox wraps any fun argument as a real, callable JS function --
%% every concrete_js:* argument already goes through jsUnbox, so no new
%% BIF is needed. These mock a plain global function that invokes its
%% callback with a controlled argument count, rather than depending on
%% a real DOM/array API's exact calling convention.

js_callback_fun_receives_one_arg(Config) ->
    <<"42">> = run(Config,
        "globalThis.callWithOne = (fn) => fn(21);\n",
        "main() -> concrete_js:call(<<\"callWithOne\">>, [fun(X) -> X * 2 end]).\n").

js_callback_fun_receives_two_args(Config) ->
    <<"7">> = run(Config,
        "globalThis.callWithTwo = (fn) => fn(3, 4);\n",
        "main() -> concrete_js:call(<<\"callWithTwo\">>, [fun(A, B) -> A + B end]).\n").

%% The wrapped fun keeps its closed-over bindings.
js_callback_fun_closure(Config) ->
    <<"31">> = run(Config,
        "globalThis.callWithOne = (fn) => fn(21);\n",
        "main() ->\n"
        "    N = 10,\n"
        "    F = fun(X) -> X + N end,\n"
        "    concrete_js:call(<<\"callWithOne\">>, [F]).\n").

%% A callback fun invoked from native JS is a "cold entry point" the
%% same way a dom:on_click handler is -- if it blocks (contains
%% receive) and never finishes in one step, that's the same
%% runEphemeral guard callTopLevel already uses, not a new mechanism.
js_callback_fun_blocking_errors(Config) ->
    <<"caught">> = run(Config,
        "globalThis.callWithOne = (fn) => fn(21);\n",
        "main() ->\n"
        "    try concrete_js:call(<<\"callWithOne\">>, [fun(_X) -> receive never -> ok end end]) of\n"
        "        _ -> ok\n"
        "    catch error:{js_error, _} -> caught\n"
        "    end.\n").

%% The native call invokes the callback with one argument; the fun
%% declares two -- Interpreter.callAnon's own badarity check fires,
%% same as calling any other fun with the wrong number of arguments.
js_callback_fun_arity_mismatch_errors(Config) ->
    <<"caught">> = run(Config,
        "globalThis.callWithOne = (fn) => fn(21);\n",
        "main() ->\n"
        "    try concrete_js:call(<<\"callWithOne\">>, [fun(A, B) -> A + B end]) of\n"
        "        _ -> ok\n"
        "    catch error:{js_error, _} -> caught\n"
        "    end.\n").

%% --- Harness ---

run(Config, Body) ->
    run(Config, "", Body).

%% GlobalsJS is injected before runtime.js loads, so it can set up
%% globalThis bindings (mocking a <script>-tag-loaded library) that
%% concrete_js:* BIFs resolve dotted paths against.
run(Config, GlobalsJS, Body) ->
    Src = "-module(m).\n" ++ Body,
    JS = compile(Src),
    RuntimePath = filename:join([code:priv_dir(concrete), "js", "demo", "runtime.js"]),
    {ok, Runtime} = file:read_file(RuntimePath),
    Script = [
        <<"const window = {};\n">>,
        unicode:characters_to_binary(GlobalsJS),
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

%% For a main/0 that itself blocks (contains a receive) -- run/3 above
%% invokes main/0 via a bare Interpreter.call, which only works for
%% non-blocking code; a blocking main/0 needs Interpreter.callTopLevel
%% instead (same reason concrete_js:await/1 only works inside spawn/1
%% in the first place -- see process_SUITE.erl's run_modules/3, same
%% shape, generalized here with GlobalsJS injection).
run_blocking(Config, GlobalsJS, Body) ->
    Src = "-module(m).\n" ++ Body,
    JS = compile(Src),
    RuntimePath = filename:join([code:priv_dir(concrete), "js", "demo", "runtime.js"]),
    {ok, Runtime} = file:read_file(RuntimePath),
    Script = [
        <<"const window = {};\n">>,
        unicode:characters_to_binary(GlobalsJS),
        Runtime,
        JS,
        <<"console.log(termToString(Interpreter.callTopLevel(\"m\", \"main\", 0, [])));\n">>
    ],
    File = filename:join(?config(priv_dir, Config),
                         atom_to_list(?FUNCTION_NAME) ++ "_"
                         ++ integer_to_list(erlang:unique_integer([positive]))
                         ++ ".js"),
    ok = file:write_file(File, unicode:characters_to_binary(Script)),
    Out = os:cmd("node " ++ File ++ " 2>&1"),
    iolist_to_binary(string:trim(Out)).

%% For a main/0 that may need to genuinely suspend across real async
%% time, not just complete within one synchronous step -- run_blocking/3
%% above uses Interpreter.callTopLevel, which throws if main/0 isn't
%% done after a single .next() (fine for a receive that resolves
%% same-tick, e.g. process_SUITE.erl's ping-pong tests; wrong for one
%% waiting on a Promise). This spawns main/0 itself as a real process
%% instead, the same way compiled spawn/1 would (Interpreter.spawnProcess
%% just needs an object with a .callable -- an ordinary Type.anon_fun
%% term qualifies, and so does this bare object), so it can sit blocked
%% in the processes table and be resumed whenever something -- same
%% tick, or arbitrarily later -- sends it a message. No console.log
%% here: main/0's own receive clause is expected to observe the result
%% itself (typically via debug:log/1), since there's nothing to
%% synchronously return to the caller of spawnProcess.
run_spawned(Config, GlobalsJS, Body) ->
    Src = "-module(m).\n" ++ Body,
    JS = compile(Src),
    RuntimePath = filename:join([code:priv_dir(concrete), "js", "demo", "runtime.js"]),
    {ok, Runtime} = file:read_file(RuntimePath),
    Script = [
        <<"const window = {};\n">>,
        unicode:characters_to_binary(GlobalsJS),
        Runtime,
        JS,
        <<"Interpreter.spawnProcess({ callable: () => Interpreter.call(\"m\", \"main\", 0, []) });\n">>
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
