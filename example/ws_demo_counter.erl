%% Tiny gen_server holding the one persistent, shared counter that
%% every connected browser bumps via a real WebSocket "command"
%% message -- see ws_demo_page:command/3 and ws_demo.erl.
-module(ws_demo_counter).
-behaviour(gen_server).

-export([start_link/0, bump/1, value/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, 0, []).

bump(Delta) ->
    gen_server:call(?MODULE, {bump, Delta}).

value() ->
    gen_server:call(?MODULE, value).

init(Count) ->
    {ok, Count}.

handle_call({bump, Delta}, _From, Count) ->
    NewCount = Count + Delta,
    {reply, NewCount, NewCount};
handle_call(value, _From, Count) ->
    {reply, Count, Count}.

handle_cast(_Msg, Count) ->
    {noreply, Count}.
