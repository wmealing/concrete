%% Child component for the task_board demo (see task_board_page.erl) --
%% one <:component>, embedded once per element of a runtime list via
%% <:for>, exercising persistent per-instance state and mount/2 (see
%% component-mount-plan.md): each task keeps its own live Component map
%% across every re-render of the page around it, and mount/2 fires
%% exactly once, the moment a given task's identity (its `key`, since
%% every iteration of the loop shares one compile-time path index)
%% first appears.
-module(task_item).
-behaviour(concrete_component).
-export([init/2, mount/2, template/0]).

init(Props, Server) ->
    State = #{id => maps:get(id, Props), label => maps:get(label, Props)},
    {#{state => State}, Server}.

%% Proves mount/2 actually ran, client-side, exactly once per task --
%% the only way to see this is in the running browser demo (open it,
%% add a task, watch "mounted" appear next to it, then add another and
%% notice the first one's flag doesn't get touched again).
mount(_Props, #{state := #{id := Id}}) ->
    dom:set_text(<<"mount-flag-", Id/binary>>, <<"mounted">>).

template() ->
    {inline, concrete_template_parser:parse_string(
        """
        <li class="task"><span class="task-label">{@label}</span><span id={<<"mount-flag-", (@id)/binary>>} class="mount-flag"></span></li>
        """)}.
