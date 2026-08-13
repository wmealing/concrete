%% Cross-references {Mod, Fun, Arity} triples against runtime.js's
%% hand-written native BIF table (the `Erlang` object in
%% priv/js/demo/runtime.js), so the call graph walker
%% (concrete_call_graph) can treat calls like `maps:get/3` or
%% `lists:reverse/1` as already-implemented leaves instead of tracing
%% into their real, debug_info-compiled stdlib source.
%%
%% This is the same shadowing problem the concrete_js bif_module fix
%% addressed, one level more general: `bif_module`/`compiler_internal`
%% (see concrete_beam_reader) exclude a module by hand-added attribute,
%% which works for concrete's own modules but not for OTP stdlib
%% modules like `maps` and `lists` that nobody can tag. Tracing into
%% them and compiling the real body would make concrete_encoder emit
%% Interpreter.defineErlangFunction("maps", "get", 3, ...), which
%% collides with the pre-existing native key at runtime -- caught by
%% defineErlangFunction's defense-in-depth guard, but only after a
%% clean compile, at first client-side use.
%%
%% runtime.js's `Erlang` table is treated as the single source of
%% truth: this module parses that file's own `"Mod:Fun/Arity"` key
%% strings directly instead of hand-maintaining a duplicate list that
%% can silently drift out of sync as runtime.js gains new native BIFs.
-module(concrete_native_bifs).

-export([is_native/1, native_mfas/0]).

-spec is_native({module(), atom(), arity()}) -> boolean().
is_native(MFA) ->
    sets:is_element(MFA, native_mfas()).

-spec native_mfas() -> sets:set({module(), atom(), arity()}).
native_mfas() ->
    case persistent_term:get({?MODULE, mfas}, undefined) of
        undefined ->
            Set = load_native_mfas(),
            persistent_term:put({?MODULE, mfas}, Set),
            Set;
        Set ->
            Set
    end.

load_native_mfas() ->
    {ok, Bin} = file:read_file(concrete:runtime_path()),
    {ok, Re} = re:compile(
        "\"([a-zA-Z_][a-zA-Z0-9_]*):([a-zA-Z_][a-zA-Z0-9_]*)/([0-9]+)\""
    ),
    case re:run(Bin, Re, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            sets:from_list([
                {binary_to_atom(M, utf8), binary_to_atom(F, utf8), binary_to_integer(A)}
                || [M, F, A] <- Matches
            ]);
        nomatch ->
            sets:new()
    end.
