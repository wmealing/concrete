%% Public API tests: concrete:compile/1, compile_module/1, paths.
-module(api_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    compile_source_string/1,
    compile_to_file/1,
    compile_module_from_beam/1,
    runtime_paths_exist/1
]).

all() ->
    [{group, all_parallel}].

groups() ->
    [{all_parallel, [parallel],
      [compile_source_string,
       compile_to_file,
       compile_module_from_beam,
       runtime_paths_exist]}].

compile_source_string(_Config) ->
    JS = concrete:compile("-module(m). double(X) -> X * 2."),
    true = is_binary(JS),
    {_, _} = binary:match(JS, <<"defineErlangFunction(\"m\", \"double\", 1">>).

compile_to_file(Config) ->
    Path = filename:join(?config(priv_dir, Config), "m.js"),
    ok = concrete:compile_to_file("-module(m). id(X) -> X.", Path),
    {ok, JS} = file:read_file(Path),
    {_, _} = binary:match(JS, <<"defineErlangFunction(\"m\", \"id\", 1">>).

compile_module_from_beam(_Config) ->
    %% fixture_counter is compiled with debug_info by the test build
    JS = concrete:compile_module(fixture_counter),
    {_, _} = binary:match(JS, <<"defineErlangFunction(\"fixture_counter\", \"action\", 3">>).

runtime_paths_exist(_Config) ->
    true = filelib:is_regular(concrete:runtime_path()),
    true = filelib:is_regular(concrete:client_path()).
