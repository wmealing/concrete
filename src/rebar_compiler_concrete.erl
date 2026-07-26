%% rebar3 compiler plugin for Concrete.
%% Implements the rebar_compiler behaviour (rebar3 3.14+).
-module(rebar_compiler_concrete).
-behaviour(rebar_compiler).

-export([context/1, needed_files/4, dependencies/3, compile/4, clean/2]).

context(AppInfo) ->
    EbinDir = rebar_app_info:ebin_dir(AppInfo),
    OutDir  = filename:join(rebar_app_info:priv_dir(AppInfo), "js/bundles"),
    #{src_dirs          => ["src"],
      src_ext           => ".erl",
      out_mappings      => [{".mjs", OutDir}],
      dependencies_opts => #{ebin_dir => EbinDir}}.

needed_files(_Graph, _FoundFiles, _Mappings, AppInfo) ->
    PLT = concrete_plt:load_or_new(plt_path(AppInfo)),
    PageModules = find_page_modules(AppInfo),
    Changed = [M || M <- PageModules, bundle_is_stale(M, PLT)],
    {Changed, []}.

dependencies(_Source, _SourceDir, _Dirs) ->
    [].

compile(PageModule, _Mappings, _Config, AppInfo) ->
    rebar_api:info("Concrete: compiling bundle for ~s", [PageModule]),
    PLT = concrete_plt:load_or_new(plt_path(AppInfo)),
    populate_plt(PLT, PageModule, AppInfo),
    Graph = concrete_call_graph:build(PageModule, PLT),
    JS    = concrete_encoder:encode_bundle(Graph, PLT),
    Hash  = crypto:hash(sha256, JS),
    Name  = io_lib:format("~s_~s.mjs", [PageModule, hex(Hash)]),
    OutDir = filename:join(rebar_app_info:priv_dir(AppInfo), "js/bundles"),
    ok = filelib:ensure_dir(filename:join(OutDir, ".")),
    ok = file:write_file(filename:join(OutDir, Name), JS),
    update_manifest(PageModule, Name, AppInfo),
    concrete_plt:save(PLT, plt_path(AppInfo)),
    ok.

clean(_AppInfo, _Config) ->
    ok.

%% Internal helpers

plt_path(AppInfo) ->
    filename:join(rebar_app_info:priv_dir(AppInfo), "concrete.plt").

find_page_modules(AppInfo) ->
    EbinDir = rebar_app_info:ebin_dir(AppInfo),
    Beams   = filelib:wildcard(filename:join(EbinDir, "*.beam")),
    [Module || Beam <- Beams,
               Module <- [beam_module(Beam)],
               is_page_module(Module)].

beam_module(BeamFile) ->
    list_to_atom(filename:basename(BeamFile, ".beam")).

is_page_module(Module) ->
    try
        Attrs = Module:module_info(attributes),
        lists:any(fun({behaviour, Bs}) -> lists:member(concrete_page, Bs);
                     (_) -> false
                  end, Attrs)
    catch _:_ -> false
    end.

bundle_is_stale(_Module, _PLT) ->
    %% TODO: compare module digest against PLT entry
    true.

populate_plt(PLT, PageModule, _AppInfo) ->
    Graph = concrete_call_graph:build(PageModule, PLT),
    MFAs  = concrete_call_graph:reachable(Graph),
    [populate_mfa(PLT, MFA) || MFA <- MFAs],
    ok.

populate_mfa(PLT, {M, _F, _A} = MFA) ->
    case concrete_plt:get(PLT, MFA) of
        {ok, _} -> ok;
        not_found ->
            case concrete_beam_reader:extract_ir(M) of
                {ok, #{'definitions' := Defs}} ->
                    [concrete_plt:put(PLT, {M, D#ir_function_def.name,
                                            D#ir_function_def.arity}, D)
                     || D <- Defs];
                _ -> ok
            end
    end.

update_manifest(PageModule, BundleName, AppInfo) ->
    Path = filename:join(rebar_app_info:priv_dir(AppInfo), "concrete_manifest.json"),
    Existing = case file:read_file(Path) of
        {ok, Bin} -> thoas:decode(Bin);
        _         -> #{}
    end,
    Updated = Existing#{atom_to_binary(PageModule) => list_to_binary(BundleName)},
    file:write_file(Path, thoas:encode(Updated)).

hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
