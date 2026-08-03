// Boot the compiled Erlang entry point. Everything else — the DOM
// writes, the increment, and scheduling the next tick — happens in
// compiled Erlang (see counter.js).
Interpreter.callTopLevel("counter", "start", 0, []);
