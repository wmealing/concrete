// Boot the compiled Erlang entry point. Everything else — the canvas
// drawing and scheduling the next frame — happens in compiled Erlang
// (see canvas_app.js).
Interpreter.callTopLevel("canvas_app", "start", 0, []);
