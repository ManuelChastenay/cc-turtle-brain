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

- A mining turtle needs a pickaxe; give it coal (it refuels by itself and keeps fuel when unloading).
- With a wireless modem and GPS it knows its real position and facing (it steps 1 block and back at startup to check).
- Put a chest next to where it starts, or next to home, so it can unload when full. Home is where it first ran; `brain set home here` changes it.
- Chests, barrels, computers, glass, doors and beds are never dug (`bot/config.lua`).

Secrets (`/.openrouter_key`, `/.github_token`) are never committed.

## Fleet
One computer plans, the turtles work in parallel.

1. Every turtle: label it, `install`, give it a wireless or ender modem, a pickaxe and coal. Then run `worker`, or make it start by itself: `edit startup.lua`, write `shell.run("worker")`, save, reboot.
2. The brain computer: a modem (ender modems avoid range problems), `install`, `edit /.openrouter_key`.
3. On the computer: `fleet <goal>`, e.g. `fleet all turtles dig out x 100 to 131, z 40 to 55, y 60 to 50, then go home`.

A shared dig (`mineBox`) is cut into one slice per turtle, nearest slice to each. Turtles answer the brain while they work. One silent for 60 s (unloaded chunk, out of range) is reported as lost. Ctrl+T on the computer stops every turtle still working. Keep the area chunk-loaded.

## Tests (dev machine)
```
pip install lupa
python tests/run.py
```
