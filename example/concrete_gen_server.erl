%% A generic gen_server-shaped loop, compiled to run entirely in the
%% browser: real Erlang spawn/self/!/receive, with dynamic dispatch to
%% a callback module (Module:init/1, Module:handle_call/3,
%% Module:handle_cast/2), exactly like OTP's gen_server. See
%% counter_server.erl for an example callback module and
%% gen_server_demo.erl for the browser wiring.
%%
%% Not a drop-in replacement for OTP's gen_server (no monitors, no
%% `after` timeouts, no code_change/terminate) -- just enough of the
%% shape to prove real send/receive/spawn works end to end.
-module(concrete_gen_server).
-export([start_link/2, call/2, cast/2, stop/1, init_it/2, loop/2]).

start_link(Module, Args) ->
    Pid = spawn(fun() -> init_it(Module, Args) end),
    {ok, Pid}.

call(Pid, Msg) ->
    Ref = make_ref(),
    Pid ! {'$call', self(), Ref, Msg},
    receive
        {Ref, Reply} -> Reply
    end.

cast(Pid, Msg) ->
    Pid ! {'$cast', Msg},
    ok.

stop(Pid) ->
    Ref = make_ref(),
    Pid ! {'$stop', self(), Ref},
    receive
        {Ref, ok} -> ok
    end.

init_it(Module, Args) ->
    {ok, State} = Module:init(Args),
    loop(Module, State).

loop(Module, State) ->
    receive
        {'$call', From, Ref, Msg} ->
            {Reply, NewState} = do_handle_call(Module, Msg, State),
            From ! {Ref, Reply},
            loop(Module, NewState);
        {'$cast', Msg} ->
            NewState = do_handle_cast(Module, Msg, State),
            loop(Module, NewState);
        {'$stop', From, Ref} ->
            From ! {Ref, ok}
    end.

%% Plain (non-blocking) helpers -- the dynamic dispatch to the callback
%% module happens here, outside of any receive clause, so the callback
%% module itself never needs to know about processes at all.
do_handle_call(Module, Msg, State) ->
    case Module:handle_call(Msg, self(), State) of
        {reply, Reply, NewState} -> {Reply, NewState}
    end.

do_handle_cast(Module, Msg, State) ->
    case Module:handle_cast(Msg, State) of
        {noreply, NewState} -> NewState
    end.
