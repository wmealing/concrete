%% rebar3 compiler plugin for Concrete.
%% Implements the rebar_compiler behaviour (rebar3 3.14+).
-module(rebar_compiler_concrete).
-behaviour(rebar_compiler).
-include("concrete_ir.hrl").

-export([context/1, needed_files/4, dependencies/3, compile/4, clean/2]).
%% Exported for direct testing -- discover_modules/2's recursive
%% <:component> traversal, bundle_digest/2's dependency hashing, and
%% populate_plt/2's call-graph-driven PLT population are otherwise only
%% reachable through compile/4, which needs a real rebar_app_info
%% record to call.
-export([discover_modules/2, bundle_digest/2, populate_plt/2]).

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
    TemplatesDir = templates_dir(AppInfo),
    PageModules = find_page_modules(AppInfo),
    Changed = [M || M <- PageModules, bundle_is_stale(M, PLT, TemplatesDir)],
    %% rebar_compiler's needed_files/4 contract: {{FirstFiles, FirstOpts},
    %% {RestFiles, Opts}} — we have no priority group, and thread AppInfo
    %% through as the per-file Opts term (compile/4's 4th argument).
    {{[], []}, {Changed, AppInfo}}.

dependencies(_Source, _SourceDir, _Dirs) ->
    [].

compile(PageModule, _Mappings, _Config, AppInfo) ->
    rebar_api:info("Concrete: compiling bundle for ~s", [PageModule]),
    PLT = concrete_plt:load_or_new(plt_path(AppInfo)),
    TemplatesDir = templates_dir(AppInfo),
    %% A page's bundle needs not just its own code, but every module it
    %% embeds via <:component> in its template (transitively -- a child
    %% component's own template can embed further components), or the
    %% browser has nothing to run when it hits one of those tags.
    {Modules, DOMs} = discover_modules(PageModule, TemplatesDir),
    populate_plt(PLT, Modules),
    Entries = lists:flatmap(fun(Mod) -> concrete_call_graph:page_entries(Mod, PLT) end, Modules),
    Graph = concrete_call_graph:build_from_entries(Entries, PLT),
    ModuleJS = concrete_encoder:encode_bundle(Graph, PLT),
    %% The compiled Erlang alone isn't a working client bundle — each
    %% module's client-side render/1 (derived from its own .slab
    %% template, same as concrete_renderer uses server-side) has to ride
    %% along too, one per module, or the browser has no render function
    %% to hydrate/re-render with.
    RenderJS = render_functions_js(Modules, DOMs),
    JS = unicode:characters_to_binary([ModuleJS, RenderJS]),
    Hash  = crypto:hash(sha256, JS),
    Name  = io_lib:format("~s_~s.mjs", [PageModule, hex(Hash)]),
    OutDir = filename:join(rebar_app_info:priv_dir(AppInfo), "js/bundles"),
    ok = filelib:ensure_dir(filename:join(OutDir, ".")),
    ok = file:write_file(filename:join(OutDir, Name), JS),
    update_manifest(PageModule, Name, AppInfo),
    concrete_plt:put(PLT, digest_key(PageModule), bundle_digest(Modules, TemplatesDir)),
    concrete_plt:save(PLT, plt_path(AppInfo)),
    ok.

clean(_AppInfo, _Config) ->
    ok.

%% Internal helpers

templates_dir(AppInfo) ->
    filename:join(rebar_app_info:priv_dir(AppInfo), "templates").

%% Starting from PageModule (and its layout module, if it declares one
%% via -concrete([{layout, Mod}, ...])), follow <:component> references
%% in every module's own template to build the full set of modules this
%% page's bundle needs, plus each one's parsed DOM (reused later for
%% both entry discovery and render/1 generation, so it's only parsed
%% once). The layout root has to be found this way rather than treated
%% like any other discovered module: unlike <:component>, a layout
%% reference lives in the page's -concrete(...) attribute, not its
%% template, so component_modules/1 alone would never find it.
discover_modules(PageModule, TemplatesDir) ->
    Roots = case concrete_renderer:layout_for(PageModule) of
        undefined           -> [PageModule];
        {LayoutModule, _Ps} -> [PageModule, LayoutModule]
    end,
    discover_modules(Roots, TemplatesDir, [], #{}).

discover_modules([], _TemplatesDir, Seen, DOMs) ->
    {lists:reverse(Seen), DOMs};
discover_modules([Mod | Rest], TemplatesDir, Seen, DOMs) ->
    case lists:member(Mod, Seen) of
        true ->
            discover_modules(Rest, TemplatesDir, Seen, DOMs);
        false ->
            DOM = module_dom(Mod, TemplatesDir),
            Children = concrete_template_parser:component_modules(DOM),
            discover_modules(Children ++ Rest, TemplatesDir, [Mod | Seen], DOMs#{Mod => DOM})
    end.

%% template/0 returns either {inline, DOM} or a .slab filename.
%% Relative filenames resolve against this project's own priv/templates.
module_dom(Module, TemplatesDir) ->
    case Module:template() of
        {inline, DOM} -> DOM;
        File          -> concrete_template_parser:parse_file(
                              filename:join(TemplatesDir, File))
    end.

render_functions_js(Modules, DOMs) ->
    [concrete_encoder:encode_function_def(
         Mod, concrete_template_parser:compile_render_fun(maps:get(Mod, DOMs)))
     || Mod <- Modules].

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

%% A bundle is stale if the combined digest of every module it depends
%% on (its own BEAM plus, for file-based templates, the template file's
%% contents — for the page and for every component it embeds) doesn't
%% match the digest recorded in the PLT the last time its bundle was
%% built (or if it has never been built). Editing a child component's
%% module or .slab, not just the page's own, must also invalidate the
%% page's bundle now that the bundle embeds that component's code too.
bundle_is_stale(Module, PLT, TemplatesDir) ->
    {Modules, _DOMs} = discover_modules(Module, TemplatesDir),
    case {bundle_digest(Modules, TemplatesDir), concrete_plt:get(PLT, digest_key(Module))} of
        {Digest, {ok, Digest}} when Digest =/= undefined -> false;
        _ -> true
    end.

digest_key(Module) ->
    {Module, '$concrete_bundle_digest', 0}.

bundle_digest([], _TemplatesDir) ->
    undefined;
bundle_digest(Modules, TemplatesDir) ->
    Digests = [module_digest(M) || M <- Modules],
    case lists:member(undefined, Digests) of
        true  -> undefined;
        false -> crypto:hash(sha256, [[D, template_digest(M, TemplatesDir)]
                                       || {M, D} <- lists:zip(Modules, Digests)])
    end.

%% Inline templates ({inline, DOM}) live in the module source, so the BEAM
%% digest already accounts for them. File-based templates are read from
%% disk at bundle-build time and need their own content hash.
template_digest(Module, TemplatesDir) ->
    case Module:template() of
        {inline, _DOM} -> <<>>;
        File ->
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

%% Populates the PLT with IR for every entry module plus, transitively,
%% every module those entry points actually call (stdlib included) --
%% two passes, because population is coarse-grained (caching one MFA of
%% a module pulls in that module's whole function set, see
%% populate_mfa/2) but page_entries/2 needs the PLT already populated to
%% correctly detect whether a module exports action/3 (command/3 is
%% never a root -- see concrete_call_graph:page_entries/2).
%% Pass 1 seeds the PLT with each entry module's own code via one known
%% MFA (template/0, always exported). Pass 2 does a real graph walk from
%% every entry module's real entry points -- now resolvable -- and
%% populates whatever further modules that walk reaches.
populate_plt(PLT, Modules) ->
    [populate_mfa(PLT, {Mod, template, 0}) || Mod <- Modules],
    Entries = lists:flatmap(fun(Mod) -> concrete_call_graph:page_entries(Mod, PLT) end, Modules),
    Graph = concrete_call_graph:build_from_entries(Entries, PLT),
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
    ok = file:write_file(Path, thoas:encode(Updated)).

hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
