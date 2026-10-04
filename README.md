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
Update later with `install`. `brain refuel` burns everything in the inventory that burns (coal, wood...), with no LLM call.

- A mining turtle needs a pickaxe; give it coal (it refuels by itself). Before unloading into a chest it burns whatever burns (coal, planks, logs...) up to its fuel limit, then keeps one stack of fuel. To turn fuel off entirely, set `need_fuel = false` under `[turtle]` in the server's `computercraft-server.toml` and restart.
- Junk never goes into your chests: cobblestone and mossy cobblestone (with their stairs, slabs and walls), dirt, gravel, deepslate, andesite, raw copper… (the list is in `bot/config.lua`, exact names) is dropped on the ground when the inventory fills, at the end of each dig and before unloading. Ores are kept. Make the list `{}` to keep everything.
- With a wireless modem and GPS it knows its real position and facing (it steps 1 block and back at startup to check).
- Put a chest next to where it starts, or next to home, so it can unload when full. Home is where it first ran; `brain set home here` changes it.
- Chests, barrels, computers, glass, doors and beds are never dug (`bot/config.lua`).

Secrets (`/.openrouter_key`, `/.github_token`) are never committed.

## Fleet
One computer plans, the turtles work in parallel.

1. Every turtle: label it, `install`, give it a wireless or ender modem, a pickaxe and coal. Make it start the worker by itself: `edit startup.lua`, write `shell.run("worker")`, save, reboot.
2. The brain computer: a modem (ender modems avoid range problems), `install`, `edit /.openrouter_key`, and `edit startup.lua` with `shell.run("fleet resume")`.
3. On the computer: `fleet <goal>`, e.g. `fleet all turtles dig out x 100 to 131, z 40 to 55, y 60 to 50, then go home`.

Without the LLM: `fleet refuel` (or `fleet refuel 3 5`) makes the idle turtles burn everything that burns. `fleet update` makes every idle turtle reinstall the code from GitHub and reboot into it, then updates the computer too. Turtles installed before `update` existed need `install` by hand once.

A shared dig (`mineBox`) is cut into one slice per turtle, nearest slice to each. Other steps go to every turtle in the group. When two turtles meet, the one with the higher computer id steps aside and lets the other pass; an idle turtle in the way is asked to move. Turtles answer the brain while they work. Ctrl+T on the computer stops every turtle still working.

**Restarts.** Jobs survive server restarts and chunk unloads. Turtles save their progress after every block and carry on where they stopped when they start again; the computer picks the job back up with `fleet resume` (that is what its `startup.lua` runs) and collects results turtles finished while it was down. A turtle that goes silent (unloaded chunk, out of range) is waited for up to 10 minutes before it counts as lost. This needs the two `startup.lua` files and GPS on the turtles.

## Dashboard
A screen for the fleet, on the brain computer: `fleet dash` (or `shell.run("fleet dash")` in its `startup.lua` instead of `fleet resume`; it picks up a saved job by itself).

- Put an **advanced monitor** next to the computer (a 4x3 or bigger works well; the dashboard sets text scale 0.5). It lists every turtle with its state (BUSY / idle / LOST), position, fuel and current step, and the recent events. Touch **[STOP ALL]**, **[HOME ALL]**, **[REFUEL ALL]** or a busy turtle's **[stop]**. Without a monitor it uses the computer's own screen.
- Type on the computer: plain text is a goal for the LLM, like `fleet <goal>`. Lines starting with `/` run at once with no LLM call: `/stop` (all turtles and the goal) or `/stop 3`, `/home` (stop everything, then all turtles go home) or `/home 3`, `/refuel` or `/refuel 3` (idle turtles burn what burns), `/update` or `/update 3` (idle turtles reinstall from GitHub and reboot), `/resume`, `/scale 1` (monitor text scale), `/clear`, `/exit` (back to the computer's shell), `/help`.
- Turtles are polled every 5 s, so the screen stays current between jobs. A turtle silent for 60 s shows as LOST.
- `/exit` (or Ctrl+T) quits the dashboard only and gives you the computer's shell back. The turtles keep working and the job is waited for again the next time `fleet dash` starts.
- `/update` does not update the computer itself (it is running the code): `/exit`, `install`, `fleet dash`. Or `/exit` and `fleet update`, which does the turtles and the computer.

## Tests (dev machine)
```
pip install lupa
python tests/run.py
```
