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
            case exclusion_reason(Forms) of
                {error, _} = Err ->
                    Err;
                ok ->
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
%%
%% A module tagged -concrete([{compiler_internal, true}]) (e.g.
%% concrete_template_parser, concrete_transformer) is a different shape
%% of the same problem: it has no native runtime.js counterpart at all
%% (it never runs client-side, hand-written or otherwise), but it's
%% still real, traceable, debug_info-compiled application code that can
%% end up called from a template/0 (see the {inline, parse_string(...)}
%% pattern) or any other compile root. Tracing it means feeding the
%% compiler's own recursive-descent parser -- full of raw character
%% literals -- to an encoder that was never written to handle it.
%% Refusing to extract it here means the offending MFA simply never
%% gets populated into the PLT; concrete_encoder:encode_mfa/3 already
%% treats an unpopulated MFA as "emit nothing" instead of crashing.
exclusion_reason(Forms) ->
    case has_tag(Forms, bif_module) of
        true ->
            {error, bif_module};
        false ->
            case has_tag(Forms, compiler_internal) of
                true  -> {error, compiler_internal};
                false -> ok
            end
    end.

has_tag(Forms, Tag) ->
    lists:any(
        fun({attribute, _, concrete, Opts}) -> proplists:get_value(Tag, Opts) =:= true;
           (_) -> false
        end,
        Forms
    ).
