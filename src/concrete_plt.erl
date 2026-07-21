%% ETS-backed persistent lookup table for caching IR by MFA.
-module(concrete_plt).

-export([new/0, put/3, get/2, all_mfas/1, save/2, load/1, load_or_new/1]).

-type plt() :: ets:table().
-type mfa_key() :: {module(), atom(), arity()}.

-spec new() -> plt().
new() ->
    ets:new(concrete_plt, [set, public, {read_concurrency, true}]).

-spec put(plt(), mfa_key(), term()) -> true.
put(PLT, MFA, IR) ->
    ets:insert(PLT, {MFA, IR}).

-spec get(plt(), mfa_key()) -> {ok, term()} | not_found.
get(PLT, MFA) ->
    case ets:lookup(PLT, MFA) of
        [{_, IR}] -> {ok, IR};
        []        -> not_found
    end.

-spec all_mfas(plt()) -> [mfa_key()].
all_mfas(PLT) ->
    [MFA || {MFA, _} <- ets:tab2list(PLT)].

-spec save(plt(), file:filename()) -> ok | {error, term()}.
save(PLT, Path) ->
    Entries = ets:tab2list(PLT),
    file:write_file(Path, term_to_binary(Entries)).

-spec load(file:filename()) -> {ok, plt()} | {error, term()}.
load(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Entries = binary_to_term(Bin),
            PLT = new(),
            [ets:insert(PLT, E) || E <- Entries],
            {ok, PLT};
        {error, Reason} ->
            {error, Reason}
    end.

-spec load_or_new(file:filename()) -> plt().
load_or_new(Path) ->
    case load(Path) of
        {ok, PLT} -> PLT;
        {error, _} -> new()
    end.
