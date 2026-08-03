// Boot the compiled Erlang entry point. Spawning the ring, wiring up
// click handlers, and driving the token/poll round trips all happen in
// compiled Erlang (see process_viz_app.erl).
Interpreter.callTopLevel("process_viz_app", "start", 0, []);
