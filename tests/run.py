"""<Claude>
Runs tests/tests.lua against the repo in a fake CC: Tweaked world (tests/fakecc.lua),
using Lua 5.2 like CC's Cobalt VM. Dev machine only; turtles never get these files.
Setup once:  pip install lupa      Run:  python tests/run.py
"""
import os
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    sys.exit("Needs the lupa package: pip install lupa")

here = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/") + "/"
repo = os.path.dirname(here.rstrip("/")) + "/"
lua = lupa.LuaRuntime()
lua.execute(f'package.path = "{repo}?.lua;" .. package.path; SIM_DIR = "{here}"; REPO = "{repo}"')
failed = lua.execute(open(here + "tests.lua", encoding="utf-8").read())
sys.exit(1 if failed else 0)
