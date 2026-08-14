%% Page module for the template_demo browser demo.
%% State comes from query params: /?player=sam&score=100
-module(scoreboard_page).
-behaviour(concrete_page).
-include_lib("concrete/include/concrete_js.hrl").
-export([init/2, template/0, action/3, mount/1, key_up/0, key_down/0]).

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

%% Runs once, client-side only, right after the scoreboard's markup is
%% in the real DOM -- see docs/on-mount-plan.md. Wires the arrow keys
%% as a global keyboard shortcut for the same +/- buttons the template
%% already renders, so score changes still only ever happen one way
%% (through action/3 and the normal re-render), even though the
%% keypress itself is caught nowhere near either button.
mount(_Component) ->
    dom:on_keydown_global(<<"ArrowUp">>, ?MODULE, key_up),
    dom:on_keydown_global(<<"ArrowDown">>, ?MODULE, key_down).

%% Clicking the real button (rather than re-running action/3 directly)
%% keeps this a thin input-mapping layer: the click listener client.js
%% already installs in Client.init is still the one and only place a
%% score change is dispatched from.
key_up() ->
    click(<<"score-inc">>).

key_down() ->
    click(<<"score-dec">>).

click(ElementId) ->
    Element = ?js:call('document.getElementById', [ElementId]),
    ?js:call(Element, click, []).

int_param(Key, Params, Default) ->
    case maps:get(Key, Params, undefined) of
        undefined -> Default;
        Bin ->
            try binary_to_integer(Bin)
            catch _:_ -> Default
            end
    end.
