# CC Turtle Brain

LLM-driven automation for ComputerCraft turtles, written in plain CC: Tweaked Lua.
A cheap LLM (via OpenRouter) plans; deterministic Lua executes.

## Environment
- Minecraft server on a managed host (gamesservers.io): no shell, file manager only.
- CC: Tweaked `computercraft-server.toml` has an `[[http.rules]]` entry for `openrouter.ai` with `timeout = 120000`.
- LLM access is API-based through OpenRouter (OpenAI-compatible endpoint). Subscription-based access was ruled out (would need an external bridge).
- Single player/user; designed for one turtle now, a fleet later.
- GPS works on the user's turtle (wireless modem + GPS hosts).

## Design: plan once, execute in Lua
- One LLM call per goal: the model sends the whole job as a plan (an ordered list of skill steps) through the single `runPlan` tool. Lua runs every step with no LLM call in between.
- The LLM is called again only when a step fails; it gets the error plus fresh state and sends a plan for the rest, or explains. `maxTurns` caps this.
- A successful plan ends the run with a Lua-written summary (no "done" round trip).
- Status (position, facing, home, fuel, inventory, adjacent chest) goes in the first user message, so the model never spends calls on status tools.
- Not free-form Lua from the LLM: plans are data, so they are validated before anything moves, cost few output tokens, can't break the world outside skill rules, and can be split across turtles and sent over rednet.
- Fleet: same flow on a computer (`fleet`). The LLM sends `runPlans`: groups of turtle ids, each with steps. Lua splits shared steps (a skill's `split`, e.g. `mineBox` slices) inside a group, sends every turtle its steps, and waits for all of them. Only then, if any failed, the LLM is called again with every turtle's outcome and fresh state. Waiting for all keeps the blocking `http.post` away from moments when rednet messages are expected.

## Files
- `install.lua`: downloads/updates all files from GitHub. Public repo uses raw URLs; private repo uses the GitHub API with a token in `/.github_token`. Add new files to its `FILES` list. It fetches itself first and, if changed, re-runs the new copy (`--updated`), so new `FILES` entries arrive in one run. Installers older than that (pre-2026-10-03) need `install` twice. Raw URLs can serve stale files for ~5 min after a push.
- `brain.lua`: single-turtle entry point (`brain <goal>`). System prompt, state line, `runPlan` wiring.
- `fleet.lua`: fleet entry point on a computer with a modem (`fleet <goal>`). Fleet system prompt, discovery, `runPlans` wiring. Ctrl+T stops the busy turtles.
- `worker.lua`: run on each fleet turtle (or from `startup.lua`). Two coroutines: one runs plans, one answers the brain (status, busy, stop).
- `llm/config.lua`: endpoint, model slug, key path, `maxTurns` (LLM calls per goal), `maxRetries`, `debugPath`.
- `llm/openrouter.lua`: HTTP client. `chat(messages, tools) -> message, usage | nil, err`. Retries on network errors, 429 and 5xx. Sends `provider.require_parameters = true` with tools. Writes the last raw response to `debugPath` (`/llm_last.json`) — first thing to read when a run misbehaves.
- `llm/agent.lua`: provider-agnostic tool-calling loop. `run(goal, tools, systemPrompt, onTool) -> text, stats | nil, err`. Calls in one turn run in order and stop at the first failure; a successful `final` tool ends the run.
- `bot/config.lua`: turtle-side settings (state file, fuel items, protected blocks, fuel margin, max plan length).
- `bot/nav.lua`: position/heading (dead reckoning saved to `/nav_state.json` after every move; GPS fix + heading calibration by stepping once at `init()`), `step`/`dig`/`goTo` that dig through obstacles except protected blocks, fuel and refuel. Another turtle in the way: waits (`turtleWaits` random ~1 s retries), never digs it.
- `bot/inv.lua`: free slots, inventory summary, unload into an adjacent inventory peripheral (keeps fuel).
- `bot/mine.lua`: `mineArea` (box relative to the turtle) and `mineBox` (box between two world corners; enters from above its nearest top corner, ends there). Walks the middle of each 3-layer group digging up/down (1 move per 3 blocks), stays inside the box, unloads at a chest next to the start or at home when full, returns to its start point on success or failure.
- `bot/skills.lua`: the skill list the planner sees, plus `state()` (the status line). Requires nav/inv/mine lazily so a computer can load it for the catalog and `split` functions.
- `bot/plan.lua`: builds the prompt catalog, the step JSON schema and arg checks from skill declarations; validates, runs and reports plans.
- `bot/net.lua`: rednet protocol (`ccbrain`) and message types; `open()` opens every modem.
- `bot/fleet.lua`: brain side: `discover`, `describe`, and the `runPlans` tool (expand groups, dispatch, wait with pings; silent for 60 s = lost; a turtle that answers with another job = restarted).
- `tests/`: fake CC world (`fakecc.lua`: turtle, events, `parallel`, rednet, virtual time) and tests (`tests.lua`) run with `python tests/run.py` (needs `pip install lupa`). The fleet is tested one side at a time (real worker vs scripted brain, real brain vs scripted turtles). Not installed on turtles.

## Conventions
- Comment blocks include a `<Claude>` tag.
- Secrets never go in the repo: `/.openrouter_key`, `/.github_token` are created by hand on each machine.
- LLM tools are injected as `{ name = { description, parameters (JSON schema), handler(args) -> table, final? } }`. Each entry point has one: `runPlan` (brain) or `runPlans` (fleet).
- Skills are declared once in `bot/skills.lua` as `{ name, doc, args = { { argName, type, default } }, run(args) -> table, split? }`. Types: `int`, `count` (>= 1), `str`, enum `a|b|c` (`dir` = 8 horizontal directions). Arg names shared between skills must have compatible types (the schema merges them). Keep `doc` short: it is sent on every call. `split(args, positions)` (optional) runs on the brain and returns args per turtle (nil = that turtle skips the step); it must not touch the turtle API.
- Results are compact tables with an `ok` field; errors are returned (`{ ok = false, error = ... }`), never thrown out of the loop. Exception: `"Terminated"` (Ctrl+T) is always re-raised past every `pcall`.
- `bot/nav` functions return `ok, err` and never throw; skills turn failures into results.
- Use `textutils.json_null` where the API needs a real JSON `null`.
- The LLM decides *what* to do; pathfinding, refueling, inventory and coordinates stay in Lua.
- Lua must run on CC's Cobalt VM (Lua 5.2): no `//`, no bitwise operators, no `goto`.
- Turtles must be labeled (`label set ...`) or they lose files when broken.

## Known limitations
- `http.post` is blocking and swallows other events (e.g. rednet) while waiting. Harmless today because the fleet brain only calls the LLM when every turtle is idle; move to async `http.request` + `parallel` before the brain does anything while turtles work (dashboards, replanning one turtle while others run).
- Fleet replans only once every turtle has finished: a turtle that fails early idles until the slowest one is done.
- Two turtles meeting head-on both wait ~20 s, then fail (replan). No traffic lanes or reservation.
- Fleet turtles must stay in loaded chunks and in modem range (wireless ~64 blocks; ender modems have no limit). Otherwise they freeze and the brain reports them lost after 60 s.
- A stop abandons the running command; the worker resyncs with `nav.init()`, which needs GPS to be exact.
- Rednet is not authenticated: anyone on the server could send plans to the workers.
- Plans are open-loop: no step can feed an observation back to the model except by failing.
- `goTo` walks axis by axis and digs through whatever is in the way (protected blocks excepted); no pathfinding around obstacles.
- `init()` steps the turtle 1 block and back on every run when GPS is available (heading calibration, 2 fuel).
- Without GPS, coordinates are relative to the first run and "north" is the turtle's first facing.
- The test world is a simplified CC. In-game: single-turtle `brain` + `mineArea` confirmed working (2026-10-03); `mineBox`, `worker` and `fleet` not yet.
- Model choice: `deepseek/deepseek-chat` (DeepSeek V3, 2 providers) ran without error but came back empty with no tool call (2026-10-03). Switched to `deepseek/deepseek-v4-flash` (15 providers, all with tool support). Check a slug's providers at `https://openrouter.ai/api/v1/models/<slug>/endpoints` before switching.

## Next steps
1. In-game test of `worker` + `fleet` with 2 turtles (shared `mineBox`, then `goHome`).
2. More skills (place/build, farm, item transfer), each with a `split` when it can be shared.
3. Async HTTP in the brain, then per-turtle replanning while others keep working, monitor dashboards.
4. Later: storage management via wired modems, blueprint-based building.
