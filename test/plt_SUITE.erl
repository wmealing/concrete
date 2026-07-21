%% Phase 2: Persistent Lookup Table (PLT) tests.
-module(plt_SUITE).
-include_lib("common_test/include/ct.hrl").
-include("concrete_ir.hrl").

-export([all/0, groups/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    put_and_get/1,
    get_missing/1,
    all_mfas/1,
    overwrite/1,
    save_and_load/1,
    load_or_new_existing/1,
    load_or_new_missing/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [put_and_get, get_missing, all_mfas, overwrite,
     save_and_load, load_or_new_existing, load_or_new_missing]}].
init_per_testcase(_TestCase, Config) ->
    PLT = concrete_plt:new(),
    [{plt, PLT} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

sample_def() ->
    #ir_function_def{name = foo, arity = 0, clauses = []}.

put_and_get(_Config) ->
    PLT = concrete_plt:new(),
    IR  = sample_def(),
    concrete_plt:put(PLT, {my_mod, foo, 0}, IR),
    {ok, IR} = concrete_plt:get(PLT, {my_mod, foo, 0}).

get_missing(_Config) ->
    PLT = concrete_plt:new(),
    not_found = concrete_plt:get(PLT, {missing, func, 0}).

all_mfas(_Config) ->
    PLT = concrete_plt:new(),
    concrete_plt:put(PLT, {m, f, 0}, sample_def()),
    concrete_plt:put(PLT, {m, g, 1}, sample_def()),
    MFAs = concrete_plt:all_mfas(PLT),
    2 = length(MFAs),
    true = lists:member({m, f, 0}, MFAs),
    true = lists:member({m, g, 1}, MFAs).

overwrite(_Config) ->
    PLT  = concrete_plt:new(),
    IR1  = #ir_function_def{name = foo, arity = 0, clauses = []},
    IR2  = #ir_function_def{name = foo, arity = 1, clauses = []},
    concrete_plt:put(PLT, {m, foo, 0}, IR1),
    concrete_plt:put(PLT, {m, foo, 0}, IR2),
    {ok, IR2} = concrete_plt:get(PLT, {m, foo, 0}).

save_and_load(Config) ->
    PLT  = proplists:get_value(plt, Config),
    IR   = sample_def(),
    concrete_plt:put(PLT, {my_mod, foo, 0}, IR),
    Path = filename:join(?config(priv_dir, Config), "test.plt"),
    ok   = concrete_plt:save(PLT, Path),
    {ok, PLT2} = concrete_plt:load(Path),
    {ok, IR}   = concrete_plt:get(PLT2, {my_mod, foo, 0}).

load_or_new_existing(Config) ->
    PLT  = proplists:get_value(plt, Config),
    IR   = sample_def(),
    concrete_plt:put(PLT, {m, f, 0}, IR),
    Path = filename:join(?config(priv_dir, Config), "test2.plt"),
    ok   = concrete_plt:save(PLT, Path),
    PLT2 = concrete_plt:load_or_new(Path),
    {ok, IR} = concrete_plt:get(PLT2, {m, f, 0}).

load_or_new_missing(_Config) ->
    PLT = concrete_plt:load_or_new("/nonexistent/path/to.plt"),
    true = is_reference(PLT) orelse is_atom(PLT) orelse is_integer(PLT),
    not_found = concrete_plt:get(PLT, {any, func, 0}).
