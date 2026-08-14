%% Test fixture for rebar_compiler_concrete_SUITE: a page whose mount/1
%% opens an SSE stream with a bare-atom callback target
%% (sse:connect(Path, Module, Function) -- a Module/Function pair the
%% call graph walker can't trace into, since it's just data flowing
%% through an argument, not a literal call node) and also literally
%% calls that same target once, directly, as part of mount/1's own
%% setup logic. Before mount/1 was a call-graph root, on_event/1 had no
%% real call site anywhere reachable -- concrete_call_graph:collect_calls/2
%% only follows literal call nodes in a clause body, so a helper never
%% reached that way needed a second, fake call site (a dead
%% `case false of true -> ... end` branch) purely to survive dead-code
%% elimination and get compiled into the bundle. Now mount/1 is itself
%% a root, so its own literal call to on_event/1 is traced the same
%% ordinary way action/3's calls already are -- no dead branch needed.
-module(fixture_mount_reachability_page).
-export([init/2, template/0, mount/1, on_event/1]).

init(_Params, Server) ->
    {#{state => #{}}, Server}.

template() ->
    {inline, []}.

mount(_Component) ->
    sse:connect(<<"/events">>, ?MODULE, on_event),
    on_event(<<"initial">>).

on_event(Data) ->
    dom:set_text(<<"status">>, Data).
