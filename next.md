Planning agent finished with a full file-by-file design (plan mode auto-expired mid-flight since the agent ran ~75 minutes, so I'm not going through the formal ExitPlanMode approval — but this is enough scope that I want your go-ahead before touching core files). Here's the plan:

Part A — fix the broken OTP skeleton (prerequisite, ~176 tests must stay green)
- plugin/rebar_compiler_concrete.erl: add missing concrete_ir.hrl include (it doesn't even compile today), implement real staleness checking in bundle_is_stale/2 (currently hardcoded true)
- src/concrete.erl: add init/1 to register the compiler plugin via rebar_state:append_compilers/2
- rebar.config: add plugin/ to extra_src_dirs so the plugin actually builds
- src/concrete.app.src: add the missing {mod, {concrete_app, []}} tuple (currently dead code — application:start(concrete) never calls it)
- src/concrete_sup.erl (new): real supervisor — pg, concrete_assets, concrete_registry as children
- src/concrete_app.erl: fix start/2 to call concrete_sup:start_link/1 correctly (currently references a nonexistent concrete_sup_mod and would crash)
- src/concrete_router.erl: make the cowboy port configurable via app env instead of hardcoded 4000
- src/concrete_registry.erl: small robustness fix (don't crash on unexpected messages)

Part B — rebar3 new concrete_app name=my_app template
- New priv/templates/ files (index .template + mustache fragments) generating: a page module, a counter component (matching CLAUDE.md's canonical example), .slab templates, rebar.config with the compiler plugin registered, .app.src/_app/_sup for the generated project, README
- No separate CLI provider — bare rebar3 new once concrete is registered as a plugin (one-line install instruction)
- One flagged risk: declaring concrete in both {deps,...} and {project_plugins,...} in the generated rebar.config — needs to be verified live, with a documented fallback

Verification: rebar3 ct (176 tests), then a real smoke test — generate a project, rebar3 compile (confirm a JS bundle + manifest appear), rebar3 shell, curl the page, click the counter in a browser and confirm the DOM updates via the compiled action.
