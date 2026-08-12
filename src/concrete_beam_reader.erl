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
            case is_bif_module(Forms) of
                true ->
                    {error, bif_module};
                false ->
                    ModName = module_name(Forms),
                    Ctx = concrete_transformer:new_ctx(ModName),
                    {ok, concrete_transformer:transform_module(Forms, Ctx)}
            end;
        {ok, {_, [{abstract_code, no_abstract_code}]}} ->
            {error, no_debug_info};
        {error, _, Reason} ->
            {error, Reason}
    end.

module_name(Forms) ->
    hd([Name || {attribute, _, module, Name} <- Forms]).

%% A module tagged -concrete([{bif_module, true}]) (e.g. concrete_js)
%% has a real, traceable .erl body kept only as a harmless server-side
%% pass-through -- its actual implementation is a hand-written native
%% BIF in runtime.js, registered under the same Erlang["Mod:Fun/Arity"]
%% key a traced-and-compiled version of this module would clobber. It
%% must never be traced into a bundle, exactly like dom/canvas/http
%% (which simply have no .erl source to trace at all).
is_bif_module(Forms) ->
    lists:any(
        fun({attribute, _, concrete, Opts}) -> proplists:get_value(bif_module, Opts) =:= true;
           (_) -> false
        end,
        Forms
    ).
