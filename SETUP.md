# CC Turtle Brain: setup guide

Everything you need to set up the computers, turtles, monitor and server for this project.
Written 2026-10-03 from a read of the code. The status column says what is confirmed in-game and what is only tested in the simulator.

An LLM (through OpenRouter) turns a goal into a **plan**: an ordered list of skill steps. Lua then runs the plan with no further LLM calls. The LLM is called again only when a step fails.

## 1. The machines

| Role | Hardware | Program | Needs the API key? |
|---|---|---|---|
| **Single turtle** | Turtle + pickaxe, optional wireless modem (for GPS) | `brain <goal>` | Yes |
| **Fleet worker** (one per turtle) | Turtle + pickaxe + wireless/ender modem | `worker` (from `startup.lua`) | No |
| **Fleet brain** | Computer + wireless/ender modem, optional advanced monitor | `fleet <goal>`, `fleet resume` or `fleet dash` | Yes |
| **GPS hosts** | 4 computers with wireless/ender modems | `gps host x y z` | No |
| **Chests / barrels** | Next to each turtle's start or home | none | n/a |

- A turtle has two equipment slots: **pickaxe on one side, modem on the other**.
- Workers never call the LLM. Only the machine that runs `brain` or `fleet` needs `/.openrouter_key`.
- The fleet needs GPS. Plans use world coordinates (`mineBox`, `goTo`), so turtles without GPS would each use their own relative frame. A single turtle works without GPS but loses exact resume (see section 7).

## 2. Server setup

The server is on a managed host (gamesservers.io) with a file manager only. Edit `computercraft-server.toml` and restart.

| Setting | Value | Why |
|---|---|---|
| `[[http.rules]]` entry for `openrouter.ai` | `timeout = 120000` | LLM calls take longer than CC's default HTTP timeout (30 s). Already set. |
| Hosts reachable by `install` | `raw.githubusercontent.com`, plus `api.github.com` in private-repo mode | Works today. If you replace the whole rules list, keep these allowed. |
| `need_fuel = false` under `[turtle]` | optional, **not set** | Turtles report `"unlimited"` and the code skips all fuel logic (tested). |

Other server facts:
- Fuel limits are a CC default: 20,000 for a normal turtle, 100,000 for an advanced turtle. Turtles refuel up to the limit.
- Each computer has a default 1 MB disk. The full install is about 107 KB.
- Wireless modem range is about 64 blocks by default. Ender modems have no range limit. A turtle out of range or in an unloaded chunk goes silent. The fleet brain waits up to 10 minutes before treating it as lost.
- If the server uses claim or protection mods, turtles may be unable to dig inside protected areas (CC's `obey_block_protection`). I did not check this.

## 3. Secrets (never committed)

| File | On which machine | Contents |
|---|---|---|
| `/.openrouter_key` | single turtle, fleet brain computer | OpenRouter API key |
| `/.github_token` | any machine, only if the repo is private | read-only fine-grained GitHub token |

Create them by hand with `edit /.openrouter_key`. Both are in `.gitignore`.

## 4. Setting up each machine

### 4.1 Install (every machine)
```
label set <name>
wget https://raw.githubusercontent.com/ManuelChastenay/cc-turtle-brain/main/install.lua
install
```
- **Label every turtle.** An unlabeled turtle loses its files when broken. The label also shows in the fleet roster.
- `install` downloads all 19 files and updates itself first, so new files arrive in one run. Re-run `install` to update.
- It prints the version: `Version v8 d2ffe09 (2026-10-04)` plus the commit message. `v8` counts the commits on main (higher is newer), `d2ffe09` is the commit. All files come from that commit, and the version is saved in `/.version`. If it is already installed, nothing is downloaded (`install force` downloads it again). `install <commit sha>` installs a given commit; the short id from the version line works (one API call to find the full one).
- Finding the newest commit costs one GitHub API call. Without a token the limit is 60 calls an hour for the whole server IP. If GitHub refuses, `install` still works from the branch and says `version unknown`.
- Fleet turtles can be updated from the brain computer instead: `fleet update` (or `/update` in the dashboard). The computer installs the newest commit first, then each turtle installs that same commit (no API call on the turtles) and reboots. In private-repo mode every turtle still needs `/.github_token`. A turtle installed before this command existed must run `install` by hand once.
- The raw URL of the branch can serve stale files for about 5 minutes after a push. That only matters for `wget` and for installers older than versions; `install` itself downloads by commit.
- The raw URL for `wget` only works while the repo is public. Private mode needs `/.github_token`, and the first download then needs another route.
- `install` never touches `startup.lua` or your secrets.

### 4.2 Single turtle (`brain`)
1. Give it a pickaxe. Add coal unless `need_fuel = false`.
2. Put a chest next to where it starts, or next to home.
3. `edit /.openrouter_key`
4. Run `brain mine a 6x6 area 3 deep north of here, then come home`.

**Status: confirmed in-game** with `mineArea`. It does not resume after a reboot.

### 4.3 Fleet worker turtle
1. Label it, `install`, equip a **pickaxe and a wireless/ender modem**, and load coal.
2. `edit startup.lua` and write `shell.run("worker")`, then reboot.
3. It should print `Worker #<id> <label> ready`, then its state line.
4. Leave **one free block** around it at boot. With GPS, startup steps one block and back to learn which way it faces. A boxed-in turtle has an unknown heading and its moves fail.

### 4.4 Fleet brain computer
1. Attach a modem (ender recommended). Add an advanced monitor next to it for the dashboard.
2. `install`, then `edit /.openrouter_key`.
3. `edit startup.lua` with one of:
   - `shell.run("fleet resume")`: after a reboot, waits again for the saved job.
   - `shell.run("fleet dash")`: the dashboard. It resumes a saved job by itself.
4. Try `fleet <goal>`, for example `fleet all turtles dig out x 100 to 131, z 40 to 55, y 60 to 50, then go home`.

### 4.5 GPS hosts (reminder: yours already work)
Four computers with wireless/ender modems at known coordinates, not all in one plane. Each runs `gps host <x> <y> <z>` from its `startup.lua`.

### 4.6 Chests
- Put a chest or barrel (any block with an inventory) next to each turtle's start or home.
- Each turtle's **home is where it first ran**. Its saved state is in `/nav_state.json`. If you move a turtle by hand, home does not move. Reset it with the `setHome` skill, or delete `/nav_state.json` and reboot.
- A full chest gives the error `chest is full`.
- The code looks at all six sides. I'd put the chest **in front, above or below** the turtle. The side holding the modem can't expose a chest, and I did not verify the other side in-game.
- Ores stay in the turtle at the end of a dig. Include "go home and unload" in the goal to collect them.

## 5. Using the terminals

| Where | Type | Effect |
|---|---|---|
| Turtle terminal | `brain <goal>` | One LLM call, then Lua runs the plan |
| Turtle terminal | `brain refuel` | Burn everything in the inventory that burns, no LLM call |
| Computer terminal | `fleet <goal>` | One LLM call plans for all turtles; Ctrl+T stops the busy turtles |
| Computer terminal | `fleet do <steps>` | Idle turtles run typed steps, shared ones split between them, no LLM call (`fleet do` lists the skills) |
| Computer terminal | `fleet retry [ids]` | Idle turtles carry on with their stopped or failed job from its last checkpoint, no LLM call |
| Computer terminal | `fleet refuel [ids]` | Idle turtles (all, or the ids given) burn what burns, no LLM call |
| Computer terminal | `fleet update` | This computer installs the newest commit, then idle turtles install the same one and reboot |
| Computer terminal | `fleet resume` | Wait again for the job saved before a reboot |
| Computer terminal | `fleet dash` | Dashboard: monitor plus a prompt on the last terminal line |

**Dashboard prompt.** Plain text is a goal for the LLM. Lines starting with `/` run in Lua with no LLM call:

| Command | Does |
|---|---|
| `/do <steps>` | Like `fleet do`: e.g. `/do mineBox 0 60 0 31 50 15; goHome; unload`. `/do` alone lists the skills |
| `/retry [id]` | Like `fleet retry`: carry on with stopped or failed jobs where they were |
| `/stop [id]` | Stop all turtles and the goal, or one turtle |
| `/home [id]` | Stop everything, then send turtles home (one turtle only if no goal is running) |
| `/refuel [id]` | Idle turtles burn what burns (all, or one) |
| `/update [id]` | Like `fleet update`; the dashboard keeps its old code until `/exit` and `fleet dash` |
| `/resume` | Wait again for an interrupted job |
| `/scale n` | Monitor text scale, 0.5 to 5 |
| `/clear` | Clear the log |
| `/exit` | Leave the dashboard for the computer's shell; turtles keep working |
| `/help` | List the commands |

**Dashboard screen.**
- Turtles are polled every 5 s. A turtle silent for 60 s shows as LOST.
- Touch **[STOP ALL]**, **[HOME ALL]** or a busy turtle's **[stop]** on an advanced monitor. Without a monitor it draws on the terminal.
- Touch **[REFUEL ALL]** to run `/refuel` for every idle turtle.
- `/exit` or Ctrl+T quits the dashboard only and clears the screen for the shell. Turtles keep working and the job is waited for again at the next `fleet dash`.
- The log shows this computer's version at start, and each turtle's when it joins or comes back from an update.
- Columns shrink with width (from `bot/ui.lua`): the stop button appears at about 30 columns, the name at 44 and the position at 60.
- A computer terminal is 51 wide, so it shows names but no positions. A 4x3 monitor at scale 0.5 should be about 79 wide and shows everything. Use `/scale 0.5` on a narrow monitor.
- The turtle's own terminal is small (39x13): long replies scroll.

## 6. What the LLM can plan

`mineArea`, `mineBox`, `goTo`, `move`, `face`, `goHome`, `setHome`, `unload`, `refuel`. Plans are limited to 20 steps and validated before anything moves.

- `mineArea` digs a box relative to the turtle, then returns to the start. `mineBox` digs a box between two world corners.
- In a fleet group, `mineBox` is cut into one slice per turtle, along the longer side. Other steps go to every turtle in the group.
- Lua handles paths, refuelling, junk dropping and unloading. The LLM never plans those.
- `refuel` burns anything combustible in any slot (coal, planks, logs, sticks...) up to the fuel limit. `unload` does the same first, drops junk, then stores the rest and keeps one stack of fuel.
- `brain set home here` is not a built-in command. It goes to the LLM as a goal, which maps to `setHome`, so it costs one call.

## 7. Where state lives

| File | Machine | Purpose |
|---|---|---|
| `/nav_state.json` | every turtle | position, heading, home, calibration markers |
| `/job.json` | worker | current job, step and checkpoint (deleted when done) |
| `/job_last.json` | worker | last stopped or failed job with its checkpoint, for `fleet retry` / `/retry` |
| `/job_result.json` | worker | last result, kept until the brain acknowledges it |
| `/fleet_job.json` | fleet brain | job in flight, used by `fleet resume` |
| `/llm_last.json` | brain / fleet computer | raw last LLM response (read this first when a run misbehaves) |
| `/.version` | every machine | installed version: `{ n, sha, date, message }` |
| `/install.lua`, `startup.lua` | every machine | installer; your boot hook |

**Reboots.**
- Workers carry on from the last checkpoint (after every dug cell). Results are kept until acknowledged.
- With GPS and a consistent saved state, a resuming worker makes no calibration moves.
- Without GPS, coordinates are relative to the first run and "north" is the first facing, so resume is not exact.

## 8. Settings you may change

**`llm/config.lua`**: `model` (now `deepseek/deepseek-v4-flash`; alternative `anthropic/claude-haiku-4.5`), `maxTurns = 4` (LLM calls per goal), `maxRetries = 3`, `keyPath`, `debugPath`.
- Check a model's providers at `https://openrouter.ai/api/v1/models/<slug>/endpoints` first. `deepseek-chat` returned empty replies with no tool call.

**`bot/config.lua`**:

| Setting | Now | Meaning |
|---|---|---|
| `fuelItems` | coal, coke, lava_bucket, blaze_rod, dried_kelp_block | Burned for fuel (substring match) |
| `keepFuel` | 64 | Fuel items kept when unloading (none if fuel is unlimited) |
| `fuelMargin` | 20 | Extra fuel kept on top of a job's need |
| `junk` | cobblestone and mossy cobblestone (+ stairs, slab, wall), cobbled deepslate, dirt, gravel, andesite, diorite, granite, tuff, netherrack, raw copper, `xycraft_world:kivi` | Exact names. Never stored: dropped into the hole after every mined cell (about 20% slower digging), after a trip that dug through something, and before unloading. `{}` keeps everything. |
| `protect` | `computercraft:`, chest, barrel, shulker_box, furnace, `_door`, glass, `_bed` | Never dug, even in the way |
| `turtleWaits` | 20 | About 1 s retries when another turtle blocks the way |
| `maxSteps` | 20 | Longest plan accepted |

## 9. Feature status

| Feature | Status |
|---|---|
| Single turtle `brain` + `mineArea` | **Confirmed in-game** |
| `mineBox`, `worker`, `fleet`, rednet protocol | Sim-tested only |
| Resume after reboot (worker jobs, `fleet resume`) | Sim-tested only (1,000+ random jobs, about 13,000 reboots) |
| Turtle-meets-turtle (right of way, step aside, `makeway`) | Sim-tested only |
| Junk dropping, unload at chest or home | Sim-tested only |
| Dashboard (`fleet dash`, monitor, touch, `/commands`) | Sim-tested only; real monitor sizes and touch events unverified |
| Refuel commands, `fleet update` / `/update`, `/exit`, versions | Sim-tested only |
| Test suite | **111 passed, 0 failed** (run on 2026-10-03 with `python tests/run.py`) |

### Known limits that matter for setup
- No pathfinding: `goTo` walks axis by axis and digs through whatever is in the way (protected blocks excepted).
- No fuel pickup: turtles only burn fuel they carry or dig up, unless `need_fuel = false`.
- The fleet replans only once every turtle has finished.
- The dashboard runs one goal at a time.
- Rednet is not authenticated: anyone on the server could send plans to your workers.
- Dropped junk becomes item entities that despawn after 5 minutes: about one per mined cell, so roughly 120 per digging turtle at any time. Many turtles keep a few thousand around the dig. If the server lags, ask for junk to be dropped only when the inventory fills again.
- Whether a turtle can read an adjacent turtle's id with `peripheral.call(side, "getID")` is untested in-game. If it can't, a coin flip decides who steps aside (slower).
- The computers and turtles must be in loaded chunks. A frozen turtle resumes when its chunk loads again.

## 10. Suggested first fleet test (from CLAUDE.md "Next steps")
1. Prepare 2 turtles as in 4.3 and one brain computer as in 4.4 with `fleet dash`.
2. The log should show `#<id> <label> joined` for each turtle.
3. Run a 10x10x10 dig with 2 turtles, then 5 turtles on 30x30x20.
4. If something misbehaves, collect what `fleet` printed and what the worker printed, plus `/job.json`, `/nav_state.json` and `/llm_last.json`.

## 11. Dev machine

```
pip install lupa
python tests/run.py
```
- `tests/` runs in a fake CC world (Lua 5.2, like CC's Cobalt VM). It is never installed on turtles.
- Code must avoid `//`, bitwise operators and `goto`.
- Keep `FILES` in `install.lua` in sync when you add files.
