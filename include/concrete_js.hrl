%% Convenience macro for concrete_js: rebinds its somewhat verbose
%% module prefix to a shorter, project-local name.
%%
%% concrete_js can't just be named "js" in the module itself -- Erlang
%% has one flat, global module namespace, and a name that generic is
%% too likely to collide with a project's own module. This -define is
%% the idiomatic Erlang way to get the same typing convenience
%% locally, opt-in, without the library claiming that name for every
%% project that depends on it.
%%
%% Usage:
%%   -include_lib("concrete/include/concrete_js.hrl").
%%   ...
%%   Scene = ?js:new('THREE.Scene', []),
%%   ?js:call(Scene, add, [Mesh]).
-define(js, concrete_js).
