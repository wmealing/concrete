// Boot the compiled Erlang entry point. Everything else -- storage,
// rendering, click/keydown dispatch -- happens in compiled Erlang
// (see todo_app.erl / the generated todo.js).
Interpreter.call("todo_app", "start", 0, []);
