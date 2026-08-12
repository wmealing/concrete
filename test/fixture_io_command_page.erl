%% Test fixture: a page whose command/3 calls io:format/2 -- used by
%% rebar_compiler_concrete_SUITE to prove command/3 is never traced
%% into the JS bundle call graph (concrete_call_graph:page_entries/2
%% deliberately excludes it), so a real, unrestricted stdlib call like
%% io:format/2 -- something the JS encoder cannot compile -- is fine
%% inside it. Before the fix, command/3 was a root like action/3, and
%% this exact module would have made the encoder choke trying to
%% compile io:format/2's own IR.
-module(fixture_io_command_page).
-export([init/2, template/0, action/3, command/3]).

init(_Params, Server) ->
    {#{state => #{count => 0}}, Server}.

template() ->
    {inline, []}.

action(increment, _Params, #{state := #{count := N} = S} = C) ->
    C#{state => S#{count := N + 1}}.

command(report, Params, Server) ->
    io:format("count is now: ~p~n", [Params]),
    Server.
