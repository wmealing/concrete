%% OTP application callback and supervision tree.
-module(concrete_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Manifest = load_manifest(),
    case concrete_sup:start_link(Manifest) of
        {ok, Pid} ->
            PageModules = page_modules(),
            {ok, _} = concrete_router:start(PageModules),
            {ok, Pid};
        {error, _} = Err ->
            Err
    end.

stop(_State) ->
    ok.

%% The manifest is written by rebar_compiler_concrete into the priv/ of
%% whichever top-level project actually has page modules — not
%% necessarily (usually not) concrete's own priv dir — so this scans
%% every application on the code path, same as page_modules/0 below.
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

%% Scans the code path on disk rather than code:all_loaded/0: concrete
%% (and this callback) typically starts before the application that
%% actually defines page modules (they depend on concrete, not the
%% other way round), so those modules are usually not loaded yet — but
%% calling Module:module_info/1 below loads them on demand.
page_modules() ->
    Beams = [filename:join(Dir, F) || Dir <- code:get_path(),
                                       F <- beam_files(Dir)],
    lists:usort([M || Beam <- Beams,
                       M <- [beam_module(Beam)],
                       is_page_module(M)]).

beam_files(Dir) ->
    filelib:wildcard("*.beam", Dir).

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
