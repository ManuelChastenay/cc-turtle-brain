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
Update later with `install`.

- A mining turtle needs a pickaxe; give it coal (it refuels by itself and keeps one stack of fuel when unloading). To turn fuel off entirely, set `need_fuel = false` under `[turtle]` in the server's `computercraft-server.toml` and restart.
- When its inventory fills, it drops junk (cobblestone, dirt, gravel, deepslate, andesite…; the list is in `bot/config.lua`) instead of going home, and keeps ores. Make the list `{}` to keep everything.
- With a wireless modem and GPS it knows its real position and facing (it steps 1 block and back at startup to check).
- Put a chest next to where it starts, or next to home, so it can unload when full. Home is where it first ran; `brain set home here` changes it.
- Chests, barrels, computers, glass, doors and beds are never dug (`bot/config.lua`).

Secrets (`/.openrouter_key`, `/.github_token`) are never committed.

## Fleet
One computer plans, the turtles work in parallel.

1. Every turtle: label it, `install`, give it a wireless or ender modem, a pickaxe and coal. Make it start the worker by itself: `edit startup.lua`, write `shell.run("worker")`, save, reboot.
2. The brain computer: a modem (ender modems avoid range problems), `install`, `edit /.openrouter_key`, and `edit startup.lua` with `shell.run("fleet resume")`.
3. On the computer: `fleet <goal>`, e.g. `fleet all turtles dig out x 100 to 131, z 40 to 55, y 60 to 50, then go home`.

A shared dig (`mineBox`) is cut into one slice per turtle, nearest slice to each. Other steps go to every turtle in the group. When two turtles meet, the one with the higher computer id steps aside and lets the other pass; an idle turtle in the way is asked to move. Turtles answer the brain while they work. Ctrl+T on the computer stops every turtle still working.

**Restarts.** Jobs survive server restarts and chunk unloads. Turtles save their progress after every block and carry on where they stopped when they start again; the computer picks the job back up with `fleet resume` (that is what its `startup.lua` runs) and collects results turtles finished while it was down. A turtle that goes silent (unloaded chunk, out of range) is waited for up to 10 minutes before it counts as lost. This needs the two `startup.lua` files and GPS on the turtles.

## Dashboard
A screen for the fleet, on the brain computer: `fleet dash` (or `shell.run("fleet dash")` in its `startup.lua` instead of `fleet resume`; it picks up a saved job by itself).

- Put an **advanced monitor** next to the computer (a 4x3 or bigger works well; the dashboard sets text scale 0.5). It lists every turtle with its state (BUSY / idle / LOST), position, fuel and current step, and the recent events. Touch **[STOP ALL]**, **[HOME ALL]** or a busy turtle's **[stop]**. Without a monitor it uses the computer's own screen.
- Type on the computer: plain text is a goal for the LLM, like `fleet <goal>`. Lines starting with `/` run at once with no LLM call: `/stop` (all turtles and the goal) or `/stop 3`, `/home` (stop everything, then all turtles go home) or `/home 3`, `/resume`, `/scale 1` (monitor text scale), `/clear`, `/help`.
- Turtles are polled every 5 s, so the screen stays current between jobs. A turtle silent for 60 s shows as LOST.
- Ctrl+T quits the dashboard only. The turtles keep working and the job is waited for again the next time `fleet dash` starts.

## Tests (dev machine)
```
pip install lupa
python tests/run.py
```
