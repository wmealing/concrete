%% Thin wrapper over OTP pg for pub/sub channel broadcasts.
-module(concrete_pubsub).

-export([subscribe/2, unsubscribe/2, broadcast/2]).

-type channel() :: atom() | {atom(), term()}.

-spec subscribe(channel(), pid()) -> ok.
subscribe(Channel, Pid) ->
    pg:join(concrete_pubsub, Channel, Pid).

-spec unsubscribe(channel(), pid()) -> ok.
unsubscribe(Channel, Pid) ->
    pg:leave(concrete_pubsub, Channel, Pid).

-spec broadcast(channel(), term()) -> ok.
broadcast(Channel, Message) ->
    Members = pg:get_members(concrete_pubsub, Channel),
    [Pid ! {concrete_event, Message} || Pid <- Members],
    ok.
