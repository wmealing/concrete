%% Phase 2: Call graph builder and dead-code elimination tests.
-module(call_graph_SUITE).
-include_lib("common_test/include/ct.hrl").
-include("concrete_ir.hrl").

-export([all/0, groups/0]).
-export([
    reachable_includes_entry/1,
    transitive_calls_followed/1,
    unreachable_excluded/1,
    not_found_mfa_skipped/1,
    remote_call_followed/1,
    page_entries_includes_action_excludes_command/1,
    page_entries_includes_mount_when_present/1,
    page_entries_excludes_mount_when_absent/1,
    mount_root_reaches_helper/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [
        reachable_includes_entry,
        transitive_calls_followed,
        unreachable_excluded,
        not_found_mfa_skipped,
        remote_call_followed,
        page_entries_includes_action_excludes_command,
        page_entries_includes_mount_when_present,
        page_entries_excludes_mount_when_absent,
        mount_root_reaches_helper
    ]}].
%% Build a PLT and a minimal page module that has init/2 and template/0.
base_plt() ->
    PLT = concrete_plt:new(),
    %% page_mod:init/2 — calls page_mod:helper/0
    InitDef = #ir_function_def{
        name = init, arity = 2,
        clauses = [#ir_clause{
            patterns = [#ir_wildcard{}, #ir_wildcard{}],
            guards   = [],
            body     = [#ir_local_call{name = helper, arity = 0, args = []}]
        }]
    },
    %% page_mod:template/0 — returns atom
    TplDef = #ir_function_def{
        name = template, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = <<"page.slab">>}]}]
    },
    %% page_mod:helper/0 — returns ok
    HelperDef = #ir_function_def{
        name = helper, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    %% page_mod:unused/0 — not reachable
    UnusedDef = #ir_function_def{
        name = unused, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = never}]}]
    },
    concrete_plt:put(PLT, {page_mod, init,     2}, InitDef),
    concrete_plt:put(PLT, {page_mod, template, 0}, TplDef),
    concrete_plt:put(PLT, {page_mod, helper,   0}, HelperDef),
    concrete_plt:put(PLT, {page_mod, unused,   0}, UnusedDef),
    PLT.

reachable_includes_entry(_Config) ->
    PLT      = base_plt(),
    G        = concrete_call_graph:build(page_mod, PLT),
    Reachable = concrete_call_graph:reachable(G),
    true = lists:member({page_mod, init,     2}, Reachable),
    true = lists:member({page_mod, template, 0}, Reachable).

transitive_calls_followed(_Config) ->
    PLT       = base_plt(),
    G         = concrete_call_graph:build(page_mod, PLT),
    Reachable = concrete_call_graph:reachable(G),
    %% helper/0 is called by init/2, so must be reachable
    true = lists:member({page_mod, helper, 0}, Reachable).

unreachable_excluded(_Config) ->
    PLT       = base_plt(),
    G         = concrete_call_graph:build(page_mod, PLT),
    Reachable = concrete_call_graph:reachable(G),
    %% unused/0 is never called, must not appear
    false = lists:member({page_mod, unused, 0}, Reachable).

not_found_mfa_skipped(_Config) ->
    %% If a called MFA is not in the PLT, build/2 should not crash.
    PLT = concrete_plt:new(),
    InitDef = #ir_function_def{
        name = init, arity = 2,
        clauses = [#ir_clause{
            patterns = [#ir_wildcard{}, #ir_wildcard{}],
            guards   = [],
            body     = [#ir_local_call{name = ghost, arity = 0, args = []}]
        }]
    },
    TplDef = #ir_function_def{
        name = template, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    concrete_plt:put(PLT, {pg_mod, init,     2}, InitDef),
    concrete_plt:put(PLT, {pg_mod, template, 0}, TplDef),
    %% ghost/0 is NOT in the PLT — should be silently skipped
    G = concrete_call_graph:build(pg_mod, PLT),
    Reachable = concrete_call_graph:reachable(G),
    true = lists:member({pg_mod, init, 2}, Reachable).

remote_call_followed(_Config) ->
    %% A remote call to another module should add the callee to the graph.
    PLT = concrete_plt:new(),
    InitDef = #ir_function_def{
        name = init, arity = 2,
        clauses = [#ir_clause{
            patterns = [#ir_wildcard{}, #ir_wildcard{}],
            guards   = [],
            body     = [#ir_remote_call{
                module   = #ir_atom{value = other_mod},
                function = #ir_atom{value = compute},
                arity    = 0, args    = []
            }]
        }]
    },
    TplDef = #ir_function_def{
        name = template, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    OtherDef = #ir_function_def{
        name = compute, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_integer{value = 42}]}]
    },
    concrete_plt:put(PLT, {rm, init,            2}, InitDef),
    concrete_plt:put(PLT, {rm, template,        0}, TplDef),
    concrete_plt:put(PLT, {other_mod, compute,  0}, OtherDef),
    G = concrete_call_graph:build(rm, PLT),
    Reachable = concrete_call_graph:reachable(G),
    true = lists:member({other_mod, compute, 0}, Reachable).

%% Regression test: command/3 must never be a root, unlike action/3.
%% No dispatch path ever runs command/3 as compiled JS (both
%% concrete_command_handler and concrete_ws_handler call it as an
%% ordinary Erlang function on the real BEAM), so including it here
%% used to force its body through the JS encoder for no reason,
%% breaking any stdlib call the encoder doesn't special-case.
page_entries_includes_action_excludes_command(_Config) ->
    PLT = concrete_plt:new(),
    TplDef = #ir_function_def{
        name = template, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    ActionDef = #ir_function_def{
        name = action, arity = 3,
        clauses = [#ir_clause{patterns = [#ir_wildcard{}, #ir_wildcard{}, #ir_wildcard{}],
                              guards = [], body = [#ir_atom{value = ok}]}]
    },
    CommandDef = #ir_function_def{
        name = command, arity = 3,
        clauses = [#ir_clause{patterns = [#ir_wildcard{}, #ir_wildcard{}, #ir_wildcard{}],
                              guards = [], body = [#ir_atom{value = ok}]}]
    },
    concrete_plt:put(PLT, {ac_mod, template, 0}, TplDef),
    concrete_plt:put(PLT, {ac_mod, action,   3}, ActionDef),
    concrete_plt:put(PLT, {ac_mod, command,  3}, CommandDef),
    Entries = concrete_call_graph:page_entries(ac_mod, PLT),
    true  = lists:member({ac_mod, action, 3}, Entries),
    false = lists:member({ac_mod, command, 3}, Entries).

%% mount/1 is a root exactly like action/3: present in the PLT ->
%% present in page_entries/2's output.
page_entries_includes_mount_when_present(_Config) ->
    PLT = concrete_plt:new(),
    TplDef = #ir_function_def{
        name = template, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    MountDef = #ir_function_def{
        name = mount, arity = 1,
        clauses = [#ir_clause{patterns = [#ir_wildcard{}], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    concrete_plt:put(PLT, {mnt_mod, template, 0}, TplDef),
    concrete_plt:put(PLT, {mnt_mod, mount,    1}, MountDef),
    Entries = concrete_call_graph:page_entries(mnt_mod, PLT),
    true = lists:member({mnt_mod, mount, 1}, Entries).

%% The overwhelming common case -- no mount/1 defined -- must not gain
%% a phantom root.
page_entries_excludes_mount_when_absent(_Config) ->
    PLT = concrete_plt:new(),
    TplDef = #ir_function_def{
        name = template, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    concrete_plt:put(PLT, {no_mnt_mod, template, 0}, TplDef),
    Entries = concrete_call_graph:page_entries(no_mnt_mod, PLT),
    false = lists:member({no_mnt_mod, mount, 1}, Entries).

%% The actual point of mount/1 being a real root (not just present in
%% page_entries/2's list): a helper only ever reached through mount/1
%% must survive ordinary call-graph tracing, the same way a helper
%% reached only through action/3 already does -- no dead
%% `case false of true -> ... end` branch required to keep it alive.
mount_root_reaches_helper(_Config) ->
    PLT = concrete_plt:new(),
    TplDef = #ir_function_def{
        name = template, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    MountDef = #ir_function_def{
        name = mount, arity = 1,
        clauses = [#ir_clause{
            patterns = [#ir_wildcard{}], guards = [],
            body     = [#ir_local_call{name = mount_helper, arity = 0, args = []}]
        }]
    },
    HelperDef = #ir_function_def{
        name = mount_helper, arity = 0,
        clauses = [#ir_clause{patterns = [], guards = [],
                              body = [#ir_atom{value = ok}]}]
    },
    concrete_plt:put(PLT, {mh_mod, template,     0}, TplDef),
    concrete_plt:put(PLT, {mh_mod, mount,        1}, MountDef),
    concrete_plt:put(PLT, {mh_mod, mount_helper, 0}, HelperDef),
    G = concrete_call_graph:build(mh_mod, PLT),
    Reachable = concrete_call_graph:reachable(G),
    true = lists:member({mh_mod, mount_helper, 0}, Reachable).
