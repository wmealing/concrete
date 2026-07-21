%% Extracts Erlang abstract code from .beam files and converts it to Concrete IR.
-module(concrete_beam_reader).

-export([extract_ir/1]).

-spec extract_ir(module() | file:filename()) -> {ok, term()} | {error, term()}.
extract_ir(Module) when is_atom(Module) ->
    case code:which(Module) of
        non_existing -> {error, {module_not_found, Module}};
        BeamFile     -> extract_ir(BeamFile)
    end;
extract_ir(BeamFile) ->
    case beam_lib:chunks(BeamFile, [abstract_code]) of
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            ModName = module_name(Forms),
            Ctx = concrete_transformer:new_ctx(ModName),
            {ok, concrete_transformer:transform_module(Forms, Ctx)};
        {ok, {_, [{abstract_code, no_abstract_code}]}} ->
            {error, no_debug_info};
        {error, _, Reason} ->
            {error, Reason}
    end.

module_name(Forms) ->
    hd([Name || {attribute, _, module, Name} <- Forms]).
