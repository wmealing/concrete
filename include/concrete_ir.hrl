%% IR node record definitions for the Concrete compiler pipeline.
%% Every record's first field is implicitly the record name atom,
%% allowing dispatch via element(1, Node).

%% Primitive types
-record(ir_atom,        {value :: atom()}).
-record(ir_integer,     {value :: integer()}).
-record(ir_float,       {value :: float()}).
-record(ir_string,      {value :: binary()}).
-record(ir_bitstring,   {segments :: list()}).
-record(ir_bs_segment,  {value, size, type, unit, signedness, endianness}).
-record(ir_pid,         {}).
-record(ir_nil,         {}).

%% Compound types
-record(ir_tuple,       {elements :: list()}).
-record(ir_list,        {elements :: list(), tail}).
-record(ir_map,         {pairs :: list()}).
-record(ir_map_update,  {map, pairs :: list()}).

%% Variables and matching
-record(ir_variable,    {name :: atom()}).
-record(ir_match,       {pattern, expr}).
-record(ir_wildcard,    {}).

%% Function definitions
-record(ir_module,      {name :: atom(), definitions :: list()}).
-record(ir_function_def,{name :: atom(), arity :: non_neg_integer(), clauses :: list()}).
-record(ir_clause,      {patterns :: list(), guards :: list(), body :: list(),
                         %% Erlang source text for each parameter pattern and
                         %% each guard leaf, rendered via erl_pp at transform
                         %% time -- only populated for top-level named
                         %% function clauses (see concrete_transformer), used
                         %% by concrete_encoder to build function_clause
                         %% "attempted clauses" diagnostics. guard_srcs
                         %% mirrors guards' [[G1,G2],[G3]] OR-of-AND shape.
                         param_srcs = [] :: [binary()],
                         guard_srcs = [] :: [[binary()]]}).

%% Function calls
-record(ir_local_call,  {name :: atom(), arity :: non_neg_integer(), args :: list()}).
-record(ir_remote_call, {module, function, arity :: non_neg_integer(), args :: list()}).
%% Dynamic dispatch: Module:Function(Args) where module and/or function
%% are runtime expressions, not literal atoms (e.g. gen_server-style
%% callback dispatch). See concrete_transformer/concrete_encoder.
-record(ir_dynamic_call,{module, function, arity :: non_neg_integer(), args :: list()}).
-record(ir_anon_call,   {function, args :: list()}).
-record(ir_anon_fun,    {clauses :: list(), arity :: non_neg_integer()}).
-record(ir_fun_ref,     {module, function :: atom(), arity :: non_neg_integer()}).

%% Control flow
-record(ir_block,       {exprs :: list()}).
-record(ir_case,        {expr, clauses :: list()}).
-record(ir_if,          {clauses :: list()}).
-record(ir_receive,     {clauses :: list(), after_expr, after_body}).
-record(ir_try,         {body :: list(), of_clauses :: list(),
                         catch_clauses :: list(), after_body :: list()}).
-record(ir_catch_clause,{class, pattern, guards :: list(), body :: list()}).
-record(ir_throw,       {expr}).

%% Comprehensions
-record(ir_lc,          {template, qualifiers :: list()}).
-record(ir_bc,          {template, qualifiers :: list()}).
-record(ir_lc_gen,      {pattern, expr}).
-record(ir_bc_gen,      {pattern, expr}).
-record(ir_lc_filter,   {expr}).

%% Operators and cons
-record(ir_binop,       {op :: atom(), left, right}).
-record(ir_unop,        {op :: atom(), operand}).
-record(ir_cons,        {head, tail}).

-type ir() ::
    #ir_atom{} | #ir_integer{} | #ir_float{} | #ir_string{} | #ir_bitstring{} |
    #ir_nil{} | #ir_tuple{} | #ir_list{} | #ir_map{} | #ir_map_update{} |
    #ir_variable{} | #ir_match{} | #ir_wildcard{} |
    #ir_module{} | #ir_function_def{} | #ir_clause{} |
    #ir_local_call{} | #ir_remote_call{} | #ir_dynamic_call{} | #ir_anon_call{} |
    #ir_anon_fun{} | #ir_fun_ref{} |
    #ir_block{} | #ir_case{} | #ir_if{} | #ir_receive{} | #ir_try{} |
    #ir_lc{} | #ir_bc{} |
    #ir_binop{} | #ir_unop{} | #ir_cons{}.
