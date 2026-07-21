%% Page module for the template_demo browser demo.
%% State comes from query params: /?player=sam&score=100
-module(scoreboard_page).
-export([init/2, template/0, action/3]).

init(Params, Server) ->
    State = #{title  => <<"Scores">>,
              player => maps:get(player, Params, <<"anonymous">>),
              score  => int_param(score, Params, 41)},
    {#{state => State}, Server}.

template() ->
    "scoreboard.slab".

%% Compiled to JavaScript and dispatched in the browser by client.js —
%% these clauses never run on the server for button clicks.
action(increment, _Params, #{state := #{score := N} = S} = C) ->
    C#{state => S#{score := N + 1}};
action(decrement, _Params, #{state := #{score := N} = S} = C) ->
    C#{state => S#{score := N - 1}}.

int_param(Key, Params, Default) ->
    case maps:get(Key, Params, undefined) of
        undefined -> Default;
        Bin ->
            try binary_to_integer(Bin)
            catch _:_ -> Default
            end
    end.
