%% rebar3 compiler plugin for Concrete.
%% Implements the rebar_compiler behaviour (rebar3 3.14+).
-module(rebar_compiler_concrete).
-behaviour(rebar_compiler).
-include("concrete_ir.hrl").

-export([context/1, needed_files/4, dependencies/3, compile/4, clean/2]).

context(AppInfo) ->
    EbinDir = rebar_app_info:ebin_dir(AppInfo),
    OutDir  = filename:join(rebar_app_info:priv_dir(AppInfo), "js/bundles"),
    #{src_dirs          => ["src"],
      include_dirs      => [],
      src_ext           => ".erl",
      out_mappings      => [{".mjs", OutDir}],
      dependencies_opts => #{ebin_dir => EbinDir}}.

needed_files(_Graph, _FoundFiles, _Mappings, AppInfo) ->
    PLT = concrete_plt:load_or_new(plt_path(AppInfo)),
    PageModules = find_page_modules(AppInfo),
    Changed = [M || M <- PageModules, bundle_is_stale(M, PLT, AppInfo)],
    %% rebar_compiler's needed_files/4 contract: {{FirstFiles, FirstOpts},
    %% {RestFiles, Opts}} — we have no priority group, and thread AppInfo
    %% through as the per-file Opts term (compile/4's 4th argument).
    {{[], []}, {Changed, AppInfo}}.

dependencies(_Source, _SourceDir, _Dirs) ->
    [].

compile(PageModule, _Mappings, _Config, AppInfo) ->
    rebar_api:info("Concrete: compiling bundle for ~s", [PageModule]),
    PLT = concrete_plt:load_or_new(plt_path(AppInfo)),
    populate_plt(PLT, PageModule, AppInfo),
    Graph = concrete_call_graph:build(PageModule, PLT),
    ModuleJS = concrete_encoder:encode_bundle(Graph, PLT),
    %% The compiled Erlang alone isn't a working client bundle — the
    %% page's client-side render/1 (derived from its .slab template,
    %% same as concrete_renderer uses server-side) has to ride along too,
    %% or the browser has no render function to hydrate/re-render with.
    RenderJS = render_function_js(PageModule, AppInfo),
    JS = unicode:characters_to_binary([ModuleJS, RenderJS]),
    Hash  = crypto:hash(sha256, JS),
    Name  = io_lib:format("~s_~s.mjs", [PageModule, hex(Hash)]),
    OutDir = filename:join(rebar_app_info:priv_dir(AppInfo), "js/bundles"),
    ok = filelib:ensure_dir(filename:join(OutDir, ".")),
    ok = file:write_file(filename:join(OutDir, Name), JS),
    update_manifest(PageModule, Name, AppInfo),
    concrete_plt:put(PLT, digest_key(PageModule), bundle_digest(PageModule, AppInfo)),
    concrete_plt:save(PLT, plt_path(AppInfo)),
    ok.

clean(_AppInfo, _Config) ->
    ok.

%% Internal helpers

%% Parse the page module's .slab template (relative to this project's
%% own priv/templates, mirroring concrete_renderer:template_path/1) and
%% encode its DOM into a client-side render/1 function definition —
%% same path template_demo.erl's hand-rolled bundle_js/1 uses.
render_function_js(PageModule, AppInfo) ->
    TemplatesDir = filename:join(rebar_app_info:priv_dir(AppInfo), "templates"),
    DOM = case PageModule:template() of
        {inline, D} -> D;
        File        -> concrete_template_parser:parse_file(
                           filename:join(TemplatesDir, File))
    end,
    concrete_encoder:encode_function_def(
        PageModule, concrete_template_parser:compile_render_fun(DOM)).

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

%% A bundle is stale if the page module's combined digest (BEAM digest
%% plus, for file-based templates, the template file's contents) doesn't
%% match the digest recorded in the PLT the last time its bundle was
%% built (or if it has never been built). The template file has to be
%% folded in because it's read straight off disk in render_function_js/2
%% rather than compiled into the module's BEAM, so editing a .slab file
%% alone wouldn't otherwise change anything this check could see.
bundle_is_stale(Module, PLT, AppInfo) ->
    case {bundle_digest(Module, AppInfo), concrete_plt:get(PLT, digest_key(Module))} of
        {Digest, {ok, Digest}} when Digest =/= undefined -> false;
        _ -> true
    end.

digest_key(Module) ->
    {Module, '$concrete_bundle_digest', 0}.

bundle_digest(Module, AppInfo) ->
    case module_digest(Module) of
        undefined -> undefined;
        ModDigest -> crypto:hash(sha256, [ModDigest, template_digest(Module, AppInfo)])
    end.

%% Inline templates ({inline, DOM}) live in the module source, so the BEAM
%% digest already accounts for them. File-based templates are read from
%% disk at bundle-build time and need their own content hash.
template_digest(Module, AppInfo) ->
    case Module:template() of
        {inline, _DOM} -> <<>>;
        File ->
            TemplatesDir = filename:join(rebar_app_info:priv_dir(AppInfo), "templates"),
            case file:read_file(filename:join(TemplatesDir, File)) of
                {ok, Bin} -> crypto:hash(sha256, Bin);
                _         -> <<>>
            end
    end.

module_digest(Module) ->
    case code:which(Module) of
        BeamFile when is_list(BeamFile) ->
            case beam_lib:md5(BeamFile) of
                {ok, {_Mod, Digest}} -> Digest;
                _                    -> undefined
            end;
        _ -> undefined
    end.

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
                {ok, #ir_module{definitions = Defs}} ->
                    [concrete_plt:put(PLT, {M, D#ir_function_def.name,
                                            D#ir_function_def.arity}, D)
                     || D <- Defs];
                _ -> ok
            end
    end.

update_manifest(PageModule, BundleName, AppInfo) ->
    Path = filename:join(rebar_app_info:priv_dir(AppInfo), "concrete_manifest.json"),
    Existing = case file:read_file(Path) of
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, Map} -> Map;
                _         -> #{}
            end;
        _ -> #{}
    end,
    Updated = Existing#{atom_to_binary(PageModule) => list_to_binary(BundleName)},
    ok = file:write_file(Path, thoas:encode(Updated)),
    notify_asset_server(Updated).

%% concrete_assets holds the manifest it was handed at application boot
%% and never re-reads it from disk, so a recompile in a live shell (e.g.
%% via r3:compile/0) would otherwise keep serving stale bundle URLs even
%% though the file on disk (and priv/concrete_manifest.json) is current.
%% Best-effort: if the app isn't running (e.g. a plain `rebar3 compile`
%% outside a shell), there's nothing to notify.
notify_asset_server(Manifest) ->
    case whereis(concrete_assets) of
        undefined -> ok;
        Pid       -> Pid ! {reload, Manifest}, ok
    end.

hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
