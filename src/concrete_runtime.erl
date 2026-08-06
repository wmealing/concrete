%% Dispatches actions and commands to the appropriate module callbacks.
-module(concrete_runtime).

-export([dispatch_action/4, dispatch_command/4]).

-spec dispatch_action(module(), atom(), map(), map()) -> map().
dispatch_action(Module, ActionName, Params, Component) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, action, 3) of
        true  -> Module:action(ActionName, Params, Component);
        false -> concrete_component:default_action(ActionName, Params, Component)
    end.

-spec dispatch_command(module(), atom(), map(), map()) -> map().
dispatch_command(Module, CommandName, Params, Server) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, command, 3) of
        true  -> Module:command(CommandName, Params, Server);
        false -> concrete_component:default_command(CommandName, Params, Server)
    end.
