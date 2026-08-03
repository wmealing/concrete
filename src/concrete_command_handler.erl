%% cowboy handler for command POST requests.
-module(concrete_command_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    {ok, #{<<"module">>  := ModuleBin,
           <<"command">> := CommandBin,
           <<"params">>  := Params,
           <<"state">>   := ClientState}} = thoas:decode(Body),
    Module      = binary_to_existing_atom(ModuleBin),
    Command     = binary_to_existing_atom(CommandBin),
    ErlState    = concrete_deserializer:decode(ClientState),
    Server      = ErlState,
    NewServer   = Module:command(Command, Params, Server),
    Response    = concrete_serializer:encode_command_response(NewServer),
    Req3 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        thoas:encode(Response), Req2),
    {ok, Req3, State}.
