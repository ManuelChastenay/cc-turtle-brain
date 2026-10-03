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
- Not free-form Lua from the LLM: plans are data, so they are validated before anything moves, cost few output tokens, can't break the world outside skill rules, and can later be split across turtles or sent over rednet.

## Files
- `install.lua`: downloads/updates all files from GitHub. Public repo uses raw URLs; private repo uses the GitHub API with a token in `/.github_token`. Add new files to its `FILES` list.
- `brain.lua`: single-turtle entry point (`brain <goal>`). System prompt, state line, `runPlan` wiring.
- `llm/config.lua`: endpoint, model slug, key path, `maxTurns` (LLM calls per goal), `maxRetries`, `debugPath`.
- `llm/openrouter.lua`: HTTP client. `chat(messages, tools) -> message, usage | nil, err`. Retries on network errors, 429 and 5xx. Sends `provider.require_parameters = true` with tools. Writes the last raw response to `debugPath` (`/llm_last.json`) — first thing to read when a run misbehaves.
- `llm/agent.lua`: provider-agnostic tool-calling loop. `run(goal, tools, systemPrompt, onTool) -> text, stats | nil, err`. Calls in one turn run in order and stop at the first failure; a successful `final` tool ends the run.
- `bot/config.lua`: turtle-side settings (state file, fuel items, protected blocks, fuel margin, max plan length).
- `bot/nav.lua`: position/heading (dead reckoning saved to `/nav_state.json` after every move; GPS fix + heading calibration by stepping once at `init()`), `step`/`dig`/`goTo` that dig through obstacles except protected blocks, fuel and refuel.
- `bot/inv.lua`: free slots, inventory summary, unload into an adjacent inventory peripheral (keeps fuel).
- `bot/mine.lua`: `mineArea`. Walks the middle of each 3-layer group digging up/down (1 move per 3 blocks), stays inside the box, unloads at a chest next to the start or at home when full, returns to start on success or failure.
- `bot/skills.lua`: the skill list the planner sees, plus `state()` (the status line).
- `bot/plan.lua`: builds the prompt catalog, the `runPlan` JSON schema and arg checks from skill declarations; validates and runs plans.
- `tests/`: fake CC world (`fakecc.lua`) and tests (`tests.lua`) run with `python tests/run.py` (needs `pip install lupa`). Not installed on turtles.

## Conventions
- Comment blocks include a `<Claude>` tag.
- Secrets never go in the repo: `/.openrouter_key`, `/.github_token` are created by hand on each machine.
- LLM tools are injected as `{ name = { description, parameters (JSON schema), handler(args) -> table, final? } }`. Today there is one: `runPlan`.
- Skills are declared once in `bot/skills.lua` as `{ name, doc, args = { { argName, type, default } }, run(args) -> table }`. Types: `int`, `count` (>= 1), `str`, enum `a|b|c` (`dir` = 8 horizontal directions). Arg names shared between skills must have compatible types (the schema merges them). Keep `doc` short: it is sent on every call.
- Results are compact tables with an `ok` field; errors are returned (`{ ok = false, error = ... }`), never thrown out of the loop. Exception: `"Terminated"` (Ctrl+T) is always re-raised past every `pcall`.
- `bot/nav` functions return `ok, err` and never throw; skills turn failures into results.
- Use `textutils.json_null` where the API needs a real JSON `null`.
- The LLM decides *what* to do; pathfinding, refueling, inventory and coordinates stay in Lua.
- Lua must run on CC's Cobalt VM (Lua 5.2): no `//`, no bitwise operators, no `goto`.
- Turtles must be labeled (`label set ...`) or they lose files when broken.

## Known limitations
- `http.post` is blocking and swallows other events (e.g. rednet) while waiting. Move to async `http.request` + `parallel` before fleet work.
- Plans are open-loop: no step can feed an observation back to the model except by failing.
- `goTo` walks axis by axis and digs through whatever is in the way (protected blocks excepted); no pathfinding around obstacles.
- `init()` steps the turtle 1 block and back on every run when GPS is available (heading calibration, 2 fuel).
- Without GPS, coordinates are relative to the first run and "north" is the turtle's first facing.
- The test world is a simplified CC; untested in-game as of 2026-10-03.
- Model choice: `deepseek/deepseek-chat` (DeepSeek V3, 2 providers) ran without error but came back empty with no tool call (2026-10-03). Switched to `deepseek/deepseek-v4-flash` (15 providers, all with tool support). Check a slug's providers at `https://openrouter.ai/api/v1/models/<slug>/endpoints` before switching.

## Next steps
1. In-game test of `mineArea` and the plan flow; then more skills (place/build, farm, item transfer).
2. Fleet: a turtle daemon that runs `plan.run` on plans received over rednet and reports results; the brain computer builds one prompt with every turtle's state and gets per-turtle plans (add a `turtle` field to steps), splitting big jobs (e.g. one `mineArea` strip per turtle).
3. Later: storage management via wired modems, monitor dashboards, blueprint-based building.
