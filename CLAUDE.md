# CC Turtle Brain

LLM-driven automation for ComputerCraft turtles, written in plain CC: Tweaked Lua.
A cheap LLM (via OpenRouter) plans; deterministic Lua executes.

## Environment
- Minecraft server on a managed host (gamesservers.io): no shell, file manager only.
- CC: Tweaked `computercraft-server.toml` has an `[[http.rules]]` entry for `openrouter.ai` with `timeout = 120000`.
- LLM access is API-based through OpenRouter (OpenAI-compatible endpoint). Subscription-based access was ruled out (would need an external bridge).
- Single player/user; designed for one turtle now, a fleet later.

## Files
- `install.lua`: downloads/updates all files from GitHub. Public repo uses raw URLs; private repo uses the GitHub API with a token in `/.github_token`. Add new files to its `FILES` list.
- `brain.lua`: single-turtle demo. Defines placeholder tools (`getStatus`, `move`, `inspect`) and the system prompt.
- `llm/config.lua`: endpoint, model slug, key path, `maxTurns`, `maxRetries`, `debugPath`.
- `llm/openrouter.lua`: HTTP client. `chat(messages, tools) -> message, usage | nil, err`. Retries on network errors, 429 and 5xx. Sends `provider.require_parameters = true` with tools. Writes the last raw response to `debugPath` (`/llm_last.json`) — first thing to read when a run misbehaves.
- `llm/agent.lua`: provider-agnostic tool-calling loop. `run(goal, tools, systemPrompt, onTool) -> text, stats | nil, err`.

## Conventions
- Comment blocks include a `<Claude>` tag.
- Secrets never go in the repo: `/.openrouter_key`, `/.github_token` are created by hand on each machine.
- Tools are injected as `{ name = { description, parameters (JSON schema), handler(args) -> table } }`.
- Tool results are compact tables with an `ok` field; errors are returned to the model (`{ ok = false, error = ... }`), never thrown out of the loop.
- Use `textutils.json_null` where the API needs a real JSON `null`.
- The LLM decides *what* to do; pathfinding, refueling, inventory and coordinates stay in Lua.
- Turtles must be labeled (`label set ...`) or they lose files when broken.

## Known limitations
- `http.post` is blocking and swallows other events (e.g. rednet) while waiting. Move to async `http.request` + `parallel` before fleet work.
- Message history grows unbounded within a run (capped only by `maxTurns`).
- No tests. Risky areas: retry logic in `openrouter.lua`, message bookkeeping in `agent.lua`. Plan: make the client injectable in `agent.run` and test with scripted fake responses in CraftOS-PC.
- Model choice: `deepseek/deepseek-chat` (DeepSeek V3, 2 providers) ran without error but came back empty with no tool call (2026-10-03). Switched to `deepseek/deepseek-v4-flash` (15 providers, all with tool support). Check a slug's providers at `https://openrouter.ai/api/v1/models/<slug>/endpoints` before switching.

## Next steps
1. Turtle tool set: `goTo` (GPS or dead reckoning), `mineArea`, auto-refuel and auto-dump in Lua.
2. Rednet turtle agent + central brain computer (same tool protocol, plus a `turtleId`).
3. Later: storage management via wired modems, monitor dashboards, blueprint-based building, history trimming.
