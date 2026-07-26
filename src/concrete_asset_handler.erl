%% Serves /concrete/assets/* by scanning every application's priv/js
%% directory on the code path, not just concrete's own -- page bundles
%% are written under the *consuming* app's priv/js/bundles/ by
%% rebar_compiler_concrete (e.g. my_app/priv/js/bundles/*.mjs), while
%% concrete's own runtime/demo assets live under concrete/priv/js/.
-module(concrete_asset_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, State) ->
    Segments = cowboy_req:path_info(Req),
    Req2 = case safe_relpath(Segments) of
        {ok, RelPath} ->
            case find_asset(RelPath) of
                {ok, FilePath} -> serve_file(FilePath, Req);
                error -> cowboy_req:reply(404, Req)
            end;
        error ->
            cowboy_req:reply(400, Req)
    end,
    {ok, Req2, State}.

%% Reject empty requests and any ".."/"." segment to prevent escaping
%% the priv/js roots being scanned.
safe_relpath([]) -> error;
safe_relpath(Segments) ->
    case lists:all(fun(S) -> S =/= <<"..">> andalso S =/= <<".">> end, Segments) of
        true  -> {ok, filename:join([binary_to_list(S) || S <- Segments])};
        false -> error
    end.

find_asset(RelPath) ->
    Dirs = lists:usort([filename:dirname(Dir) || Dir <- code:get_path()]),
    find_in_dirs(RelPath, Dirs).

find_in_dirs(_RelPath, []) -> error;
find_in_dirs(RelPath, [AppDir | Rest]) ->
    %% rebar_compiler_concrete writes page bundles under priv/js/bundles/,
    %% but the manifest URL (built in concrete_assets) has no "bundles/"
    %% segment, so both roots have to be tried; other assets (runtime.js,
    %% client.js, ...) are referenced by their real relative path and are
    %% found directly under priv/js/.
    Candidates = [filename:join([AppDir, "priv", "js", RelPath]),
                  filename:join([AppDir, "priv", "js", "bundles", RelPath])],
    case lists:filter(fun filelib:is_regular/1, Candidates) of
        [Found | _] -> {ok, Found};
        []          -> find_in_dirs(RelPath, Rest)
    end.

serve_file(FilePath, Req) ->
    {ok, Data} = file:read_file(FilePath),
    {Type, SubType, _} = cow_mimetypes:web(FilePath),
    ContentType = <<Type/binary, "/", SubType/binary>>,
    cowboy_req:reply(200, #{<<"content-type">> => ContentType}, Data, Req).
