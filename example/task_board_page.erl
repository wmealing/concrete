%% Page for the task_board browser demo (see task_board_demo.erl) --
%% the first example built on the actual concrete_page/concrete_component
%% framework (not raw dom:* BIFs, like todo_app.erl) to render a
%% dynamic, keyed list of stateful child components via <:for>. Adding
%% a task appends a new keyed <:component>; completing the oldest one
%% removes its identity entirely -- the same add/remove-from-a-list
%% shape component-mount-plan.md's testing section covers, just visible
%% in a browser instead of a Node harness.
-module(task_board_page).
-behaviour(concrete_page).
-export([init/2, action/3, template/0]).

init(_Params, Server) ->
    Tasks = [#{id => <<"1">>, label => <<"Write the plan">>},
             #{id => <<"2">>, label => <<"Wire up mount/2">>},
             #{id => <<"3">>, label => <<"Ship it">>}],
    {#{state => #{tasks => Tasks, next_id => 4}}, Server}.

action(add_task, _Params, #{state := #{tasks := Tasks, next_id := N} = S} = C) ->
    NewTask = #{id => integer_to_binary(N), label => <<"Task ", (integer_to_binary(N))/binary>>},
    C#{state => S#{tasks => Tasks ++ [NewTask], next_id => N + 1}};
action(complete_task, _Params, #{state := #{tasks := Tasks} = S} = C) ->
    Remaining = case Tasks of [] -> []; [_ | Rest] -> Rest end,
    C#{state => S#{tasks => Remaining}}.

template() ->
    {inline, concrete_template_parser:parse_string(
        "<div class=\"board\">"
        "<h2>Tasks</h2>"
        "<ul>"
        "<:for item=\"T\" in={@tasks}>"
        "<:component module={task_item} key={maps:get(id, T)} "
        "id={maps:get(id, T)} label={maps:get(label, T)} />"
        "</:for>"
        "</ul>"
        "<button concrete-click=\"add_task\">Add task</button>"
        "<button concrete-click=\"complete_task\">Complete oldest</button>"
        "</div>")}.
