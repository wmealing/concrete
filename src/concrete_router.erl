%% Builds the cowboy dispatch table from discovered page modules.
-module(concrete_router).

-export([start/1, routes/1]).

-spec start([module()]) -> {ok, pid()}.
start(PageModules) ->
    Dispatch = cowboy_router:compile([{'_', routes(PageModules)}]),
    cowboy:start_clear(concrete_http, [{port, 4000}], #{
        env => #{dispatch => Dispatch}
    }).

-spec routes([module()]) -> list().
routes(PageModules) ->
    page_routes(PageModules) ++ system_routes().

page_routes(Modules) ->
    lists:filtermap(fun(Module) ->
        case route_for(Module) of
            {ok, Route} -> {true, {Route, concrete_page_handler, #{module => Module}}};
            error       -> false
        end
    end, Modules).

route_for(Module) ->
    Attrs = Module:module_info(attributes),
    case [V || {concrete, V} <- Attrs] of
        [[Opts | _] | _] ->
            case proplists:get_value(route, Opts) of
                undefined -> error;
                Route     -> {ok, Route}
            end;
        _ -> error
    end.

system_routes() ->
    [
        {"/concrete/command",      concrete_command_handler, #{}},
        {"/concrete/sse",          concrete_sse_handler,     #{}},
        {"/concrete/ws",           concrete_ws_handler,      #{}},
        {"/concrete/assets/[...]", cowboy_static, {priv_dir, concrete, "js"}}
    ].
