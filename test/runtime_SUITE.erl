%% Phase 4: Action/command dispatch runtime tests.
%% Uses inline test modules compiled at runtime via compile:forms/2.
-module(runtime_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    dispatch_action_calls_callback/1,
    dispatch_action_default_error/1,
    dispatch_command_calls_callback/1,
    dispatch_command_default_error/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [
        dispatch_action_calls_callback,
        dispatch_action_default_error,
        dispatch_command_calls_callback,
        dispatch_command_default_error
    ]}].
%% Compile and load a minimal component module for testing.
init_per_suite(Config) ->
    ActionSrc = [
        "-module(test_action_component).",
        "-behaviour(concrete_component).",
        "-export([init/2, action/3, template/0]).",
        "init(_P, S) -> {#{state => #{}}, S}.",
        "action(increment, _Params, #{state := #{count := N} = St} = C) ->",
        "  C#{state => St#{count => N + 1}}.",
        "template() -> \"test.slab\"."
    ],
    CommandSrc = [
        "-module(test_command_component).",
        "-behaviour(concrete_component).",
        "-export([init/2, command/3, template/0]).",
        "init(_P, S) -> {#{state => #{}}, S}.",
        "command(fetch, _Params, Server) -> Server#{fetched => true}.",
        "template() -> \"test.slab\"."
    ],
    load_module(ActionSrc),
    load_module(CommandSrc),
    Config.

end_per_suite(_Config) ->
    code:purge(test_action_component),
    code:delete(test_action_component),
    code:purge(test_command_component),
    code:delete(test_command_component),
    ok.

load_module(Lines) ->
    Src   = string:join(Lines, "\n"),
    Forms = parse_forms(Src),
    {ok, Mod, Bin} = compile:forms(Forms, []),
    {module, Mod}  = code:load_binary(Mod, "", Bin).

parse_forms(Src) ->
    parse_all_forms(Src).

parse_all_forms(Src) ->
    Tokens0 = scan_all(Src),
    parse_forms_loop(Tokens0, []).

scan_all(Src) ->
    {ok, Tokens, _} = erl_scan:string(Src),
    Tokens.

parse_forms_loop([], Acc) ->
    lists:reverse(Acc);
parse_forms_loop(Tokens, Acc) ->
    case split_at_dot(Tokens) of
        {[], _Rest} -> lists:reverse(Acc);
        {FormTokens, Rest} ->
            case erl_parse:parse_form(FormTokens) of
                {ok, Form} -> parse_forms_loop(Rest, [Form | Acc]);
                _          -> parse_forms_loop(Rest, Acc)
            end
    end.

split_at_dot(Tokens) ->
    split_at_dot(Tokens, []).

split_at_dot([], Acc) ->
    {lists:reverse(Acc), []};
split_at_dot([{dot, _} = D | Rest], Acc) ->
    {lists:reverse([D | Acc]), Rest};
split_at_dot([H | T], Acc) ->
    split_at_dot(T, [H | Acc]).

%% --- Tests ---

dispatch_action_calls_callback(_Config) ->
    Component = #{state => #{count => 0}},
    Result = concrete_runtime:dispatch_action(
        test_action_component, increment, #{}, Component),
    #{state := #{count := 1}} = Result.

dispatch_action_default_error(_Config) ->
    %% Module with no action/3 exported — should hit the default error handler.
    Component = #{state => #{}},
    try
        concrete_runtime:dispatch_action(
            test_command_component, increment, #{}, Component),
        ct:fail(expected_error)
    catch
        error:{unhandled_action, increment} -> ok
    end.

dispatch_command_calls_callback(_Config) ->
    Server = #{},
    Result = concrete_runtime:dispatch_command(
        test_command_component, fetch, #{}, Server),
    #{fetched := true} = Result.

dispatch_command_default_error(_Config) ->
    Server = #{},
    try
        concrete_runtime:dispatch_command(
            test_action_component, fetch, #{}, Server),
        ct:fail(expected_error)
    catch
        error:{unhandled_command, fetch} -> ok
    end.
