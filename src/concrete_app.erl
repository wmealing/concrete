%% OTP application callback and supervision tree.
-module(concrete_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = pg:start(concrete_pubsub),
    Manifest = load_manifest(),
    PageModules = page_modules(),
    {ok, _} = concrete_router:start(PageModules),
    Children = [
        {concrete_assets,
            {concrete_assets, start_link, [Manifest]},
            permanent, 5000, worker, [concrete_assets]},
        {concrete_registry,
            {concrete_registry, start_link, []},
            permanent, 5000, worker, [concrete_registry]}
    ],
    supervisor:start_link({local, concrete_sup}, concrete_sup_mod, Children).

stop(_State) ->
    ok.

load_manifest() ->
    ManifestPath = filename:join(code:priv_dir(concrete), "concrete_manifest.json"),
    case file:read_file(ManifestPath) of
        {ok, Bin} -> thoas:decode(Bin);
        {error, _} -> #{}
    end.

page_modules() ->
    [M || {M, _, _} <- code:all_loaded(),
          is_page_module(M)].

is_page_module(Module) ->
    Attrs = Module:module_info(attributes),
    lists:any(fun({behaviour, Bs}) -> lists:member(concrete_page, Bs);
                 (_) -> false
              end, Attrs).
