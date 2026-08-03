%% An ordinary gen_server-shaped callback module -- exactly the shape a
%% real `-behaviour(gen_server)` module would have (init/1,
%% handle_call/3, handle_cast/2). No spawn/self/!/receive in here at
%% all: concrete_gen_server owns the process; this module is just the
%% business logic it dispatches into.
-module(counter_server).
-export([init/1, handle_call/3, handle_cast/2]).

init(Initial) ->
    {ok, Initial}.

handle_call(get, _From, State) ->
    {reply, State, State};
handle_call(increment, _From, State) ->
    {reply, State + 1, State + 1};
handle_call(decrement, _From, State) ->
    {reply, State - 1, State - 1}.

handle_cast(reset, _State) ->
    {noreply, 0}.
