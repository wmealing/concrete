%% Browser wiring for the gen_server demo: spawns a real
%% concrete_gen_server process backed by counter_server, and dispatches
%% button clicks into gen_server:call/cast against it. All of this --
%% the spawn, the call/cast round trips, the receive inside
%% concrete_gen_server -- runs as compiled Erlang; this module has no
%% JS glue beyond the one-line bootstrap in gen_server_boot.js.
-module(counter_ui).
-export([start/0, click/1]).

start() ->
    dom:on_click(<<"gs-root">>, <<"data-action">>, counter_ui, click),
    {ok, Pid} = concrete_gen_server:start_link(counter_server, 0),
    ui:set_pid(Pid),
    render(0).

click(<<"increment">>) ->
    Pid = ui:get_pid(),
    Value = concrete_gen_server:call(Pid, increment),
    log(<<"call increment -> ">>, Value),
    render(Value);
click(<<"decrement">>) ->
    Pid = ui:get_pid(),
    Value = concrete_gen_server:call(Pid, decrement),
    log(<<"call decrement -> ">>, Value),
    render(Value);
click(<<"get">>) ->
    Pid = ui:get_pid(),
    Value = concrete_gen_server:call(Pid, get),
    log(<<"call get -> ">>, Value),
    render(Value);
click(<<"reset">>) ->
    Pid = ui:get_pid(),
    concrete_gen_server:cast(Pid, reset),
    log(<<"cast reset">>, <<"">>),
    render(concrete_gen_server:call(Pid, get)).

render(Value) ->
    dom:set_text(<<"gs-count">>, integer_to_binary(Value)).

log(Label, Value) when is_integer(Value) ->
    dom:append_html(<<"gs-log">>,
        <<"<div>", Label/binary, (integer_to_binary(Value))/binary, "</div>">>),
    dom:scroll_to_bottom(<<"gs-log">>);
log(Label, _Value) ->
    dom:append_html(<<"gs-log">>, <<"<div>", Label/binary, "</div>">>),
    dom:scroll_to_bottom(<<"gs-log">>).
