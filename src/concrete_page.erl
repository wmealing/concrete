-module(concrete_page).

-callback init(Params :: map(), Server :: map()) ->
    {Component :: map(), Server :: map()}.

-callback template() -> TemplateFile :: string() | {inline, term()}.

%% Runs exactly once, client-side only, after this page's markup is in
%% the real DOM -- never called during the server-side render that
%% produces the first HTML (see Client.mount() in client.js), and never
%% during render/1 itself. Component is the same wire-decoded shape
%% action/3's third argument already is. Return value is unused; this
%% exists purely for the side effects (dom:*/sse:* calls) that today
%% have nowhere else safe to run once after mount.
-callback mount(Component :: map()) -> ok.

-optional_callbacks([init/2, mount/1]).
