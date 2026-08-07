%% Pure Erlang, compiled to JavaScript, driving the DOM directly via the
%% dom:* BIFs -- no concrete_page/concrete_component behaviour, no .slab
%% template, no server. See {{name}}_build:build/0 to compile this module
%% and priv/index.html to run it.
-module({{name}}).
-export([start/0, handle_click/1]).

start() ->
    dom:set_value(<<"count">>, <<"0">>),
    dom:on_click(<<"{{name}}-root">>, <<"data-action">>, {{name}}, handle_click).

%% dom:on_click/4 calls its handler with the clicked element's
%% data-action value as a single bitstring argument.
%% dom:get_value/set_value target an <input> element's `.value` -- there's
%% no dom:get_text BIF, so the counter's state lives in the input itself
%% rather than in an Erlang process.
handle_click(<<"increment">>) ->
    N = binary_to_integer(dom:get_value(<<"count">>)),
    dom:set_value(<<"count">>, integer_to_binary(N + 1));
handle_click(_Other) ->
    ok.
