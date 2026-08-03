%% Authoritative server-side state for the multiplayer snake demo. A
%% real OTP gen_server -- unlike the rest of example/, this module
%% never gets compiled to JS; it's the "server" half of the demo, the
%% same way a Phoenix Channel or a plain WebSocket server would be in a
%% hand-written JS app. See snake_client.erl for the browser half
%% (compiled Erlang, rendering whatever board state this process
%% broadcasts) and snake_http.erl / snake_sse_handler.erl for how a
%% browser gets connected to it.
%%
%% One player per browser tab: snake_sse_handler:init/2 joins its
%% player id the moment its SSE connection opens (not the page handler
%% -- a page load with no working SSE connection shouldn't leave a
%% snake stuck on the board). Every ?TICK_MS this process advances
%% every alive snake by one cell, resolves collisions, and pushes the
%% new board to every subscriber via concrete_pubsub -- the same
%% broadcast primitive concrete_sse_handler uses.
%%
%% Cleanup on disconnect is done with a plain erlang:monitor/2 on the
%% joining pid (see join/2), not a cowboy terminate/3 callback: a loop
%% handler whose peer just vanishes mid-stream isn't guaranteed to run
%% its terminate/3 (it can be brought down by a signal before cowboy's
%% own cleanup path executes), but a monitor's 'DOWN' is delivered by
%% the VM regardless of how the process died.
-module(snake_game).
-behaviour(gen_server).

-export([start_link/0, join/2, set_direction/2, board/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(WIDTH, 30).
-define(HEIGHT, 20).
-define(TICK_MS, 150).
-define(RESPAWN_TICKS, 20).
-define(START_LEN, 3).

%% --- API ---

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Pid is monitored so the player is removed automatically if it dies
%% (i.e. the browser's SSE connection closes) -- see the module header.
-spec join(binary(), pid()) -> ok.
join(PlayerId, Pid) ->
    gen_server:call(?MODULE, {join, PlayerId, Pid}).

-spec set_direction(binary(), up | down | left | right) -> ok.
set_direction(PlayerId, Dir) ->
    gen_server:cast(?MODULE, {set_direction, PlayerId, Dir}).

-spec board() -> map().
board() ->
    gen_server:call(?MODULE, board).

%% --- gen_server callbacks ---

init([]) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, #{players => #{}, food => {?WIDTH div 2, ?HEIGHT div 2}, tick => 0, next_hue => 0}}.

handle_call({join, PlayerId, Pid}, _From, State) ->
    _Ref = erlang:monitor(process, Pid),
    #{players := Players, next_hue := Hue} = State,
    Player = #{color => Hue, body => new_body(Players), dir => right,
               pending => right, alive => true, respawn_at => undefined, pid => Pid},
    State2 = State#{players := Players#{PlayerId => Player},
                     next_hue := (Hue + 67) rem 360},
    {reply, ok, State2};
handle_call(board, _From, State) ->
    {reply, board_term(State), State}.

handle_cast({set_direction, PlayerId, Dir}, #{players := Players} = State) ->
    case maps:find(PlayerId, Players) of
        {ok, #{dir := Cur} = P} ->
            case opposite(Dir, Cur) of
                true  -> {noreply, State};
                false -> {noreply, State#{players := Players#{PlayerId := P#{pending := Dir}}}}
            end;
        error ->
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    erlang:send_after(?TICK_MS, self(), tick),
    State2 = step(State),
    concrete_pubsub:broadcast(snake_board, board_term(State2)),
    {noreply, State2};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #{players := Players} = State) ->
    Players2 = maps:filter(fun(_Id, #{pid := P}) -> P =/= Pid end, Players),
    {noreply, State#{players := Players2}};
handle_info(_Msg, State) ->
    {noreply, State}.

%% --- Game loop ---

step(#{players := Players, food := Food, tick := Tick} = State) ->
    {Players2, AteFood} = lists:foldl(fun({Id, P}, {Acc, AteAcc}) ->
        step_player(Id, P, Players, Food, Tick, Acc, AteAcc)
    end, {Players, false}, maps:to_list(Players)),
    Food2 = case AteFood of
        true  -> random_free_cell(Players2);
        false -> Food
    end,
    State#{players := Players2, food := Food2, tick := Tick + 1}.

step_player(Id, #{alive := false, respawn_at := RespawnAt} = P, _Players, _Food, Tick, Acc, AteAcc)
  when RespawnAt =/= undefined, Tick >= RespawnAt ->
    {Acc#{Id := P#{alive := true, body := new_body(Acc), dir := right,
                   pending := right, respawn_at := undefined}}, AteAcc};
step_player(_Id, #{alive := false}, _Players, _Food, _Tick, Acc, AteAcc) ->
    {Acc, AteAcc};
step_player(Id, #{alive := true, pending := Dir, body := [Head | _] = Body} = P,
            Players, Food, Tick, Acc, AteAcc) ->
    NewHead = move(Head, Dir),
    Others = lists:append([B || {OId, #{alive := true, body := B}} <- maps:to_list(Players), OId =/= Id]),
    case dead(NewHead, Others, Body) of
        true ->
            {Acc#{Id := P#{alive := false, respawn_at := Tick + ?RESPAWN_TICKS}}, AteAcc};
        false ->
            Grow = NewHead =:= Food,
            NewBody = case Grow of
                true  -> [NewHead | Body];
                false -> [NewHead | lists:droplast(Body)]
            end,
            {Acc#{Id := P#{dir := Dir, body := NewBody}}, AteAcc orelse Grow}
    end.

dead({X, Y}, _Others, _SelfBody) when X < 0; X >= ?WIDTH; Y < 0; Y >= ?HEIGHT ->
    true;
dead(Head, Others, SelfBody) ->
    lists:member(Head, Others) orelse lists:member(Head, lists:droplast(SelfBody)).

move({X, Y}, up)    -> {X, Y - 1};
move({X, Y}, down)  -> {X, Y + 1};
move({X, Y}, left)  -> {X - 1, Y};
move({X, Y}, right) -> {X + 1, Y}.

opposite(up, down)    -> true;
opposite(down, up)    -> true;
opposite(left, right) -> true;
opposite(right, left) -> true;
opposite(_, _)        -> false.

%% A fresh ?START_LEN-cell body trailing left from a random free cell.
new_body(Players) ->
    {X, Y} = random_free_cell(Players),
    [{X - N, Y} || N <- lists:seq(0, ?START_LEN - 1)].

random_free_cell(Players) ->
    Occupied = lists:append([B || #{body := B} <- maps:values(Players)]),
    Cell = {rand:uniform(?WIDTH) - 1, rand:uniform(?HEIGHT) - 1},
    case lists:member(Cell, Occupied) of
        true  -> random_free_cell(Players);
        false -> Cell
    end.

%% The wire-safe subset of state broadcast to every client: plain
%% tuples/lists/atoms/integers/binaries, everything concrete_serializer
%% already knows how to encode (see the "Wire format" table in the
%% README).
board_term(#{players := Players, food := Food}) ->
    #{width => ?WIDTH, height => ?HEIGHT, food => Food,
      players => [{Id, maps:get(color, P), maps:get(body, P), maps:get(alive, P)}
                  || {Id, P} <- maps:to_list(Players)]}.
