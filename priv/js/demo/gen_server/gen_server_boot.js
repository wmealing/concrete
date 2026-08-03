// Boot the compiled Erlang entry point. Everything else -- spawning the
// gen_server process, wiring up click handlers, calling/casting into
// it -- happens in compiled Erlang (see counter_ui.erl).
Interpreter.callTopLevel("counter_ui", "start", 0, []);
