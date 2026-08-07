%% Public API: compile Erlang to JavaScript for use in a web page.
%%
%%   concrete:compile("-module(m). double(X) -> X * 2.")
%%       -> JS binary registering m:double/1 with the runtime
%%   concrete:compile_module(my_module)
%%       -> same, from a loaded module's BEAM (needs debug_info)
%%   concrete:compile_to_file(Src, "m.js")
%%       -> compile a source string and write the JS file
%%   concrete:runtime_path() / client_path()
%%       -> paths to runtime.js / client.js, for copying next to
%%          your generated bundle
-module(concrete).

-export([compile/1, compile_module/1, compile_to_file/2,
         runtime_path/0, client_path/0, init/1]).

%% rebar3 plugin entry point: registers rebar_compiler_concrete into
%% the compiler pipeline for any project that lists `concrete` under
%% {plugins, ...} / {project_plugins, ...}. rebar3 discovers this via
%% a module matching the OTP application name. Not part of the public
%% API docs -- rebar_state:t/0 is an opaque type from rebar itself,
%% which isn't a project dependency, so ex_doc can't resolve it.
-doc false.
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    {ok, rebar_state:append_compilers(State, [rebar_compiler_concrete])}.

%% Compile an Erlang source string (one module) to JavaScript.
-spec compile(string() | binary()) -> binary().
compile(Src) when is_binary(Src) ->
    compile(unicode:characters_to_list(Src));
compile(Src) ->
    Forms = parse_source(Src),
    ModName = module_name(Forms),
    Ctx = concrete_transformer:new_ctx(ModName),
    IR  = concrete_transformer:transform_module(Forms, Ctx),
    unicode:characters_to_binary(concrete_encoder:encode_module(IR)).

%% Compile a loaded module from its BEAM (requires debug_info).
-spec compile_module(module()) -> binary().
compile_module(Module) ->
    {ok, IR} = concrete_beam_reader:extract_ir(Module),
    unicode:characters_to_binary(concrete_encoder:encode_module(IR)).

-spec compile_to_file(string() | binary(), file:filename()) -> ok.
compile_to_file(Src, Path) ->
    ok = file:write_file(Path, compile(Src)).

%% Path to the browser runtime (Type/Interpreter/Erlang BIF table).
-spec runtime_path() -> file:filename().
runtime_path() ->
    filename:join([code:priv_dir(concrete), "js", "demo", "runtime.js"]).

%% Path to the client (hydration + action dispatch).
-spec client_path() -> file:filename().
client_path() ->
    filename:join([code:priv_dir(concrete), "js", "demo", "client.js"]).

%% --- helpers ---

parse_source(Src) ->
    {ok, Tokens, _} = erl_scan:string(Src),
    parse_forms(Tokens, []).

parse_forms([], Acc) ->
    lists:reverse(Acc);
parse_forms(Tokens, Acc) ->
    case split_at_dot(Tokens) of
        {[], _} -> lists:reverse(Acc);
        {FormTokens, Rest} ->
            case erl_parse:parse_form(FormTokens) of
                {ok, Form} -> parse_forms(Rest, [Form | Acc]);
                _          -> parse_forms(Rest, Acc)
            end
    end.

split_at_dot(Tokens) ->
    split_at_dot(Tokens, []).

split_at_dot([], Acc) ->
    {lists:reverse(Acc), []};
split_at_dot([{dot, _} = D | Rest], Acc) ->
    {lists:reverse([D | Acc]), Rest};
split_at_dot([H | T], Acc) ->
    split_at_dot(T, [H | Acc]).

module_name(Forms) ->
    hd([Name || {attribute, _, module, Name} <- Forms]).
