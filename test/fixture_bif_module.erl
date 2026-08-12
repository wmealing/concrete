%% Test fixture: a module tagged -concrete([{bif_module, true}]), the
%% same way concrete_js.erl is -- used by beam_reader_SUITE to prove
%% concrete_beam_reader:extract_ir/1 refuses to trace into ANY module
%% carrying that attribute, not just concrete_js specifically.
-module(fixture_bif_module).
-concrete([{bif_module, true}]).
-export([noop/0]).

noop() -> ok.
