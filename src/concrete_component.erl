-module(concrete_component).

-callback init(Props :: map(), Server :: map()) ->
    {Component :: map(), Server :: map()}.

-callback action(ActionName :: atom(), Params :: map(), Component :: map()) ->
    Component :: map().

-callback command(CommandName :: atom(), Params :: map(), Server :: map()) ->
    Server :: map().

-callback template() -> TemplateFile :: string() | {inline, term()}.

%% Mirrors concrete_page's mount/1 (Props, Component -- same shape as
%% action/3's (ActionName, Params, Component), not a new convention).
%% Called once client-side, the first time this <:component> call
%% site's identity appears in a render pass (see client.js's
%% ComponentInstances / resolveComponentDom / reconcileComponentInstances).
-callback mount(Props :: map(), Component :: map()) -> ok.

-optional_callbacks([action/3, command/3, mount/2]).

-export([default_action/3, default_command/3]).

default_action(Name, _Params, _Component) ->
    error({unhandled_action, Name}).

default_command(Name, _Params, _Server) ->
    error({unhandled_command, Name}).
