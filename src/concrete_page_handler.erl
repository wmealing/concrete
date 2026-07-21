%% cowboy handler for initial page requests.
-module(concrete_page_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, #{module := PageModule} = State) ->
    Params = parse_query_params(Req),
    {HTML, StateJSON, _Server} = concrete_renderer:render_page(PageModule, Params),
    BundleURL = concrete_assets:bundle_url(PageModule),
    FullHTML = inject_bootstrap(HTML, StateJSON, BundleURL),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/html; charset=utf-8">>},
        FullHTML, Req),
    {ok, Req2, State}.

parse_query_params(Req) ->
    QS = cowboy_req:parse_qs(Req),
    maps:from_list([{binary_to_atom(K), V} || {K, V} <- QS]).

inject_bootstrap(HTML, StateJSON, BundleURL) ->
    [HTML,
     <<"<script type='module'>">>,
     <<"import Concrete from '">>, BundleURL, <<"';\n">>,
     <<"Concrete.init(">>, StateJSON, <<");\n">>,
     <<"</script>">>].
