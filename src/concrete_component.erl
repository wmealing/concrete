-module(concrete_component).

-callback init(Props :: map(), Server :: map()) ->
    {Component :: map(), Server :: map()}.

-callback action(ActionName :: atom(), Params :: map(), Component :: map()) ->
    Component :: map().

-callback command(CommandName :: atom(), Params :: map(), Server :: map()) ->
    Server :: map().

-callback template() -> TemplateFile :: string() | {inline, term()}.

-optional_callbacks([action/3, command/3]).

-export([default_action/3, default_command/3]).

default_action(Name, _Params, _Component) ->
    error({unhandled_action, Name}).

default_command(Name, _Params, _Server) ->
    error({unhandled_command, Name}).
