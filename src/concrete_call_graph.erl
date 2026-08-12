%% Builds an MFA dependency graph from IR and performs dead-code elimination.
-module(concrete_call_graph).
-include("concrete_ir.hrl").

-export([build/2, build_from_entries/2, reachable/1, page_entries/2]).

-type mfa_key() :: {module(), atom(), arity()}.

%% Build a call graph rooted at the page/component module's entry
%% points: init/2 and template/0 are always roots (the JS runtime calls
%% them directly, not via any traceable Erlang call); action/3 is a
%% root too when present -- the browser dispatches to it directly from
%% a concrete-click handler, never via a call reachable from init/2, so
%% plain call-graph tracing would otherwise mark it (wrongly) as dead
%% code.
%%
%% command/3 is deliberately NOT a root, unlike action/3. Every
%% dispatch path that reaches it -- concrete_command_handler's HTTP
%% POST handler and concrete_ws_handler's WebSocket handler, both via
%% concrete_runtime:dispatch_command/4 -- calls Module:command/3 as an
%% ordinary Erlang function call on the real BEAM. No compiled-JS path
%% ever exists for it (grep priv/js/demo/client.js and runtime.js: the
%% only thing that happens client-side is the POST/WS message itself,
%% dispatchCommand never runs command/3 locally the way Client.dispatch
%% runs action/3). Treating it as a root anyway used to force
%% command/3's body through the JS encoder for no functional reason,
%% breaking any use of a stdlib call the encoder doesn't special-case
%% (io:format/2, logger:info/1,2, ...) even though that code would
%% never execute in a browser. If a command/3 happens to be reachable
%% some other way -- e.g. an action/3 clause
%% calls it directly as a plain in-process function, which defeats the
%% point of it being server-only but is legal Erlang -- ordinary call
%% graph tracing from action/3 still picks it up and compiles it, same
%% as any other function action/3 calls.
-spec build(module(), term()) -> digraph:graph().
build(PageModule, PLT) ->
    build_from_entries(page_entries(PageModule, PLT), PLT).

%% The entry MFAs for one page or component module. Exposed on its own
%% (not just folded into build/2) so a caller building one combined
%% graph over several modules -- e.g. a page plus every component it
%% embeds via <:component> -- can concatenate entry lists before
%% calling build_from_entries/2 once, rather than unioning several
%% separate graphs.
-spec page_entries(module(), term()) -> [mfa_key()].
page_entries(PageModule, PLT) ->
    BaseEntries = [{PageModule, init, 2}, {PageModule, template, 0}],
    ExtraEntries = [E || E <- [{PageModule, action, 3}],
                          concrete_plt:get(PLT, E) =/= not_found],
    BaseEntries ++ ExtraEntries.

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
