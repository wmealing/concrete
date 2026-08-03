%% Execution round-trip tests for spawn/self/!/receive compiled to JS
%% and run in Node.js against priv/js/demo/runtime.js -- same harness
%% as js_exec_SUITE.erl. See the distributed-wiggling-flame plan for
%% the generator-based process model these exercise.
-module(process_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    ping_pong/1,
    selective_receive/1,
    receive_non_tail_expression/1,
    case_nested_in_receive/1,
    dynamic_dispatch/1,
    blocking_fun_into_lists_foreach/1,
    non_blocking_lists_map_unaffected/1,
    gen_server_round_trip/1
]).

all() ->
    [{group, all_parallel}].

groups() ->
    [{all_parallel, [parallel], [
        ping_pong,
        selective_receive,
        receive_non_tail_expression,
        case_nested_in_receive,
        dynamic_dispatch,
        blocking_fun_into_lists_foreach,
        non_blocking_lists_map_unaffected,
        gen_server_round_trip
    ]}].

init_per_suite(Config) ->
    case os:find_executable("node") of
        false -> {skip, "node not found on PATH"};
        _     -> Config
    end.

end_per_suite(_Config) ->
    ok.

%% --- Basic spawn/self/!/receive ---

ping_pong(Config) ->
    <<"hello">> = run(Config,
        "main() ->\n"
        "    Pid = spawn(fun echoer/0),\n"
        "    Pid ! {self(), hello},\n"
        "    receive\n"
        "        {reply, X} -> X\n"
        "    end.\n"
        "echoer() ->\n"
        "    receive\n"
        "        {From, Msg} -> From ! {reply, Msg}\n"
        "    end.\n").

%% Mailbox holds [first, second] when the receive arrives; `first`
%% doesn't match any clause, so real Erlang receive semantics (scan
%% forward, skip non-matching, leave it in the mailbox) must pick
%% `second` -- not just "the first clause, against the first message".
selective_receive(Config) ->
    <<"got_second">> = run(Config,
        "main() ->\n"
        "    Self = self(),\n"
        "    Pid = spawn(fun() -> collector(Self) end),\n"
        "    Pid ! first,\n"
        "    Pid ! second,\n"
        "    receive\n"
        "        {result, R} -> R\n"
        "    end.\n"
        "collector(Caller) ->\n"
        "    receive\n"
        "        second -> Caller ! {result, got_second}\n"
        "    end.\n").

%% --- Full generality: receive doesn't need to be the last statement,
%% and a case may be nested directly inside a receive clause. ---

receive_non_tail_expression(Config) ->
    <<"24">> = run(Config,
        "main() ->\n"
        "    Pid = spawn(fun doubler/0),\n"
        "    Pid ! {self(), 6},\n"
        "    X = receive\n"
        "        {reply, V} -> V\n"
        "    end,\n"
        "    X + X.\n"
        "doubler() ->\n"
        "    receive\n"
        "        {From, N} -> From ! {reply, N * 2}\n"
        "    end.\n").

case_nested_in_receive(Config) ->
    <<"{1, 2, stopped}">> = run(Config,
        "main() ->\n"
        "    Pid = spawn(fun() -> loop(0) end),\n"
        "    R1 = call(Pid, bump),\n"
        "    R2 = call(Pid, bump),\n"
        "    Pid ! {self(), stop},\n"
        "    R3 = receive {done, D} -> D end,\n"
        "    {R1, R2, R3}.\n"
        "call(Pid, Msg) ->\n"
        "    Pid ! {self(), Msg},\n"
        "    receive {reply, R} -> R end.\n"
        "loop(N) ->\n"
        "    receive\n"
        "        {From, Msg} ->\n"
        "            case Msg of\n"
        "                bump -> From ! {reply, N + 1}, loop(N + 1);\n"
        "                stop -> From ! {done, stopped}\n"
        "            end\n"
        "    end.\n").

%% --- Dynamic dispatch: Module:Function(Args) with Module a variable ---

dynamic_dispatch(Config) ->
    <<"9">> = run_modules(Config,
        ["-module(math_helper).\n"
         "-export([square/1]).\n"
         "square(X) -> X * X.\n",
         "-module(driver).\n"
         "-export([main/0, dispatch/3]).\n"
         "main() -> dispatch(math_helper, square, 3).\n"
         "dispatch(Mod, Fun, Arg) -> Mod:Fun(Arg).\n"],
        "driver").

%% --- A literal blocking fun passed to a higher-order stdlib BIF ---

blocking_fun_into_lists_foreach(Config) ->
    <<"[1, 2, 3]">> = run(Config,
        "main() ->\n"
        "    Pid = spawn(fun collector/0),\n"
        "    lists:foreach(fun(X) ->\n"
        "        Pid ! {self(), X},\n"
        "        receive {reply, ok} -> ok end\n"
        "    end, [1, 2, 3]),\n"
        "    Pid ! {self(), done},\n"
        "    receive {result, R} -> R end.\n"
        "collector() -> collector([]).\n"
        "collector(Acc) ->\n"
        "    receive\n"
        "        {From, done} -> From ! {result, lists:reverse(Acc)};\n"
        "        {From, X} -> From ! {reply, ok}, collector([X | Acc])\n"
        "    end.\n").

%% A plain (non-blocking) lists:map usage must be completely unaffected
%% by the higher-order-BIF blocking analysis.
non_blocking_lists_map_unaffected(Config) ->
    <<"[2, 4, 6]">> = run(Config,
        "main() -> lists:map(fun(X) -> X * 2 end, [1, 2, 3]).\n").

%% --- The payoff: the actual concrete_gen_server.erl + counter_server.erl
%% sources (not a simplified inline copy), compiled and run together. ---

gen_server_round_trip(Config) ->
    GenServerSrc = read_example("concrete_gen_server.erl"),
    CallbackSrc  = read_example("counter_server.erl"),
    Driver =
        "-module(driver).\n"
        "-export([main/0]).\n"
        "main() ->\n"
        "    {ok, Pid} = concrete_gen_server:start_link(counter_server, 0),\n"
        "    R1 = concrete_gen_server:call(Pid, increment),\n"
        "    R2 = concrete_gen_server:call(Pid, increment),\n"
        "    R3 = concrete_gen_server:call(Pid, get),\n"
        "    ok = concrete_gen_server:cast(Pid, reset),\n"
        "    R4 = concrete_gen_server:call(Pid, get),\n"
        "    ok = concrete_gen_server:stop(Pid),\n"
        "    {R1, R2, R3, R4}.\n",
    <<"{1, 2, 2, 0}">> = run_modules(Config,
        [GenServerSrc, CallbackSrc, Driver], "driver").

%% --- Harness (same shape as js_exec_SUITE:run/2, generalized to
%% compile+link several independently-named modules) ---

run(Config, Body) ->
    Src = "-module(m).\n" ++ Body,
    run_modules(Config, [Src], "m").

run_modules(Config, Sources, EntryModule) ->
    JsFragments = [compile(Src) || Src <- Sources],
    RuntimePath = filename:join([code:priv_dir(concrete), "js", "demo", "runtime.js"]),
    {ok, Runtime} = file:read_file(RuntimePath),
    Script = [
        <<"const window = {};\n">>,
        Runtime,
        JsFragments,
        io_lib:format("console.log(termToString(Interpreter.callTopLevel(~p, \"main\", 0, [])));~n",
                       [EntryModule])
    ],
    File = filename:join(?config(priv_dir, Config),
                         atom_to_list(?FUNCTION_NAME) ++ "_"
                         ++ integer_to_list(erlang:unique_integer([positive]))
                         ++ ".js"),
    ok = file:write_file(File, unicode:characters_to_binary(Script)),
    Out = os:cmd("node " ++ File ++ " 2>&1"),
    iolist_to_binary(string:trim(Out)).

%% example/*.erl isn't part of the "concrete" OTP app (it's compiled
%% only under the `example` rebar3 profile, see rebar.config), so it
%% has no code:priv_dir/lib_dir of its own to anchor from. Anchor off
%% concrete's own lib_dir instead (<repo>/_build/<profile>/lib/concrete)
%% and walk up to the repo root, rather than assuming cwd.
read_example(Filename) ->
    Path = filename:join([code:lib_dir(concrete), "..", "..", "..", "..",
                          "example", Filename]),
    {ok, Bin} = file:read_file(Path),
    Bin.

compile(Src) when is_binary(Src) ->
    compile(unicode:characters_to_list(Src));
compile(Src) ->
    {ok, Tokens, _} = erl_scan:string(Src),
    Forms = parse_all(Tokens, []),
    ModName = module_name(Forms),
    Ctx = concrete_transformer:new_ctx(ModName),
    IR = concrete_transformer:transform_module(Forms, Ctx),
    iolist_to_binary(concrete_encoder:encode_module(IR)).

module_name(Forms) ->
    hd([Name || {attribute, _, module, Name} <- Forms]).

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
