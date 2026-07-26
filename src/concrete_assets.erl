%% Reads the asset manifest and resolves bundle URLs for page modules.
%%
%% The manifest is read fresh from disk on every call rather than cached
%% in process state: it's written by rebar_compiler_concrete every time
%% a page's bundle is recompiled (e.g. via r3:compile() in a live
%% rebar3 shell), and recompiling can itself kill/restart this process
%% (module purge cascades through the supervision tree) -- OTP would
%% then respawn it with whatever manifest was frozen into concrete_sup's
%% child spec at the *original* boot, silently reverting any cached
%% state. Reading live avoids that whole class of staleness bugs.
-module(concrete_assets).

-export([load_manifest/0, bundle_url/1]).

-spec bundle_url(module()) -> binary().
bundle_url(PageModule) ->
    Manifest = load_manifest(),
    case maps:get(atom_to_binary(PageModule), Manifest, undefined) of
        undefined -> <<"/concrete/assets/missing.mjs">>;
        Bundle    -> <<"/concrete/assets/", Bundle/binary>>
    end.

%% The manifest is written by rebar_compiler_concrete into the priv/ of
%% whichever top-level project actually has page modules -- not
%% necessarily (usually not) concrete's own priv dir -- so this scans
%% every application on the code path, same as concrete_app:page_modules/0.
load_manifest() ->
    Dirs = lists:usort([filename:dirname(Dir) || Dir <- code:get_path()]),
    lists:foldl(fun(AppDir, Acc) ->
        Path = filename:join([AppDir, "priv", "concrete_manifest.json"]),
        case file:read_file(Path) of
            {ok, Bin} ->
                case thoas:decode(Bin) of
                    {ok, Map} -> maps:merge(Acc, Map);
                    _         -> Acc
                end;
            {error, _} -> Acc
        end
    end, #{}, Dirs).
