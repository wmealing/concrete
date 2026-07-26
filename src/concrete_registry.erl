%% gproc-based registry mapping component instance IDs to PIDs.
-module(concrete_registry).

-export([start_link/0, register/2, lookup/1, unregister/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    %% gproc starts as part of its own application; this is a thin facade.
    {ok, spawn_link(fun loop/0)}.

loop() ->
    receive
        stop -> ok;
        _    -> loop()
    end.

-spec register(term(), pid()) -> true.
register(Id, Pid) ->
    gproc:reg({n, l, {concrete_component, Id}}, Pid).

-spec lookup(term()) -> pid() | undefined.
lookup(Id) ->
    case gproc:where({n, l, {concrete_component, Id}}) of
        undefined -> undefined;
        Pid       -> Pid
    end.

-spec unregister(term()) -> true.
unregister(Id) ->
    gproc:unreg({n, l, {concrete_component, Id}}).
