%% Builds an MFA dependency graph from IR and performs dead-code elimination.
-module(concrete_call_graph).
-include("concrete_ir.hrl").

-export([build/2, build_from_entries/2, reachable/1]).

-type mfa_key() :: {module(), atom(), arity()}.

%% Build a call graph rooted at the page/component module's entry
%% points: init/2 and template/0 are always roots (the JS runtime calls
%% them directly, not via any traceable Erlang call); action/3 and
%% command/3 are roots too when present — the browser dispatches to
%% them directly from a concrete-click handler, never via a call
%% reachable from init/2, so plain call-graph tracing would otherwise
%% mark them (wrongly) as dead code.
-spec build(module(), term()) -> digraph:graph().
build(PageModule, PLT) ->
    BaseEntries = [{PageModule, init, 2}, {PageModule, template, 0}],
    ExtraEntries = [E || E <- [{PageModule, action, 3}, {PageModule, command, 3}],
                          concrete_plt:get(PLT, E) =/= not_found],
    build_from_entries(BaseEntries ++ ExtraEntries, PLT).

%% Build a call graph rooted at an explicit list of entry MFAs — used to
%% additionally root the graph at component modules embedded via
%% <:component> template tags, which aren't reachable through ordinary
%% Erlang calls in the page module's own code.
-spec build_from_entries([mfa_key()], term()) -> digraph:graph().
build_from_entries(Entries, PLT) ->
    G = digraph:new(),
    walk(Entries, G, PLT, sets:new()),
    G.

%% Return the set of reachable MFAs in topological order.
-spec reachable(digraph:graph()) -> [mfa_key()].
reachable(G) ->
    digraph_utils:topsort(G).

walk([], _G, _PLT, _Visited) ->
    ok;
walk([MFA | Rest], G, PLT, Visited) ->
    case sets:is_element(MFA, Visited) of
        true ->
            walk(Rest, G, PLT, Visited);
        false ->
            Visited2 = sets:add_element(MFA, Visited),
            digraph:add_vertex(G, MFA),
            case concrete_plt:get(PLT, MFA) of
                {ok, FunDef} ->
                    Callees = collect_calls(MFA, FunDef),
                    [begin
                         digraph:add_vertex(G, Callee),
                         digraph:add_edge(G, MFA, Callee)
                     end || Callee <- Callees],
                    walk(Callees ++ Rest, G, PLT, Visited2);
                not_found ->
                    walk(Rest, G, PLT, Visited2)
            end
    end.

-spec collect_calls(mfa_key(), #ir_function_def{}) -> [mfa_key()].
collect_calls({Mod, _, _}, #ir_function_def{clauses = Clauses}) ->
    lists:usort(lists:flatmap(fun(C) -> calls_in_clause(Mod, C) end, Clauses)).

calls_in_clause(Mod, #ir_clause{body = Body}) ->
    lists:flatmap(fun(E) -> calls_in_ir(Mod, E) end, Body).

calls_in_ir(_Mod, #ir_remote_call{module = #ir_atom{value = M},
                                  function = #ir_atom{value = F},
                                  arity = A}) ->
    [{M, F, A}] ++ [];
calls_in_ir(Mod, #ir_local_call{name = F, arity = A}) ->
    [{Mod, F, A}];
calls_in_ir(Mod, #ir_case{expr = E, clauses = Cls}) ->
    calls_in_ir(Mod, E) ++ lists:flatmap(fun(C) -> calls_in_clause(Mod, C) end, Cls);
calls_in_ir(Mod, #ir_block{exprs = Es}) ->
    lists:flatmap(fun(E) -> calls_in_ir(Mod, E) end, Es);
calls_in_ir(Mod, #ir_binop{left = L, right = R}) ->
    calls_in_ir(Mod, L) ++ calls_in_ir(Mod, R);
calls_in_ir(Mod, #ir_unop{operand = E}) ->
    calls_in_ir(Mod, E);
calls_in_ir(Mod, #ir_tuple{elements = Es}) ->
    lists:flatmap(fun(E) -> calls_in_ir(Mod, E) end, Es);
calls_in_ir(Mod, #ir_map{pairs = Pairs}) ->
    lists:flatmap(fun({K, V}) -> calls_in_ir(Mod, K) ++ calls_in_ir(Mod, V) end, Pairs);
calls_in_ir(_Mod, _Node) ->
    [].
