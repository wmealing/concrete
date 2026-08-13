%% Test fixture: a module tagged -concrete([{compiler_internal, true}]),
%% the same shape fixture_bif_module.erl uses for bif_module -- used by
%% beam_reader_SUITE to prove concrete_beam_reader:extract_ir/1 refuses
%% to trace into ANY module carrying that attribute, not just
%% concrete_template_parser/concrete_transformer specifically.
-module(fixture_compiler_internal).
-concrete([{compiler_internal, true}]).
-export([noop/0]).

noop() -> ok.
