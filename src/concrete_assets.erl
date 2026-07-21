%% Reads the asset manifest and resolves bundle URLs for page modules.
-module(concrete_assets).

-export([start_link/1, bundle_url/1]).

-spec start_link(map()) -> {ok, pid()}.
start_link(Manifest) ->
    Pid = spawn_link(fun() -> loop(Manifest) end),
    register(concrete_assets, Pid),
    {ok, Pid}.

-spec bundle_url(module()) -> binary().
bundle_url(PageModule) ->
    concrete_assets ! {get_url, PageModule, self()},
    receive
        {url, URL} -> URL
    after 5000 ->
        error({timeout, bundle_url, PageModule})
    end.

loop(Manifest) ->
    receive
        {get_url, Module, From} ->
            URL = case maps:get(atom_to_binary(Module), Manifest, undefined) of
                undefined -> <<"/concrete/assets/missing.mjs">>;
                Bundle    -> <<"/concrete/assets/", Bundle/binary>>
            end,
            From ! {url, URL},
            loop(Manifest);
        {reload, NewManifest} ->
            loop(NewManifest)
    end.
