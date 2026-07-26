# Erlang Hologram — Implementation Details

Technical reference for implementing the compiler pipeline, runtime, and tooling described in `plan.md`.

---

## 1. IR Record Definitions (`hologram_ir.hrl`)

All IR nodes are Erlang records. Every record has at least a `type` field (an atom matching the record name) so the encoder can dispatch without knowing the record name at compile time via `element(1, Node)`.

```erlang
%% Primitive types
-record(ir_atom,        {value :: atom()}).
-record(ir_integer,     {value :: integer()}).
-record(ir_float,       {value :: float()}).
-record(ir_string,      {value :: binary()}).          % UTF-8 binary
-record(ir_bitstring,   {segments :: [#ir_bs_segment{}]}).
-record(ir_bs_segment,  {value, size, type, unit, signedness, endianness}).
-record(ir_pid,         {}).                           % placeholder; pids not compile-time
-record(ir_nil,         {}).                           % []

%% Compound types
-record(ir_tuple,       {elements :: [ir()]}).
-record(ir_list,        {elements :: [ir()], tail :: ir() | nil}).  % nil = proper list
-record(ir_map,         {pairs :: [{ir(), ir()}]}).
-record(ir_map_update,  {map :: ir(), pairs :: [{ir(), ir()}]}).

%% Variables & matching
-record(ir_variable,    {name :: atom()}).
-record(ir_match,       {pattern :: ir(), expr :: ir()}).
-record(ir_wildcard,    {}).                           % _

%% Function definitions
-record(ir_module,      {name :: atom(), definitions :: [#ir_function_def{}]}).
-record(ir_function_def,{name :: atom(), arity :: non_neg_integer(),
                         clauses :: [#ir_clause{}]}).
-record(ir_clause,      {patterns :: [ir()], guards :: [[ir()]], body :: [ir()]}).
%% guards is a list of guard sequences (OR of ANDs): [[G1,G2],[G3]] = (G1 and G2) or G3

%% Function calls
-record(ir_local_call,  {name :: atom(), arity :: non_neg_integer(), args :: [ir()]}).
-record(ir_remote_call, {module :: ir(), function :: ir(), arity :: non_neg_integer(),
                         args :: [ir()]}).
-record(ir_anon_call,   {function :: ir(), args :: [ir()]}).
-record(ir_anon_fun,    {clauses :: [#ir_clause{}], arity :: non_neg_integer()}).
-record(ir_fun_ref,     {module :: atom(), function :: atom(),
                         arity :: non_neg_integer()}).   % fun m:f/a

%% Control flow
-record(ir_block,       {exprs :: [ir()]}).
-record(ir_case,        {expr :: ir(), clauses :: [#ir_clause{}]}).
-record(ir_if,          {clauses :: [#ir_clause{}]}).   % if guard -> body; ... end
-record(ir_receive,     {clauses :: [#ir_clause{}], after_expr :: ir() | nil,
                         after_body :: [ir()] | nil}).
-record(ir_try,         {body :: [ir()],
                         of_clauses :: [#ir_clause{}],
                         catch_clauses :: [#ir_catch_clause{}],
                         after_body :: [ir()]}).
-record(ir_catch_clause,{class :: ir(), pattern :: ir(), guards :: [[ir()]],
                         body :: [ir()]}).
-record(ir_throw,       {expr :: ir()}).

%% Comprehensions
-record(ir_lc,          {template :: ir(), qualifiers :: [ir()]}).
-record(ir_bc,          {template :: #ir_bs_segment{}, qualifiers :: [ir()]}).
-record(ir_lc_gen,      {pattern :: ir(), expr :: ir()}).  % Pattern <- Expr
-record(ir_bc_gen,      {pattern :: #ir_bs_segment{}, expr :: ir()}).
-record(ir_lc_filter,   {expr :: ir()}).

%% Operators
-record(ir_binop,       {op :: atom(), left :: ir(), right :: ir()}).
-record(ir_unop,        {op :: atom(), operand :: ir()}).
-record(ir_cons,        {head :: ir(), tail :: ir()}).

-type ir() ::
    #ir_atom{} | #ir_integer{} | #ir_float{} | #ir_string{} | #ir_bitstring{} |
    #ir_nil{} | #ir_tuple{} | #ir_list{} | #ir_map{} | #ir_map_update{} |
    #ir_variable{} | #ir_match{} | #ir_wildcard{} |
    #ir_module{} | #ir_function_def{} | #ir_clause{} |
    #ir_local_call{} | #ir_remote_call{} | #ir_anon_call{} |
    #ir_anon_fun{} | #ir_fun_ref{} |
    #ir_block{} | #ir_case{} | #ir_if{} | #ir_receive{} | #ir_try{} |
    #ir_lc{} | #ir_bc{} |
    #ir_binop{} | #ir_unop{} | #ir_cons{}.
```

---

## 2. Erlang AST → IR Transformer

`erl_parse` produces forms like these. Map each to the corresponding IR record.

### AST form reference

```erlang
%% Module declaration (top-level form)
{attribute, Line, module, ModuleName}

%% Function definition (top-level form)
{function, Line, Name, Arity, Clauses}

%% Function clause
{clause, Line, Patterns, Guards, Body}
%% Guards = [[GuardExpr]] (list of guard seqs; OR of ANDs)

%% Literals
{atom, Line, Value}
{integer, Line, Value}
{float, Line, Value}
{string, Line, CharList}           % "foo" is a charlist — treat as binary in component code
{nil, Line}                        % []

%% Compound
{tuple, Line, Elements}
{cons, Line, Head, Tail}
{bin, Line, BinElements}
{bin_element, Line, Expr, Size, TSL}  % TSL = type specifier list

%% Map
{map, Line, Assocs}                % #{k => v}
{map, Line, Expr, Assocs}          % Expr#{k => v} (update)
{map_field_assoc, Line, Key, Val}  % k => v (new key)
{map_field_exact, Line, Key, Val}  % k := v (existing key, pattern or update)

%% Variables & matching
{var, Line, '_'}                   % wildcard
{var, Line, Name}                  % any other uppercase name
{match, Line, Pattern, Expr}       % Pattern = Expr

%% Calls
{call, Line, {atom, Line, Fun}, Args}                       % local
{call, Line, {remote, Line, {atom,_,Mod}, {atom,_,Fun}}, Args}  % remote
{call, Line, FunExpr, Args}                                 % higher-order

%% Anonymous funs
{'fun', Line, {clauses, Clauses}}
{'fun', Line, {function, Name, Arity}}                      % fun f/2
{'fun', Line, {function, Mod, Name, Arity}}                 % fun m:f/2

%% Operators
{op, Line, Op, Left, Right}        % binary op
{op, Line, Op, Operand}            % unary op ('not', '-', '+', 'bnot')

%% Control flow
{'case', Line, Expr, Clauses}
{'if', Line, Clauses}
{'receive', Line, Clauses}
{'receive', Line, Clauses, AfterExpr, AfterBody}
{'try', Line, Body, OfClauses, CatchClauses, AfterBody}
{'catch', Line, Expr}

%% Comprehensions
{lc, Line, Template, Qualifiers}
{bc, Line, Template, Qualifiers}
{generate, Line, Pattern, Expr}    % Pattern <- Expr
{b_generate, Line, Pattern, Expr}  % Pattern <= Expr (binary gen)

%% Block
{block, Line, Exprs}
```

### Transformer skeleton

```erlang
-module(hologram_transformer).
-include("hologram_ir.hrl").
-export([transform_module/2]).

transform_module(Forms, Ctx) ->
    Defs = [transform_form(F, Ctx) || F <- Forms, is_function_form(F)],
    ModName = module_name(Forms),
    #ir_module{name = ModName, definitions = lists:flatten(Defs)}.

transform_form({function, _L, Name, _Arity, Clauses}, Ctx) ->
    IRClauses = [transform_clause(C, Ctx) || C <- Clauses],
    Arity = length(element(3, hd(Clauses))),
    #ir_function_def{name = Name, arity = Arity, clauses = IRClauses}.

transform_clause({clause, _L, Patterns, Guards, Body}, Ctx) ->
    #ir_clause{
        patterns = [transform_expr(P, Ctx#ctx{in_pattern = true}) || P <- Patterns],
        guards   = [[transform_expr(G, Ctx) || G <- Seq] || Seq <- Guards],
        body     = [transform_expr(E, Ctx) || E <- Body]
    }.

transform_expr({atom, _, V}, _Ctx)    -> #ir_atom{value = V};
transform_expr({integer, _, V}, _Ctx) -> #ir_integer{value = V};
transform_expr({float, _, V}, _Ctx)   -> #ir_float{value = V};
transform_expr({nil, _}, _Ctx)        -> #ir_nil{};
transform_expr({var, _, '_'}, _Ctx)   -> #ir_wildcard{};
transform_expr({var, _, Name}, _Ctx)  -> #ir_variable{name = Name};
transform_expr({tuple, _, Es}, Ctx)   -> #ir_tuple{elements = [transform_expr(E, Ctx) || E <- Es]};
transform_expr({cons, _, H, T}, Ctx)  -> #ir_cons{head = transform_expr(H, Ctx),
                                                    tail = transform_expr(T, Ctx)};
transform_expr({match, _, P, E}, Ctx) -> #ir_match{
                                            pattern = transform_expr(P, Ctx#ctx{in_pattern=true}),
                                            expr    = transform_expr(E, Ctx)};
transform_expr({'case', _, E, Cls}, Ctx) ->
    #ir_case{expr = transform_expr(E, Ctx),
             clauses = [transform_clause(C, Ctx) || C <- Cls]};
transform_expr({call, _, {remote,_,{atom,_,M},{atom,_,F}}, Args}, Ctx) ->
    #ir_remote_call{module = #ir_atom{value=M}, function = #ir_atom{value=F},
                    arity = length(Args), args = [transform_expr(A,Ctx) || A <- Args]};
transform_expr({call, _, {atom,_,F}, Args}, Ctx) ->
    #ir_local_call{name = F, arity = length(Args),
                   args = [transform_expr(A, Ctx) || A <- Args]};
transform_expr({map, _, Assocs}, Ctx) ->
    #ir_map{pairs = [transform_assoc(A, Ctx) || A <- Assocs]};
transform_expr({map, _, Expr, Assocs}, Ctx) ->
    #ir_map_update{map = transform_expr(Expr, Ctx),
                   pairs = [transform_assoc(A, Ctx) || A <- Assocs]};
transform_expr({op, _, Op, L, R}, Ctx) ->
    #ir_binop{op=Op, left=transform_expr(L,Ctx), right=transform_expr(R,Ctx)};
transform_expr({op, _, Op, E}, Ctx) ->
    #ir_unop{op=Op, operand=transform_expr(E,Ctx)};
transform_expr({'fun', _, {clauses, Cls}}, Ctx) ->
    #ir_anon_fun{clauses = [transform_clause(C,Ctx) || C <- Cls],
                 arity   = clause_arity(hd(Cls))};
transform_expr({'fun', _, {function, F, A}}, _Ctx) ->
    #ir_fun_ref{module = current_module, function = F, arity = A};
transform_expr({'fun', _, {function, M, F, A}}, _Ctx) ->
    #ir_fun_ref{module = M, function = F, arity = A};
%% ... etc for lc, bc, receive, try, if, block, bin
transform_expr(Node, _Ctx) ->
    error({unhandled_ast_node, Node}).

transform_assoc({map_field_assoc, _, K, V}, Ctx) -> {transform_expr(K,Ctx), transform_expr(V,Ctx)};
transform_assoc({map_field_exact, _, K, V}, Ctx) -> {transform_expr(K,Ctx), transform_expr(V,Ctx)}.
```

### Context record

```erlang
-record(ctx, {
    module      :: atom(),
    imports     :: [{atom(), non_neg_integer()}],  % imported functions
    in_pattern  = false :: boolean()
}).
```

### Edge cases to handle

- `{string, _, Chars}` where `Chars` is a charlist: convert to `#ir_string{value = list_to_binary(Chars)}` for component code. Warn if a raw charlist is used where a binary is expected.
- `{lc, _, {bc, ...}, _}` — binary comprehensions inside list comprehensions: handle recursively.
- `{block, _, Exprs}` — sequence of expressions, transform to `#ir_block{exprs = ...}`.
- Guard sequences: `Guards = [[G1, G2], [G3]]` means `(G1 andalso G2) orelse G3`. Preserve this structure in `#ir_clause.guards`.
- `{'catch', _, Expr}` — the catch expression (not catch clause in try). Maps to a wrapping IR node or inline try.
- Records: `{record, _, Name, Fields}` — either expand to map IR at transform time (requires knowing the record definition), or error with "records not supported in component code, use maps instead".

---

## 3. IR → JavaScript Encoder

The encoder turns IR nodes into JavaScript string fragments. The JS runtime uses `defineElixirFunction()` to register function clauses.

### JS runtime API (from Hologram's `interpreter.mjs`)

```javascript
// Register an Erlang function with its clauses
Interpreter.defineElixirFunction("ModuleName", "functionName", arity, [
  [
    // clause 1: [matchSpec, guardFn, bodyFn]
    (args) => matchResult,   // pattern match fn — returns null if no match, else bindings
    (bindings) => boolean,   // guard fn — true/false
    (bindings) => term,      // body fn — returns Erlang term
  ],
  // clause 2, ...
]);

// Erlang term constructors (from type.mjs)
Type.atom("ok")
Type.integer(42)
Type.float(3.14)
Type.bitstring("hello")
Type.tuple([...])
Type.list([...])
Type.map([[Type.atom("key"), Type.integer(1)])
Type.pid(...)
```

### Encoder output structure

For each module:

```javascript
// Generated bundle fragment for module `counter`
Interpreter.defineElixirFunction("counter", "init", 2, [
  [
    // clause 1: init(Props, Server)
    (args) => {
      const [props, server] = args;
      // bindings from pattern match (Props and Server are just variables, always match)
      return {props, server};
    },
    (_bindings) => true,  // no guard
    ({props, server}) => {
      const count = Erlang["maps:get/3"](Type.atom("initial_value"), props, Type.integer(0));
      return Type.tuple([
        Type.map([[Type.atom("state"), Type.map([[Type.atom("count"), count]])]]),
        server
      ]);
    }
  ]
]);
```

### Encoder skeleton

```erlang
-module(hologram_encoder).
-include("hologram_ir.hrl").
-export([encode_module/1, encode_ir/1]).

encode_module(#ir_module{name = Name, definitions = Defs}) ->
    Header = io_lib:format("// Module: ~s\n", [Name]),
    Body = [encode_function_def(Name, D) || D <- Defs],
    [Header | Body].

encode_function_def(ModName, #ir_function_def{name=Fun, arity=Arity, clauses=Clauses}) ->
    ClausesJS = [encode_clause(C) || C <- Clauses],
    io_lib:format(
        "Interpreter.defineElixirFunction(~s, ~s, ~w, [\n~s]);\n",
        [encode_string(atom_to_binary(ModName)), encode_string(atom_to_binary(Fun)),
         Arity, join(ClausesJS, ",\n")]
    ).

encode_clause(#ir_clause{patterns=Pats, guards=Guards, body=Body}) ->
    PatJS   = encode_pattern_fn(Pats),
    GuardJS = encode_guard_fn(Guards),
    BodyJS  = encode_body_fn(Body),
    io_lib:format("  [~s, ~s, ~s]", [PatJS, GuardJS, BodyJS]).

encode_ir(#ir_atom{value = true})  -> "Type.atom(\"true\")";
encode_ir(#ir_atom{value = false}) -> "Type.atom(\"false\")";
encode_ir(#ir_atom{value = V})     -> io_lib:format("Type.atom(~s)", [encode_string(atom_to_binary(V))]);
encode_ir(#ir_integer{value = V})  -> io_lib:format("Type.integer(~w)", [V]);
encode_ir(#ir_float{value = V})    -> io_lib:format("Type.float(~w)", [V]);
encode_ir(#ir_nil{})               -> "Type.list([])";
encode_ir(#ir_tuple{elements=Es})  ->
    io_lib:format("Type.tuple([~s])", [join([encode_ir(E)||E<-Es], ", ")]);
encode_ir(#ir_map{pairs=Pairs})    ->
    io_lib:format("Type.map([~s])", [join([encode_pair(P)||P<-Pairs], ", ")]);
encode_ir(#ir_variable{name=N})    ->
    io_lib:format("bindings[~s]", [encode_string(atom_to_binary(N))]);
encode_ir(#ir_remote_call{module=#ir_atom{value=M}, function=#ir_atom{value=F},
                           arity=A, args=Args}) ->
    io_lib:format("Erlang[~s](~s)",
        [encode_string(io_lib:format("~s:~s/~w", [M, F, A])),
         join([encode_ir(Arg)||Arg<-Args], ", ")]);
encode_ir(#ir_local_call{name=F, arity=A, args=Args}) ->
    io_lib:format("Interpreter.call(currentModule, ~s, ~w, [~s])",
        [encode_string(atom_to_binary(F)), A,
         join([encode_ir(Arg)||Arg<-Args], ", ")]);
encode_ir(#ir_case{expr=E, clauses=Cls}) ->
    io_lib:format("Interpreter.matchClauses(~s, [~s])",
        [encode_ir(E), join([encode_clause(C)||C<-Cls], ", ")]);
encode_ir(#ir_binop{op=Op, left=L, right=R}) ->
    encode_binop(Op, L, R);
%% ... etc
encode_ir(Node) ->
    error({unhandled_ir_node, Node}).

encode_pair({K, V}) ->
    io_lib:format("[~s, ~s]", [encode_ir(K), encode_ir(V)]).
```

### Operator mapping

```
Erlang op  → JS runtime call
---------    ----------------
+          → Erlang["+/2"](L, R)  or direct JS + for integers
-          → Erlang["-/2"](L, R)
*          → Erlang["*/2"](L, R)
/          → Erlang["//2"](L, R)
div        → Erlang["div/2"](L, R)
rem        → Erlang["rem/2"](L, R)
==         → Interpreter.isEqual(L, R)
=:=        → Interpreter.isStrictlyEqual(L, R)
/=         → !Interpreter.isEqual(L, R)
=/=        → !Interpreter.isStrictlyEqual(L, R)
<          → Interpreter.isLess(L, R)
>          → Interpreter.isGreater(L, R)
=<         → Interpreter.isLessOrEqual(L, R)
>=         → Interpreter.isGreaterOrEqual(L, R)
andalso    → (encodeBool(L) && encodeBool(R))
orelse     → (encodeBool(L) || encodeBool(R))
not        → !encodeBool(E)
++         → Erlang["++/2"](L, R)
--         → Erlang["--/2"](L, R)
band bor bxor bsl bsr bnot → Erlang["band/2"] etc.
```

---

## 4. Call Graph & Dead Code Elimination

### Algorithm

1. Start with the set of entry MFAs for a page: `[{PageModule, init, 2}, {PageModule, template, 0}]`
2. For each MFA, look up its IR in the PLT
3. Walk the IR, collecting all `#ir_remote_call{}` and `#ir_local_call{}` nodes
4. Local calls are resolved to `{CurrentModule, Fun, Arity}`
5. Add discovered MFAs to a work queue if not already visited
6. Repeat until the work queue is empty
7. The visited set is the bundle's MFA set

### PLT (Persistent Lookup Table)

```erlang
-module(hologram_plt).
-export([new/0, put/3, get/2, all_mfas/1, save/2, load/1]).

%% In-memory: ETS table
%% Key: {Module, Function, Arity}
%% Value: #ir_function_def{} or {external, BeamFile}

new() ->
    ets:new(hologram_plt, [named_table, public, {read_concurrency, true}]).

put(PLT, {M, F, A}, IR) ->
    ets:insert(PLT, {{M, F, A}, IR}).

get(PLT, {M, F, A}) ->
    case ets:lookup(PLT, {M, F, A}) of
        [{_, IR}] -> {ok, IR};
        []        -> not_found
    end.
```

### Extracting stdlib functions from BEAM files

```erlang
-module(hologram_beam_reader).
-export([extract_ir/1]).

extract_ir(Module) when is_atom(Module) ->
    BeamFile = code:which(Module),
    extract_ir(BeamFile);
extract_ir(BeamFile) ->
    case beam_lib:chunks(BeamFile, [abstract_code]) of
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            {ok, hologram_transformer:transform_module(Forms, #ctx{module=module_from_forms(Forms)})};
        {ok, {_, [{abstract_code, no_abstract_code}]}} ->
            {error, no_debug_info};
        {error, _, Reason} ->
            {error, Reason}
    end.
```

**Important**: Standard library BEAM files (e.g. `maps.beam`, `lists.beam`) are compiled with `+debug_info` in OTP, so `abstract_code` is available. For any module compiled without `+debug_info`, the function cannot be inlined — fall back to a hand-written JS stub or bundle the entire module.

---

## 5. Template System

### `.holo` file syntax

```html
<div class="counter">
  <p>Count: {@count}</p>
  <button hologram-click="increment">+</button>
  <button hologram-click="decrement">-</button>
  <:component module={my_other_component} initial_value={@count} />
</div>
```

Interpolation `{@name}` reads from component state. `{expr}` can be any Erlang expression that evaluates to a term renderable as a string. `<:component>` embeds a child component.

### DOM AST (Erlang representation)

```erlang
-type dom_node() ::
    {element, binary(), [attr()], [dom_node()]}
  | {text, binary()}
  | {expr, [erl_parse:abstract_expr()]}    % parsed Erlang expression
  | {component, module(), [{atom(), dom_node()}]}.  % props as dom_nodes

-type attr() :: {binary(), binary() | {expr, _}}.
```

### Parser strategy

Use a hand-written tokenizer (or a leex/yecc grammar) for the `.holo` format. The key parsing steps:

1. Tokenize HTML character-by-character, detecting `{` for expression start
2. Inside `{@name}`, extract the variable name — maps to a state lookup `#ir_map_get{map=#ir_variable{name='State'}, key=#ir_atom{value=name}}`
3. Inside `{expr}` or prop values like `initial_value={@count}`, extract the Erlang expression string and parse with:
   ```erlang
   {ok, Tokens, _} = erl_scan:string(ExprStr ++ "."),
   {ok, [Expr]}    = erl_parse:parse_exprs(Tokens)
   ```
4. `<:component module={name} prop={value} />` — extract module atom and props list

### Server-side rendering

```erlang
-module(hologram_renderer).
-export([render_page/2]).

render_page(PageModule, Params) ->
    {ComponentState, Server} = PageModule:init(Params, initial_server()),
    TemplateFile = PageModule:template(),
    DOM = hologram_template_parser:parse_file(TemplateFile),
    HTML = render_node(DOM, ComponentState),
    StateJSON = encode_state_for_hydration(ComponentState),
    {HTML, StateJSON, Server}.

render_node({element, Tag, Attrs, Children}, State) ->
    RenderedAttrs = render_attrs(Attrs, State),
    RenderedChildren = [render_node(C, State) || C <- Children],
    [<<"<">>, Tag, RenderedAttrs, <<">">>, RenderedChildren, <<"</">>, Tag, <<">">>];
render_node({text, Text}, _State) ->
    Text;
render_node({expr, ASTExpr}, State) ->
    {value, Val, _} = erl_eval:expr(ASTExpr, state_to_bindings(State)),
    term_to_iodata(Val);
render_node({component, Module, Props}, State) ->
    ResolvedProps = resolve_props(Props, State),
    {ChildState, _} = Module:init(ResolvedProps, #{}),
    ChildTemplate = Module:template(),
    ChildDOM = hologram_template_parser:parse_file(ChildTemplate),
    render_node(ChildDOM, ChildState).

state_to_bindings(State) when is_map(State) ->
    maps:fold(fun(K, V, Acc) ->
        erl_eval:add_binding(K, V, Acc)
    end, erl_eval:new_bindings(), State).
```

---

## 6. cowboy HTTP Server Setup

### Dispatch table

```erlang
-module(hologram_router).
-export([start/1]).

start(PageModules) ->
    Routes = page_routes(PageModules) ++ system_routes(),
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    cowboy:start_clear(hologram_http, [{port, 4000}], #{
        env => #{dispatch => Dispatch}
    }).

page_routes(Modules) ->
    [begin
         Attrs = Module:module_info(attributes),
         [{route, Route}] = [V || {hologram, V} <- Attrs, proplists:is_defined(route, V)],
         {proplists:get_value(route, Route), hologram_page_handler, #{module => Module}}
     end || Module <- Modules].

system_routes() ->
    [
        {"/hologram/command",  hologram_command_handler, #{}},
        {"/hologram/sse",      hologram_sse_handler,     #{}},
        {"/hologram/ws",       hologram_ws_handler,      #{}},
        {"/hologram/assets/[...]", cowboy_static, {priv_dir, hologram_erl, "js"}}
    ].
```

### Page handler

```erlang
-module(hologram_page_handler).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req, #{module := PageModule} = State) ->
    Params = parse_query_params(Req),
    {HTML, StateJSON, _Server} = hologram_renderer:render_page(PageModule, Params),
    BundleURL = hologram_assets:bundle_url(PageModule),
    FullHTML = inject_bootstrap(HTML, StateJSON, BundleURL),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/html; charset=utf-8">>},
        FullHTML, Req),
    {ok, Req2, State}.

inject_bootstrap(HTML, StateJSON, BundleURL) ->
    [HTML,
     <<"<script type='module'>">>,
     <<"import Hologram from '">>, BundleURL, <<"';\n">>,
     <<"Hologram.init(">>, StateJSON, <<");\n">>,
     <<"</script>">>].
```

### Command handler

```erlang
-module(hologram_command_handler).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    #{module   := ModuleBin,
      command  := CmdBin,
      params   := Params,
      state    := ClientState} = thoas:decode(Body),
    Module  = binary_to_existing_atom(ModuleBin),
    Command = binary_to_existing_atom(CmdBin),
    ErlState = hologram_deserializer:decode(ClientState),
    Server  = initial_server_from_state(ErlState),
    NewServer = Module:command(Command, Params, Server),
    Response = hologram_serializer:encode_command_response(NewServer),
    Req3 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        thoas:encode(Response), Req2),
    {ok, Req3, State}.
```

### SSE handler

```erlang
-module(hologram_sse_handler).
-behaviour(cowboy_loop).
-export([init/2, info/3]).

init(Req, State) ->
    ComponentId = cowboy_req:binding(id, Req),
    hologram_pubsub:subscribe(ComponentId, self()),
    Req2 = cowboy_req:stream_reply(200,
        #{<<"content-type">> => <<"text/event-stream">>,
          <<"cache-control">> => <<"no-cache">>}, Req),
    {cowboy_loop, Req2, #{component_id => ComponentId}}.

info({hologram_event, Event}, Req, State) ->
    Data = thoas:encode(hologram_serializer:encode_event(Event)),
    cowboy_req:stream_body(["data: ", Data, "\n\n"], nofin, Req),
    {ok, Req, State}.
```

---

## 7. Serialization Wire Format

The wire format must match what the Hologram JS client expects. The type-tagged JSON format:

```javascript
// Erlang term → JSON encoding
atom("ok")       → {"type": "atom", "value": "ok"}
integer(42)      → {"type": "integer", "value": 42}
float(3.14)      → {"type": "float", "value": 3.14}
bitstring("hi")  → {"type": "bitstring", "value": "aGk="}  // base64
tuple([a, b])    → {"type": "tuple", "data": [{atom}, {atom}]}
list([1, 2])     → {"type": "list", "data": [{int}, {int}], "tail": null}
map(#{a => 1})   → {"type": "map", "data": [[{atom "a"}, {int 1}]]}
pid(...)         → {"type": "pid", "value": "<0.123.0>"}
```

Erlang-side:

```erlang
-module(hologram_serializer).
-export([encode/1, encode_command_response/1]).

encode(Atom) when is_atom(Atom) ->
    #{type => atom, value => atom_to_binary(Atom)};
encode(Int) when is_integer(Int) ->
    #{type => integer, value => Int};
encode(Float) when is_float(Float) ->
    #{type => float, value => Float};
encode(Bin) when is_binary(Bin) ->
    #{type => bitstring, value => base64:encode(Bin)};
encode(Tuple) when is_tuple(Tuple) ->
    #{type => tuple, data => [encode(E) || E <- tuple_to_list(Tuple)]};
encode([]) ->
    #{type => list, data => [], tail => null};
encode(List) when is_list(List) ->
    case lists:last(List) of  % improper list check
        _ -> #{type => list, data => [encode(E) || E <- List], tail => null}
    end;
encode(Map) when is_map(Map) ->
    Pairs = [[encode(K), encode(V)] || {K, V} <- maps:to_list(Map)],
    #{type => map, data => Pairs}.
```

---

## 8. JS Runtime Adaptation Checklist

Files to keep from Hologram's `assets/js/`:

| File | Action |
|------|--------|
| `interpreter.mjs` | Keep; remove Elixir-specific IR node branches (search for `"Elixir."` prefix handling, `defstruct`, `with`, `sigil_`) |
| `type.mjs` | Keep; remove `isElixirStruct` type predicate if any |
| `bitstring.mjs` | Keep as-is |
| `vdom.mjs` | Keep as-is |
| `renderer.mjs` | Keep; adjust component registry key format |
| `hologram.mjs` | Keep; adjust bootstrap call signature |
| `serializer.mjs` | Keep as-is (type-tagged format stays the same) |
| `deserializer.mjs` | Keep as-is |
| `erlang/*.mjs` | Keep all (these implement Erlang BIFs) |
| `connection.mjs` | Keep |
| `sse.mjs` | Keep |
| `elixir/*.mjs` | **Delete** (Elixir stdlib stubs not needed) |
| `erlang/elixir_aliases.mjs` | **Delete** |
| `erlang/elixir_locals.mjs` | **Delete** |
| `erlang/elixir_utils.mjs` | **Delete** |

Module name encoding: Hologram prefixes Elixir modules as `"Elixir.MyModule"`. For Erlang, module names are plain atoms: `"counter"`, `"maps"`, `"lists"`. Update any module name encoding in `interpreter.mjs` that adds the `"Elixir."` prefix.

---

## 9. rebar3 Compiler Plugin

Implements the `rebar_compiler` behaviour introduced in rebar3 3.14.

```erlang
-module(rebar_compiler_hologram).
-behaviour(rebar_compiler).

-export([context/1, needed_files/4, dependencies/3, compile/4, clean/2]).

context(AppInfo) ->
    EbinDir  = rebar_app_info:ebin_dir(AppInfo),
    OutDir   = filename:join(rebar_app_info:priv_dir(AppInfo), "js"),
    #{src_dirs     => ["src"],
      src_ext      => ".erl",
      out_mappings => [{".mjs", OutDir}],
      dependencies_opts => #{ebin_dir => EbinDir}}.

needed_files(Graph, FoundFiles, _Mappings, AppInfo) ->
    PLT = hologram_plt:load_or_new(plt_path(AppInfo)),
    %% Find page modules by checking -behaviour attribute in BEAM
    PageModules = find_page_modules(AppInfo),
    %% A bundle is needed if any module in its call graph changed
    ChangedPages = [M || M <- PageModules,
                         bundle_is_stale(M, PLT, Graph)],
    {ChangedPages, []}.

compile(PageModule, _Mappings, Config, AppInfo) ->
    rebar_api:info("Hologram: compiling bundle for ~s", [PageModule]),
    %% 1. Build/update PLT with IR for all reachable modules
    PLT = hologram_plt:load_or_new(plt_path(AppInfo)),
    populate_plt(PLT, PageModule, AppInfo),
    %% 2. Build call graph from page entry points
    Graph = hologram_call_graph:build(PageModule, PLT),
    %% 3. Encode reachable IR to JS
    JS = hologram_encoder:encode_bundle(Graph, PLT),
    %% 4. Write bundle file with content-hash name
    Hash = crypto:hash(sha256, JS),
    BundleName = io_lib:format("~s_~s.mjs", [PageModule, hex(Hash)]),
    OutPath = filename:join(priv_js_dir(AppInfo), BundleName),
    file:write_file(OutPath, JS),
    %% 5. Update asset manifest
    hologram_manifest:put(PageModule, BundleName, manifest_path(AppInfo)),
    ok.

clean(_AppInfo, _Config) ->
    %% Remove all generated bundles and manifest
    ok.
```

### Plugin configuration in user's `rebar.config`

```erlang
{plugins, [rebar_compiler_hologram]}.

{hologram, [
    {js_runtime_dir, "deps/hologram_erl/priv/js"},
    {bundle_dir,     "priv/js/bundles"},
    {manifest,       "priv/hologram_manifest.json"}
]}.
```

---

## 10. OTP Supervision Tree

```erlang
-module(hologram_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    Manifest = hologram_manifest:load(),
    PageModules = hologram_manifest:page_modules(Manifest),
    {ok, _} = hologram_router:start(PageModules),
    Children = [
        {hologram_assets,   {hologram_assets, start_link, [Manifest]}, permanent, 5000, worker, []},
        {hologram_registry, {hologram_registry, start_link, []},       permanent, 5000, worker, []}
        %% hologram_pubsub uses pg — no explicit supervisor child needed
    ],
    supervisor:start_link({local, hologram_sup}, hologram_sup_mod, Children).
```

`hologram_registry` is a thin wrapper around `gproc` for mapping component instance IDs to PIDs.

---

## 11. Behaviour Callback Specs

```erlang
%% hologram_component.erl
-module(hologram_component).

-callback init(Props :: map(), Server :: map()) ->
    {Component :: map(), Server :: map()}.

-callback action(ActionName :: atom(), Params :: map(), Component :: map()) ->
    Component :: map().

-callback command(CommandName :: atom(), Params :: map(), Server :: map()) ->
    Server :: map().

-callback template() -> TemplateFile :: string() | {inline, dom_ast()}.

-optional_callbacks([action/3, command/3]).

%% Default implementations
-export([default_action/3, default_command/3]).

default_action(Name, _Params, _Component) ->
    error({unhandled_action, Name}).

default_command(Name, _Params, _Server) ->
    error({unhandled_command, Name}).
```

```erlang
%% hologram_page.erl
-module(hologram_page).

-callback init(Params :: map(), Server :: map()) ->
    {Component :: map(), Server :: map()}.

-callback template() -> TemplateFile :: string() | {inline, dom_ast()}.

-optional_callbacks([init/2]).
```

---

## 12. Potential Pitfalls

### Erlang string literals in component code

`"hello"` in Erlang is a charlist `[104,101,108,108,111]`. This will not serialise as a binary string to the JS client. Enforce a linter rule in the rebar3 plugin: warn on any `{string, _, _}` AST node in component or page modules. Users should write `<<"hello">>` (binary) instead.

### BIF resolution in the call graph

BIFs (built-in functions like `erlang:length/1`, `erlang:is_atom/1`) are implemented in `erlang/*.mjs`. They do not have Erlang source or BEAM abstract code. Maintain a whitelist of BIFs that have JS implementations; anything on the whitelist is not traversed for dependencies, just referenced directly.

### `apply/3` and dynamic dispatch

`apply(Module, Fun, Args)` cannot be statically resolved. When the call graph encounters `apply/3` with non-literal arguments, log a warning and fall back to bundling the entire module referenced (if the module can be determined), or require the user to annotate reachable targets. This is the same limitation Hologram has.

### Guards in pattern matching

Erlang guards can call a restricted set of BIFs (`is_atom`, `is_integer`, `length`, etc.). The JS interpreter needs to evaluate guards using the same BIF implementations. Ensure `erlang.mjs` exports all guard-safe BIFs and the interpreter calls them via the same `Erlang["bif/n"]` dispatch.

### `receive` in component code

`receive` makes sense on the server side but not in the JS-compiled client-side component logic. If a component's `action/3` contains a `receive`, the JS encoder should emit a runtime error or compile-time warning. Only server-side `command/3` implementations should use `receive` (and those run on the BEAM, not in JS).

### `erl_eval` for template expressions

`erl_eval:expr/2` is suitable for evaluating template `{expr, _}` nodes during server-side rendering. However, it is slow for hot paths. Consider pre-compiling frequently-rendered templates to anonymous functions via `erl_eval:expr` with a binding fun, or generate Erlang module code for template rendering at build time.

---

## 13. Testing Strategy

### Compiler unit tests (EUnit)

```erlang
transform_integer_test() ->
    {integer, 1, 42} = AST,
    #ir_integer{value = 42} = hologram_transformer:transform_expr(AST, #ctx{}).

encode_atom_test() ->
    IR = #ir_atom{value = ok},
    <<"Type.atom(\"ok\")">> = iolist_to_binary(hologram_encoder:encode_ir(IR)).
```

### JS runtime tests

Borrow Hologram's JS test suite structure. Use `node --experimental-vm-modules` with Jest or a similar runner.

For each IR node type, write a round-trip test:
1. Erlang source snippet → AST (via `erl_scan`/`erl_parse`)
2. AST → IR (via transformer)
3. IR → JS (via encoder)
4. Execute JS in Node.js with the runtime
5. Assert the result matches expected Erlang term encoding

### Integration tests (Common Test)

```erlang
-module(integration_SUITE).
-include_lib("common_test/include/ct.hrl").

all() -> [counter_increment, command_round_trip, sse_broadcast].

counter_increment(Config) ->
    %% Start hologram_erl with the example counter app
    {ok, _} = application:ensure_all_started(hologram_erl_example),
    %% Fetch initial page
    {ok, {{_, 200, _}, _, Body}} = httpc:request("http://localhost:4000/counter"),
    {match, _} = re:run(Body, "Count: 0"),
    %% Send an increment action via command endpoint
    Payload = thoas:encode(#{module => <<"counter">>, command => <<"increment">>, ...}),
    {ok, {{_, 200, _}, _, _}} = httpc:request(post, {"http://localhost:4000/hologram/command",
                                                       [], "application/json", Payload}, [], []).
```
