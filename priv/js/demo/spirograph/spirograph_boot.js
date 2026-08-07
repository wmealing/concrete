// Boot the compiled Erlang entry point. Everything else -- building the
// three.js scene, camera, and renderer, and animating the spirograph --
// happens in compiled Erlang (see spirograph_app.js), calling into the
// THREE global this page's own <script> tag loaded from a CDN.
Interpreter.callTopLevel("spirograph_app", "start", 0, []);
