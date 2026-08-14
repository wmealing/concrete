%% Test fixture for client_SUITE: a page whose mount/1 runs a real
%% dom:* BIF against the Component it receives, proving Client.mount()
%% invokes it automatically, exactly once, with the same wire-decoded
%% shape action/3 already gets -- and only after the first render has
%% put the page's own markup in the DOM.
-module(fixture_mount_page).
-export([init/2, template/0, mount/1]).

init(Props, Server) ->
    State = #{greeting => maps:get(greeting, Props, <<"hi">>)},
    {#{state => State}, Server}.

template() ->
    {inline, concrete_template_parser:parse_string("<p>hello</p>")}.

mount(#{state := #{greeting := Greeting}}) ->
    dom:set_text(<<"ignored-id">>, Greeting).
