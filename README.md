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

## Tests (dev machine)
```
pip install lupa
python tests/run.py
```
