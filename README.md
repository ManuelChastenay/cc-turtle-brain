# cc-turtle-brain

LLM-driven ComputerCraft (CC: Tweaked) turtles via OpenRouter.
The LLM turns a goal into a plan of skills with one API call; Lua runs it.

## Install on a turtle
```
label set brain-01
wget https://raw.githubusercontent.com/ManuelChastenay/cc-turtle-brain/main/install.lua
install
edit /.openrouter_key
```
Then: `brain <goal>`, e.g. `brain mine a 6x6 area 3 deep north of here, then come home`.
Update later with `install`. It prints the version it installs, e.g. `Version v8 d2ffe09 (2026-10-04)` and the commit message: v8 = the 8th commit on main (higher is newer), d2ffe09 = the commit. Every file comes from that one commit. Already up to date: nothing is downloaded (`install force` downloads it again). `install <commit>` installs a given commit (the short id from the version line works). `brain refuel` burns everything in the inventory that burns (coal, wood...), with no LLM call.

- A mining turtle needs a pickaxe; give it coal (it refuels by itself). Before unloading into a chest it burns whatever burns (coal, planks, logs...) up to its fuel limit, then keeps one stack of fuel. To turn fuel off entirely, set `need_fuel = false` under `[turtle]` in the server's `computercraft-server.toml` and restart.
- Junk never goes into your chests: cobblestone and mossy cobblestone (with their stairs, slabs and walls), dirt, gravel, deepslate, andesite, raw copper, XyCraft World's kivi… (the list is in `bot/config.lua`, exact names) is dropped into the hole after every mined cell, and before unloading. Each drop takes as long as a move, so digging is about 20% slower than keeping it until the inventory fills. Ores are kept. Make the list `{}` to keep everything.
- With a wireless modem and GPS it knows its real position and facing (it steps 1 block and back at startup to check).
- Put a chest next to where it starts, or next to home, so it can unload when full. Home is where it first ran; `brain set home here` changes it.
- Chests, barrels, computers, glass, doors and beds are never dug (`bot/config.lua`).

Secrets (`/.openrouter_key`, `/.github_token`) are never committed.

## Fleet
One computer plans, the turtles work in parallel.

1. Every turtle: label it, `install`, give it a wireless or ender modem, a pickaxe and coal. Make it start the worker by itself: `edit startup.lua`, write `shell.run("worker")`, save, reboot.
2. The brain computer: a modem (ender modems avoid range problems), `install`, `edit /.openrouter_key`, and `edit startup.lua` with `shell.run("fleet resume")`.
3. On the computer: `fleet <goal>`, e.g. `fleet all turtles dig out x 100 to 131, z 40 to 55, y 60 to 50, then go home`.

Without the LLM: `fleet do <steps>` gives the idle turtles typed steps, split between them exactly like an LLM plan: `fleet do mineSphere 0 100 0 200 bottom=75; goHome; unload` (bare values fill the args in order, `name=value` sets one; `fleet do` alone lists the skills and their args). `fleet retry` (or `fleet retry 3 5`) has every idle turtle whose last job was stopped or failed carry on with it from its last checkpoint. `fleet refuel` (or `fleet refuel 3 5`) makes the idle turtles burn everything that burns. `fleet update` installs the newest commit on the computer, then every idle turtle installs that same commit and reboots into it (`#7 updated to v9 1a2b3c4, rebooting`). Turtles installed before `update` existed need `install` by hand once.

A shared dig (`mineBox`) is cut into one slice per turtle, nearest slice to each. Other steps go to every turtle in the group. When two turtles meet, the one with the higher computer id steps aside and lets the other pass; an idle turtle in the way is asked to move. Turtles answer the brain while they work. Ctrl+T on the computer stops every turtle still working.

**Restarts.** Jobs survive server restarts and chunk unloads. Turtles save their progress after every block and carry on where they stopped when they start again; the computer picks the job back up with `fleet resume` (that is what its `startup.lua` runs) and collects results turtles finished while it was down. A turtle that goes silent (unloaded chunk, out of range) is waited for up to 10 minutes before it counts as lost. This needs the two `startup.lua` files and GPS on the turtles.

**When a job did not finish.** A turtle that rebooted but did not start its worker (no `startup.lua`): run `worker` on it, it carries on from `/job.json`. A job that was stopped (`/stop`, `/home`) or failed (blocked, out of fuel...) is kept on the turtle in `/job_last.json`, with its step and checkpoint, even through later jobs like going home: `fleet retry` or `/retry` has the turtles carry on where they were (they travel back to their share and go on from the last dug block). It stays until a retry picks it up or another job is stopped or fails.

## Dashboard
A screen for the fleet, on the brain computer: `fleet dash` (or `shell.run("fleet dash")` in its `startup.lua` instead of `fleet resume`; it picks up a saved job by itself).

- Put an **advanced monitor** next to the computer (a 4x3 or bigger works well; the dashboard sets text scale 0.5). It lists every turtle with its state (BUSY / idle / LOST), position, fuel and current step, and the recent events. Touch **[STOP ALL]**, **[HOME ALL]**, **[REFUEL ALL]** or a busy turtle's **[stop]**. Without a monitor it uses the computer's own screen.
- Type on the computer: plain text is a goal for the LLM, like `fleet <goal>`; the log shows each LLM call as it starts, how long it took, retries, and the plans it sent. Lines starting with `/` run at once with no LLM call: `/do <steps>` (like `fleet do`; `/do` alone lists the skills), `/retry` or `/retry 3` (like `fleet retry`), `/stop` (all turtles and the goal) or `/stop 3`, `/home` (stop everything, then all turtles go home) or `/home 3`, `/refuel` or `/refuel 3` (idle turtles burn what burns), `/update` or `/update 3` (like `fleet update`), `/resume`, `/scale 1` (monitor text scale), `/clear`, `/exit` (back to the computer's shell), `/help`.
- Turtles are polled every 5 s, so the screen stays current between jobs. A turtle silent for 60 s shows as LOST.
- `/exit` (or Ctrl+T) quits the dashboard only and gives you the computer's shell back. The turtles keep working and the job is waited for again the next time `fleet dash` starts.
- Versions: the log shows this computer's version at start and each turtle's when it joins (`#7 miner-1 joined, v8 d2ffe09`) or comes back from an update (`#7 now runs v9 1a2b3c4`).
- `/update` installs on the computer first (the installer's output shows on the terminal for a moment), then on the turtles. The dashboard keeps running its old code until you `/exit` and start `fleet dash` again.

## Tests (dev machine)
```
pip install lupa
python tests/run.py
```
