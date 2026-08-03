%% Authoritative server-side state for the multiplayer snake demo. A
%% real OTP gen_server -- unlike the rest of example/, this module
%% never gets compiled to JS; it's the "server" half of the demo, the
%% same way a Phoenix Channel or a plain WebSocket server would be in a
%% hand-written JS app. See snake_client.erl for the browser half
%% (compiled Erlang, rendering whatever board state this process
%% broadcasts) and snake_http.erl / snake_sse_handler.erl for how a
%% browser gets connected to it.
%%
%% One player per browser tab, identified by a per-tab session secret
%% (see snake_http:new_secret/0) rather than a guessable sequential id
%% -- it's baked into the page's boot script once, then reused as the
%% SSE path and the input POST body for the tab's whole lifetime, so a
%% dropped/reconnected stream (or the client's own explicit reconnect,
%% see runtime.js's sse:connect/3) resumes the same snake instead of
%% spawning a new one. It's never broadcast back out (see
%% board_term/1): every *other* client only ever sees an opaque snake,
%% not who owns it.
%%
%% snake_sse_handler:init/2 joins its secret the moment its SSE
%% connection opens (not the page handler -- a page load with no
%% working SSE connection shouldn't leave a snake stuck on the board).
%% Every ?TICK_MS this process advances every alive snake by one cell,
%% resolves collisions, and pushes the new board to every subscriber
%% via concrete_pubsub -- the same broadcast primitive
%% concrete_sse_handler uses.
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
%% Joining with a Secret that's already playing resumes it (same body,
%% direction, alive-ness) rather than spawning a fresh snake. Returns
%% this player's color -- board_term/1 never includes whose snake is
%% whose (see its own comment), so this is the only way the owning
%% client learns which one to highlight as its own.
-spec join(binary(), pid()) -> {ok, non_neg_integer()}.
join(Secret, Pid) ->
    gen_server:call(?MODULE, {join, Secret, Pid}).

-spec set_direction(binary(), up | down | left | right) -> ok.
set_direction(Secret, Dir) ->
    gen_server:cast(?MODULE, {set_direction, Secret, Dir}).

-spec board() -> map().
board() ->
    gen_server:call(?MODULE, board).

%% --- gen_server callbacks ---

init([]) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, #{players => #{}, food => {?WIDTH div 2, ?HEIGHT div 2}, tick => 0, next_hue => 0}}.

handle_call({join, Secret, Pid}, _From, State) ->
    _Ref = erlang:monitor(process, Pid),
    #{players := Players, next_hue := Hue, tick := Tick} = State,
    case maps:find(Secret, Players) of
        {ok, Existing} ->
            %% A reconnect (EventSource retries automatically on any
            %% connection hiccup -- laptop sleep, a network blip, a
            %% browser tab juggling several open streams -- with the
            %% *same* secret) must not respawn an already-playing
            %% snake from scratch. Just point this player's record at
            %% the new connection's pid; body/alive/etc. carry over.
            %% last_seen_tick does update here, though -- that's what
            %% "last connected/reconnected" in the legend means.
            log_join(reconnect, Secret, Pid),
            State2 = State#{players := Players#{Secret := Existing#{pid := Pid, last_seen_tick := Tick}}},
            {reply, {ok, maps:get(color, Existing)}, State2};
        error ->
            log_join(new_player, Secret, Pid),
            Player = #{color => Hue, body => new_body(Players), dir => right,
                       pending => right, alive => true, respawn_at => undefined, pid => Pid,
                       last_seen_tick => Tick},
            State2 = State#{players := Players#{Secret => Player},
                             next_hue := (Hue + 67) rem 360},
            {reply, {ok, Hue}, State2}
    end;
handle_call(board, _From, State) ->
    {reply, board_term(State), State}.

handle_cast({set_direction, Secret, Dir}, #{players := Players} = State) ->
    case maps:find(Secret, Players) of
        {ok, #{dir := Cur} = P} ->
            case opposite(Dir, Cur) of
                true  -> {noreply, State};
                false -> {noreply, State#{players := Players#{Secret := P#{pending := Dir}}}}
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
handle_info({'DOWN', _Ref, process, Pid, Reason}, #{players := Players} = State) ->
    %% A 'DOWN' for a pid that's no longer this player's *current* one
    %% (superseded by a later reconnect, see the {join, ...} clause
    %% above) is expected and a correct no-op, not a removal -- log
    %% only the secrets actually leaving the board.
    Leaving = [S || {S, #{pid := P}} <- maps:to_list(Players), P =:= Pid],
    lists:foreach(fun(S) -> log_leave(S, Pid, Reason) end, Leaving),
    Players2 = maps:filter(fun(_Secret, #{pid := P}) -> P =/= Pid end, Players),
    {noreply, State#{players := Players2}};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Diagnostic logging for "a snake vanished and came back" reports: a
%% `reconnect` for the same secret shortly after a `leave` is a dropped
%% -and-resumed SSE stream (expected, see the module header); a
%% `new_player` where you expected a `reconnect` means the *page*
%% reloaded (a fresh secret was minted), not just the stream.
log_join(new_player, Secret, Pid) ->
    io:format("[snake_game] new player ~s (~p)~n", [short(Secret), Pid]);
log_join(reconnect, Secret, Pid) ->
    io:format("[snake_game] ~s reconnected (~p)~n", [short(Secret), Pid]).

log_leave(Secret, Pid, Reason) ->
    io:format("[snake_game] ~s left (pid ~p down: ~p)~n", [short(Secret), Pid, Reason]).

short(Secret) -> binary:part(Secret, 0, 8).

%% --- Game loop ---

step(#{players := Players, food := Food, tick := Tick} = State) ->
    {Players2, AteFood} = lists:foldl(fun({Secret, P}, {Acc, AteAcc}) ->
        step_player(Secret, P, Players, Food, Tick, Acc, AteAcc)
    end, {Players, false}, maps:to_list(Players)),
    Food2 = case AteFood of
        true  -> random_free_cell(Players2);
        false -> Food
    end,
    State#{players := Players2, food := Food2, tick := Tick + 1}.

step_player(Secret, #{alive := false, respawn_at := RespawnAt} = P, _Players, _Food, Tick, Acc, AteAcc)
  when RespawnAt =/= undefined, Tick >= RespawnAt ->
    {Acc#{Secret := P#{alive := true, body := new_body(Acc), dir := right,
                        pending := right, respawn_at := undefined}}, AteAcc};
step_player(_Secret, #{alive := false}, _Players, _Food, _Tick, Acc, AteAcc) ->
    {Acc, AteAcc};
step_player(Secret, #{alive := true, pending := Dir, body := [Head | _] = Body} = P,
            Players, Food, Tick, Acc, AteAcc) ->
    NewHead = move(Head, Dir),
    Others = lists:append([B || {OSecret, #{alive := true, body := B}} <- maps:to_list(Players),
                                 OSecret =/= Secret]),
    case dead(NewHead, Others) of
        true ->
            {Acc#{Secret := P#{alive := false, respawn_at := Tick + ?RESPAWN_TICKS}}, AteAcc};
        false ->
            Grow = NewHead =:= Food,
            NewBody = case Grow of
                true  -> [NewHead | Body];
                false -> [NewHead | lists:droplast(Body)]
            end,
            {Acc#{Secret := P#{dir := Dir, body := NewBody}}, AteAcc orelse Grow}
    end.

%% Running into another snake's body is the only way to die -- the
%% edges of the board wrap (see move/2) and a snake can freely cross
%% its own body.
dead(Head, Others) ->
    lists:member(Head, Others).

%% The board wraps: moving off one edge brings you back on the other.
move({X, Y}, up)    -> {X, wrap(Y - 1, ?HEIGHT)};
move({X, Y}, down)  -> {X, wrap(Y + 1, ?HEIGHT)};
move({X, Y}, left)  -> {wrap(X - 1, ?WIDTH), Y};
move({X, Y}, right) -> {wrap(X + 1, ?WIDTH), Y}.

wrap(V, Max) -> (V + Max) rem Max.

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
%% README). Deliberately excludes the map key (each player's session
%% secret) -- nothing client-side needs it, and broadcasting it would
%% hand every connected browser everyone else's reconnect credential.
%%
%% The fourth element is how long ago (in milliseconds) this player
%% last joined/reconnected -- ticks are this game's clock, so that's
%% just (current tick - last_seen_tick) scaled by ?TICK_MS, no wall
%% -clock synchronization with the browser needed.
board_term(#{players := Players, food := Food, tick := Tick}) ->
    #{width => ?WIDTH, height => ?HEIGHT, food => Food,
      players => [{maps:get(color, P), maps:get(body, P), maps:get(alive, P),
                    (Tick - maps:get(last_seen_tick, P)) * ?TICK_MS}
                  || P <- maps:values(Players)]}.
