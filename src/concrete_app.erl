%% OTP application callback and supervision tree.
-module(concrete_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    case concrete_sup:start_link() of
        {ok, Pid} ->
            PageModules = page_modules(),
            {ok, _} = concrete_router:start(PageModules),
            {ok, Pid};
        {error, _} = Err ->
            Err
    end.

stop(_State) ->
    ok.

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
