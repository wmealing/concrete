%% Browser todo-list demo. Pure Erlang, compiled to JavaScript and run
%% entirely client-side — no server round-trips. State is persisted to
%% the browser's localStorage, so a reload keeps your todos.
%%
%% Start with: rebar3 as example shell
%% Then call:  todo_demo:build().  %% compiles this module to todo.js
%%             todo_demo:serve().  %% http://localhost:8767
%%
%% Storage format (localStorage key "concrete_todos"):
%%   "<next_id>\n<id>\t<0|1>\t<text>\n<id>\t<0|1>\t<text>\n..."
%% Hand-rolled instead of a real serializer — the point of this demo is
%% that it's plain Erlang all the way down, with no JS glue beyond the
%% one-line bootstrap in app.js.
-module(todo_app).
-export([start/0, handle_click/1, add_todo/0, render/0]).

start() ->
    dom:on_click(<<"todo-root">>, <<"data-action">>, todo_app, handle_click),
    dom:on_keydown(<<"new-todo">>, <<"Enter">>, todo_app, add_todo),
    render().

%% Delegated click dispatch: data-action values are "add", "clear",
%% "toggle:<id>", "remove:<id>".
handle_click(Action) ->
    case split_bin(Action, 58) of
        [<<"add">>] ->
            add_todo();
        [<<"clear">>] ->
            clear_completed();
        [<<"toggle">>, IdBin] ->
            toggle(binary_to_integer(IdBin));
        [<<"remove">>, IdBin] ->
            remove(binary_to_integer(IdBin));
        _ ->
            ok
    end.

add_todo() ->
    Text = dom:get_value(<<"new-todo">>),
    case byte_size(Text) > 0 of
        true ->
            {NextId, Todos} = load(),
            NewTodo = #{id => NextId, text => Text, done => false},
            save(NextId + 1, Todos ++ [NewTodo]),
            dom:set_value(<<"new-todo">>, <<"">>),
            render();
        false ->
            ok
    end.

toggle(Id) ->
    {NextId, Todos} = load(),
    NewTodos = lists:map(fun(T) ->
        case maps:get(id, T) =:= Id of
            true  -> T#{done := not maps:get(done, T)};
            false -> T
        end
    end, Todos),
    save(NextId, NewTodos),
    render().

remove(Id) ->
    {NextId, Todos} = load(),
    NewTodos = lists:filter(fun(T) -> maps:get(id, T) =/= Id end, Todos),
    save(NextId, NewTodos),
    render().

clear_completed() ->
    {NextId, Todos} = load(),
    NewTodos = lists:filter(fun(T) -> maps:get(done, T) =/= true end, Todos),
    save(NextId, NewTodos),
    render().

%% --- rendering ---

render() ->
    {_NextId, Todos} = load(),
    ItemsHtml = join_bin(lists:map(fun(T) -> item_html(T) end, Todos), <<"">>),
    Remaining = lists:foldl(fun(T, Acc) ->
        case maps:get(done, T) =:= true of
            true  -> Acc;
            false -> Acc + 1
        end
    end, 0, Todos),
    Body = case Todos of
        [] -> <<"<li class=\"empty\">Nothing to do - add one above.</li>">>;
        _  -> ItemsHtml
    end,
    dom:set_html(<<"todo-list">>, Body),
    dom:set_text(<<"todo-count">>,
        <<(integer_to_binary(Remaining))/binary, " item(s) left">>).

item_html(T) ->
    Id = maps:get(id, T),
    Done = maps:get(done, T),
    IdBin = integer_to_binary(Id),
    Text = escape_html(maps:get(text, T)),
    Checked = case Done of true -> <<" checked">>; false -> <<"">> end,
    ClassName = case Done of true -> <<"todo-item done">>; false -> <<"todo-item">> end,
    Open = <<"<li class=\"", ClassName/binary, "\">">>,
    Checkbox = <<"<input type=\"checkbox\" data-action=\"toggle:", IdBin/binary,
                 "\"", Checked/binary, ">">>,
    Label = <<"<span>", Text/binary, "</span>">>,
    RemoveBtn = <<"<button data-action=\"remove:", IdBin/binary,
                  "\">remove</button>">>,
    Part1 = <<Open/binary, Checkbox/binary>>,
    Part2 = <<Part1/binary, Label/binary>>,
    Part3 = <<Part2/binary, RemoveBtn/binary>>,
    <<Part3/binary, "</li>">>.

%% --- storage ---

load() ->
    case dom:local_storage_get(<<"concrete_todos">>) of
        undefined ->
            {1, []};
        Content ->
            [NextIdBin | Rest] = split_bin(Content, 10),
            ValidLines = lists:filter(fun(L) -> byte_size(L) > 0 end, Rest),
            Todos = lists:map(fun(L) -> parse_line(L) end, ValidLines),
            {binary_to_integer(NextIdBin), Todos}
    end.

save(NextId, Todos) ->
    Lines = lists:map(fun(T) -> line_of(T) end, Todos),
    Body = join_bin(Lines, <<"\n">>),
    Content = <<(integer_to_binary(NextId))/binary, "\n", Body/binary>>,
    dom:local_storage_set(<<"concrete_todos">>, Content).

line_of(T) ->
    IdBin = integer_to_binary(maps:get(id, T)),
    DoneBin = case maps:get(done, T) of true -> <<"1">>; false -> <<"0">> end,
    Text = maps:get(text, T),
    <<IdBin/binary, "\t", DoneBin/binary, "\t", Text/binary>>.

parse_line(Line) ->
    [IdBin, DoneBin, Text] = split_bin(Line, 9),
    Done = (DoneBin =:= <<"1">>),
    #{id => binary_to_integer(IdBin), done => Done, text => Text}.

%% --- small binary helpers (no binary:split/string:split in the demo
%% runtime, so these are plain Erlang) ---

split_bin(Bin, Sep) ->
    split_bin(Bin, Sep, <<"">>, []).

split_bin(<<>>, _Sep, Acc, Out) ->
    lists:reverse([Acc | Out]);
split_bin(<<C:8, Rest/binary>>, Sep, Acc, Out) when C =:= Sep ->
    split_bin(Rest, Sep, <<"">>, [Acc | Out]);
split_bin(<<C:8, Rest/binary>>, Sep, Acc, Out) ->
    split_bin(Rest, Sep, <<Acc/binary, C:8>>, Out).

join_bin([], _Sep) ->
    <<"">>;
join_bin([H], _Sep) ->
    H;
join_bin([H | T], Sep) ->
    <<H/binary, Sep/binary, (join_bin(T, Sep))/binary>>.

escape_html(Bin) ->
    escape_html(Bin, <<"">>).

escape_html(<<>>, Acc) ->
    Acc;
escape_html(<<C:8, Rest/binary>>, Acc) when C =:= 38 ->
    escape_html(Rest, <<Acc/binary, "&amp;">>);
escape_html(<<C:8, Rest/binary>>, Acc) when C =:= 60 ->
    escape_html(Rest, <<Acc/binary, "&lt;">>);
escape_html(<<C:8, Rest/binary>>, Acc) when C =:= 62 ->
    escape_html(Rest, <<Acc/binary, "&gt;">>);
escape_html(<<C:8, Rest/binary>>, Acc) when C =:= 34 ->
    escape_html(Rest, <<Acc/binary, "&quot;">>);
escape_html(<<C:8, Rest/binary>>, Acc) ->
    escape_html(Rest, <<Acc/binary, C:8>>).
