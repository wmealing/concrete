%% Phase 1 end-to-end pipeline test.
%% Verifies that source code flows correctly through each stage:
%%   Erlang source → erl_parse → AST → transformer → IR → encoder → JS string
%%
%% Does NOT execute the JS — that requires a Node.js integration test.
%% These tests confirm the pipeline produces plausible, non-crashing output.
-module(pipeline_SUITE).
-include_lib("common_test/include/ct.hrl").
-include("concrete_ir.hrl").

-export([all/0, groups/0]).
-export([
    identity_function/1,
    map_access/1,
    pattern_match_clauses/1,
    arithmetic/1,
    remote_call/1,
    nested_case/1
]).

all() ->
    [{group, all_parallel}].

%% All cases are independent; run them in parallel.
groups() ->
    [{all_parallel, [parallel], [
        identity_function,
        map_access,
        pattern_match_clauses,
        arithmetic,
        remote_call,
        nested_case
    ]}].
%% Parse an Erlang source string and transform all forms to IR.
src_to_ir(Src) ->
    {ok, Tokens, _} = erl_scan:string(Src),
    Forms = parse_all(Tokens, []),
    Ctx   = concrete_transformer:new_ctx(test_mod),
    concrete_transformer:transform_module(Forms, Ctx).

%% Encode a full IR module to JS.
ir_to_js(IR) ->
    iolist_to_binary(concrete_encoder:encode_module(IR)).

%% Helper: parse all top-level forms from a token stream.
parse_all([], Acc) -> lists:reverse(Acc);
parse_all(Tokens, Acc) ->
    case split_dot(Tokens) of
        {[], _}              -> lists:reverse(Acc);
        {FormToks, Rest}     ->
            case erl_parse:parse_form(FormToks) of
                {ok, Form} -> parse_all(Rest, [Form | Acc]);
                _          -> parse_all(Rest, Acc)
            end
    end.

split_dot(T) -> split_dot(T, []).
split_dot([], Acc)                  -> {lists:reverse(Acc), []};
split_dot([{dot,_}=D|Rest], Acc)    -> {lists:reverse([D|Acc]), Rest};
split_dot([H|T], Acc)               -> split_dot(T, [H|Acc]).

%% --- Tests ---

identity_function(_Config) ->
    Src = "-module(test_mod). id(X) -> X.",
    IR  = src_to_ir(Src),
    #ir_module{name = test_mod, definitions = [Def]} = IR,
    #ir_function_def{name = id, arity = 1} = Def,
    JS = ir_to_js(IR),
    true = binary:match(JS, <<"defineErlangFunction">>) =/= nomatch,
    true = binary:match(JS, <<"\"id\"">>) =/= nomatch.

map_access(_Config) ->
    Src = "-module(test_mod). get_count(#{count := N}) -> N.",
    IR  = src_to_ir(Src),
    JS  = ir_to_js(IR),
    true = byte_size(JS) > 0.

pattern_match_clauses(_Config) ->
    Src = "-module(test_mod).\n"
          "label(ok) -> done;\n"
          "label(error) -> failed.",
    IR  = src_to_ir(Src),
    %% Two clauses should be present on the single function def
    [#ir_function_def{name = label, arity = 1, clauses = Cls}] =
        IR#ir_module.definitions,
    2 = length(Cls),
    JS = ir_to_js(IR),
    true = binary:match(JS, <<"\"label\"">>) =/= nomatch.

arithmetic(_Config) ->
    Src = "-module(test_mod). add(A, B) -> A + B.",
    IR  = src_to_ir(Src),
    JS  = ir_to_js(IR),
    true = binary:match(JS, <<"+/2">>) =/= nomatch.

remote_call(_Config) ->
    Src = "-module(test_mod). rev(L) -> lists:reverse(L).",
    IR  = src_to_ir(Src),
    JS  = ir_to_js(IR),
    true = binary:match(JS, <<"lists:reverse/1">>) =/= nomatch.

nested_case(_Config) ->
    Src = "-module(test_mod).\n"
          "check(X) ->\n"
          "  case X of\n"
          "    ok    -> good;\n"
          "    error -> bad\n"
          "  end.",
    IR  = src_to_ir(Src),
    JS  = ir_to_js(IR),
    true = binary:match(JS, <<"Interpreter.matchClauses(">>) =/= nomatch.
