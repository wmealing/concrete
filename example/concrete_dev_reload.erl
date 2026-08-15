%% Dev-only live reload for the example/ demos (see plan: live reload was
%% flagged as missing compared to Hologram). Polls example/*.erl and
%% priv/templates/*.slab for mtime changes; a .slab change just needs a
%% browser refresh (concrete_template_parser:parse_file/1 already re-reads
%% templates from disk on every request), while a .erl change is recompiled
%% via `rebar3 as example compile` and the changed modules reloaded in this
%% VM before the refresh signal goes out.
%%
%% Self-contained: runs its own tiny cowboy listener (fixed dev port,
%% independent of every demo's own listener) rather than touching any
%% demo's cowboy_router dispatch table. Every demo just needs to call
%% ensure_started/0 once (same idempotent pattern as
%% ws_demo:ensure_counter_started/0) and add one <script> tag pointing at
%% this listener's /dev-reload.js.
%%
%% Scope: example/*.erl and priv/templates/*.slab only, not src/ -- see
%% the plan for why. A handful of demos (concrete_demo, canvas_demo,
%% gen_server_demo, process_viz_demo, spirograph_demo, snake_demo) write
%% their compiled JS to a static file once at serve/1 startup rather than
%% regenerating it per request; for those, a .erl edit still recompiles
%% and reloads the Erlang module, but the stale on-disk .js won't refresh
%% without restarting that demo.
-module(concrete_dev_reload).
-behaviour(gen_server).
-behaviour(cowboy_handler).

-export([ensure_started/0]).
-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([init/2]). %% cowboy_handler: serves /dev-reload.js

-define(PORT, 8799).
-define(POLL_MS, 500).
-define(DEBOUNCE_MS, 300).
-define(CHANNEL, <<"dev">>).

-record(state, {mtimes :: #{file:filename() => integer()}, pending = false :: boolean()}).

%% --- Public API ---

-spec ensure_started() -> ok.
ensure_started() ->
    case whereis(?MODULE) of
        undefined ->
            {ok, _} = start_link(),
            ok;
        _Pid ->
            ok
    end.

start_link() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% --- cowboy_handler: GET /dev-reload.js ---

init(Req, State) ->
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/javascript; charset=utf-8">>},
        dev_reload_js(), Req),
    {ok, Req2, State}.

%% --- gen_server ---

init([]) ->
    ok = start_listener(),
    Mtimes = scan_mtimes(),
    erlang:send_after(?POLL_MS, self(), poll),
    {ok, #state{mtimes = Mtimes}}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll, State) ->
    erlang:send_after(?POLL_MS, self(), poll),
    Current = scan_mtimes(),
    Changed = [F || {F, Mtime} <- maps:to_list(Current),
                     maps:get(F, State#state.mtimes, undefined) =/= Mtime],
    case Changed of
        [] ->
            {noreply, State#state{mtimes = Current}};
        _ ->
            case lists:any(fun is_slab/1, Changed) andalso not lists:any(fun is_erl/1, Changed) of
                true ->
                    %% Template-only change: already re-read from disk
                    %% per request, no compile needed.
                    concrete_pubsub:broadcast(?CHANNEL, reload),
                    {noreply, State#state{mtimes = Current}};
                false ->
                    erlang:send_after(?DEBOUNCE_MS, self(), compile),
                    {noreply, State#state{mtimes = Current, pending = true}}
            end
    end;
handle_info(compile, #state{pending = true} = State) ->
    do_compile_and_reload(),
    {noreply, State#state{pending = false}};
handle_info(compile, State) ->
    %% A later poll already superseded this debounce -- skip, the
    %% newer one already scheduled its own `compile`.
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%% --- Watching ---

scan_mtimes() ->
    Files = filelib:wildcard("example/*.erl") ++ filelib:wildcard("priv/templates/*.slab"),
    maps:from_list([{F, mtime(F)} || F <- Files]).

mtime(F) ->
    case filelib:last_modified(F) of
        0 -> 0;
        Datetime -> calendar:datetime_to_gregorian_seconds(Datetime)
    end.

is_erl(F)  -> filename:extension(F) =:= ".erl".
is_slab(F) -> filename:extension(F) =:= ".slab".

%% --- Compile + reload ---

do_compile_and_reload() ->
    {Output, ExitCode} = run_cmd("rebar3 as example compile"),
    case ExitCode of
        0 ->
            reload_beams(),
            concrete_pubsub:broadcast(?CHANNEL, reload);
        _ ->
            concrete_pubsub:broadcast(?CHANNEL,
                {compile_error, unicode:characters_to_binary(Output)})
    end.

%% os:cmd/1 alone doesn't expose the exit status -- appending a marker
%% echo and splitting it back off is the standard dependency-free way
%% to recover it.
run_cmd(Cmd) ->
    Marker = "___CONCRETE_DEV_RELOAD_EXIT___",
    Raw = os:cmd(Cmd ++ " ; echo " ++ Marker ++ "$?"),
    case string:split(Raw, Marker, trailing) of
        [Before, After] ->
            {Before, list_to_integer(string:trim(After))};
        _ ->
            {Raw, 1}
    end.

%% Unconditionally purge+reload every watched module rather than
%% tracking which .beam actually changed -- harmless for the ones that
%% didn't, and far simpler than cross-referencing source mtimes against
%% build output paths.
reload_beams() ->
    [begin
         Mod = list_to_atom(filename:basename(F, ".erl")),
         code:purge(Mod),
         code:load_file(Mod)
     end || F <- filelib:wildcard("example/*.erl")],
    ok.

%% --- Listener ---

start_listener() ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/reload/:id",    concrete_sse_handler, #{}},
            {"/dev-reload.js", ?MODULE,               #{}}
        ]}
    ]),
    case cowboy:start_clear(?MODULE, [{port, ?PORT}], #{env => #{dispatch => Dispatch}}) of
        {ok, _}                       -> ok;
        {error, {already_started, _}} -> ok;
        {error, eaddrinuse}           -> ok
    end.

%% ?PORT is baked in as a literal below too -- keep the two in sync.
dev_reload_js() ->
    <<
      """
      (function () {
        var src = new EventSource("http://localhost:8799/reload/dev");
        src.onmessage = function (ev) {
          var msg = JSON.parse(ev.data);
          if (msg.type === "atom" && msg.value === "reload") {
            location.reload();
            return;
          }
          if (msg.type === "tuple" && msg.data[0].type === "atom" &&
              msg.data[0].value === "compile_error") {
            var text = atob(msg.data[1].value);
            var pre = document.getElementById("concrete-dev-reload-error");
            if (!pre) {
              pre = document.createElement("pre");
              pre.id = "concrete-dev-reload-error";
              pre.style.cssText =
                "position:fixed;top:0;left:0;right:0;max-height:50vh;" +
                "overflow:auto;margin:0;padding:1em;z-index:999999;" +
                "background:#300;color:#fbb;font-size:0.85em;white-space:pre-wrap;";
              document.body.appendChild(pre);
            }
            pre.textContent = text;
          }
        };
      })();
      """
    >>.
