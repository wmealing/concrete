%% cowboy handler for initial page requests.
-module(concrete_page_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, #{module := PageModule} = State) ->
    Params = parse_query_params(Req),
    {HTML, StateJSON, _Server} = concrete_renderer:render_page(PageModule, Params),
    BundleURL = concrete_assets:bundle_url(PageModule),
    MountHTML = inject_bootstrap(HTML, StateJSON, BundleURL, PageModule),
    FullHTML = concrete_renderer:wrap_in_layout(PageModule, MountHTML),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/html; charset=utf-8">>},
        FullHTML, Req),
    {ok, Req2, State}.

parse_query_params(Req) ->
    QS = cowboy_req:parse_qs(Req),
    maps:from_list([{binary_to_atom(K), V} || {K, V} <- QS]).

%% The JS runtime (priv/js/demo/runtime.js + client.js) is classic
%% global-scope script, not ES modules -- there's no "Concrete" default
%% export to import. Load order matters: runtime.js defines
%% Type/Interpreter/Erlang, client.js defines Client (hydration +
%% action dispatch) on top of them, the compiled bundle registers the
%% page module's functions with Interpreter, then Client.init/3 hydrates
%% and renders. Mirrors template_demo:page_shell/2, the known-working
%% reference implementation of this same boot sequence.
inject_bootstrap(HTML, StateJSON, BundleURL, PageModule) ->
    [<<"<div id=\"concrete-root\">">>, HTML, <<"</div>">>,
     <<"<script src=\"/concrete/assets/demo/runtime.js\"></script>">>,
     <<"<script src=\"/concrete/assets/demo/client.js\"></script>">>,
     <<"<script src=\"">>, BundleURL, <<"\"></script>">>,
     <<"<script>Client.init(\"">>, atom_to_binary(PageModule), <<"\", \"concrete-root\", ">>,
     StateJSON, <<");</script>">>].
