%% Phase 2: BEAM abstract code extraction tests.
%% Reads IR from compiled OTP stdlib modules (always have debug_info).
-module(beam_reader_SUITE).
-include_lib("common_test/include/ct.hrl").
-include("concrete_ir.hrl").

-export([all/0, groups/0]).
-export([
    extract_stdlib_module/1,
    extract_missing_module/1,
    extracted_ir_is_module_record/1,
    extracted_module_has_definitions/1,
    extracted_definition_names_are_atoms/1,
    bif_module_is_refused/1,
    concrete_js_is_refused/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [
        extract_stdlib_module,
        extract_missing_module,
        extracted_ir_is_module_record,
        extracted_module_has_definitions,
        extracted_definition_names_are_atoms,
        bif_module_is_refused,
        concrete_js_is_refused
    ]}].
%% The `lists` module is always compiled with debug_info in OTP.
extract_stdlib_module(_Config) ->
    {ok, _IR} = concrete_beam_reader:extract_ir(lists).

extract_missing_module(_Config) ->
    {error, _Reason} = concrete_beam_reader:extract_ir(no_such_module_ever_12345).

extracted_ir_is_module_record(_Config) ->
    {ok, IR} = concrete_beam_reader:extract_ir(lists),
    true = is_record(IR, ir_module).

extracted_module_has_definitions(_Config) ->
    {ok, #ir_module{definitions = Defs}} = concrete_beam_reader:extract_ir(lists),
    true = length(Defs) > 0.

extracted_definition_names_are_atoms(_Config) ->
    {ok, #ir_module{definitions = Defs}} = concrete_beam_reader:extract_ir(lists),
    lists:foreach(fun(#ir_function_def{name = N}) ->
        true = is_atom(N)
    end, Defs).

%% Any module tagged -concrete([{bif_module, true}]) -- not just
%% concrete_js -- must be refused, even though it has real, traceable
%% abstract code (fixture_bif_module:noop/0 is a normal exported
%% function). Regression test for the call-graph-walk shadowing bug:
%% a module like this getting traced and compiled into a bundle would
%% silently overwrite its hand-written native runtime.js counterpart.
bif_module_is_refused(_Config) ->
    {error, bif_module} = concrete_beam_reader:extract_ir(fixture_bif_module).

%% concrete_js itself is real production code carrying the same
%% attribute -- confirm it's refused too, not just the fixture.
concrete_js_is_refused(_Config) ->
    {error, bif_module} = concrete_beam_reader:extract_ir(concrete_js).
