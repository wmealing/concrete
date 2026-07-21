%% Builds an MFA dependency graph from IR and performs dead-code elimination.
-module(concrete_call_graph).
-include("concrete_ir.hrl").

-export([build/2, reachable/1]).

-type mfa_key() :: {module(), atom(), arity()}.

%% Build a call graph rooted at the page module's entry points.
-spec build(module(), term()) -> digraph:graph().
build(PageModule, PLT) ->
    G = digraph:new(),
    Entries = [{PageModule, init, 2}, {PageModule, template, 0}],
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
