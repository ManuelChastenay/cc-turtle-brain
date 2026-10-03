--[[ <Claude>
  Tests for bot/* and llm/agent.lua in a fake world (tests/fakecc.lua).
  Run with: python tests/run.py. The LLM is replaced by scripted replies.
]]
local sim = dofile(SIM_DIR .. "fakecc.lua")
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local NAMES = { [0] = "north", "east", "south", "west" }
local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

local function saveState(h, home)
  sim.files["/nav_state.json"] = textutils.serialiseJSON({
    pos = { x = sim.t.x, y = sim.t.y, z = sim.t.z }, heading = h, home = home })
end

local function boxCells(o, h, L, W, N, vertical, side)
  local rh = (h + 1) % 4
  local r0 = side == "left" and -(W - 1) or side == "center" and -math.floor((W - 1) / 2) or 0
  local cells = {}
  for a = 1, L do for r = r0, r0 + W - 1 do for i = 1, N do
    local l = vertical == "up" and i - 1 or -i
    cells[sim.key(o.x + a * DX[h] + r * DX[rh], o.y + l, o.z + a * DZ[h] + r * DZ[rh])] = true
  end end end
  return cells
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

---------------------------------------------------------------- user's scenario
test("user goal: 6x6x3 north from 442,31,907 facing east, fuel 78", function()
  sim.reset{ turtle = { x = 442, y = 31, z = 907, h = 1, fuel = 78 } }
  local nav = require("bot.nav")
  local skills = require("bot.skills")
  local plan = require("bot.plan")
  nav.init()
  eq(nav.heading(), 1, "calibrated heading")
  eq(sim.t.x, 442) eq(sim.t.z, 907) eq(sim.t.h, 1, "faces original way after calibration")
  local fuel0 = sim.t.fuel
  local steps = assert(plan.check({
    { skill = "mineArea", direction = "north", length = 6, width = 6, layers = 3 },
    { skill = "goHome" } }, skills.list))
  local ok, n, results = plan.run(steps)
  truthy(ok, "plan ok: " .. tostring(results[n] and results[n].error))
  eq(results[1].mined, 108, "mined")
  eq(sim.t.x, 442) eq(sim.t.y, 31) eq(sim.t.z, 907) eq(sim.t.h, 1, "end facing")
  local box = boxCells({ x = 442, y = 31, z = 907 }, 0, 6, 6, 3, "down", "right")
  for k in pairs(box) do eq(sim.get(k:match("(-?%d+),(-?%d+),(-?%d+)")), nil, "box cell " .. k) end
  eq(#sim.dugLog, 108, "nothing outside the box dug")
  print(("  user goal: fuel used %d (78 available), inventory %s"):format(fuel0 - sim.t.fuel, skills.state()))
end)

---------------------------------------------------------------- all shapes, solid world: no collateral
test("mineArea shapes: dug cells == box (+ entry cell when digging down)", function()
  local n = 0
  for h = 0, 3 do
    for _, vertical in ipairs({ "down", "up" }) do
      for _, side in ipairs({ "right", "left", "center" }) do
        for _, dims in ipairs({ { 1, 1, 1 }, { 1, 3, 2 }, { 2, 2, 4 }, { 3, 1, 5 }, { 4, 5, 3 }, { 5, 4, 7 } }) do
          local L, W, N = dims[1], dims[2], dims[3]
          sim.reset{ gps = false, terrain = function() return "minecraft:stone" end,
            turtle = { x = 10, y = 64, z = -20, h = (h + 1) % 4, fuel = 5000 } }
          saveState((h + 1) % 4)
          local nav, mine = require("bot.nav"), require("bot.mine")
          nav.init()
          local r = mine.mineArea({ direction = NAMES[h], length = L, width = W, layers = N, vertical = vertical, side = side })
          local tag = ("%s %s %s %dx%dx%d"):format(NAMES[h], vertical, side, L, W, N)
          truthy(r.ok, tag .. ": " .. tostring(r.error))
          local box = boxCells({ x = 10, y = 64, z = -20 }, h, L, W, N, vertical, side)
          local expected = count(box)
          if vertical == "down" then box[sim.key(10 + DX[h], 64, -20 + DZ[h])] = true expected = expected + 1 end
          for _, k in ipairs(sim.dugLog) do truthy(box[k], tag .. ": collateral dig at " .. k) end
          eq(#sim.dugLog, expected, tag .. ": dug count")
          eq(r.mined, expected, tag .. ": reported mined")
          eq(sim.t.x, 10, tag) eq(sim.t.y, 64, tag) eq(sim.t.z, -20, tag) eq(sim.t.h, (h + 1) % 4, tag .. " heading")
          local passes = math.ceil(N / 3)
          truthy(sim.moves <= L * W * passes + 2 * (L + W + N) + 4, tag .. ": moves " .. sim.moves)
          n = n + 1
        end
      end
    end
  end
  print("  shapes checked: " .. n)
end)

---------------------------------------------------------------- gravel
test("gravel falling into the box is cleared", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000 } }
  for y = 25, 33 do sim.set(1, y, -2, "minecraft:gravel") end -- column through and above the box
  sim.set(2, 29, -1, "minecraft:sand")
  saveState(0)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 3, width = 3, layers = 3, vertical = "down", side = "right" })
  truthy(r.ok, tostring(r.error))
  for k in pairs(boxCells({ x = 0, y = 31, z = 0 }, 0, 3, 3, 3, "down", "right")) do
    eq(sim.get(k:match("(-?%d+),(-?%d+),(-?%d+)")), nil, "box cell " .. k)
  end
  truthy(sim.sleeps > 0, "waited for falling blocks")
end)

---------------------------------------------------------------- failures come back to start
test("protected block inside the box: fails, returns to start", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 2, fuel = 5000 } }
  sim.set(2, 29, -3, "minecraft:chest")
  saveState(2)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 5, width = 4, layers = 4, vertical = "down", side = "right" })
  eq(r.ok, false) truthy(r.error:find("protected"), r.error)
  eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0) eq(sim.t.h, 2)
  eq(sim.get(2, 29, -3), "minecraft:chest")
end)

test("bedrock: fails with reason, returns to start", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000 } }
  sim.set(1, 26, -2, "minecraft:bedrock")
  saveState(0)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 3, width = 3, layers = 6, vertical = "down", side = "right" })
  eq(r.ok, false) truthy(r.error:find("Unbreakable"), r.error)
  eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0) eq(sim.t.h, 0)
end)

test("not enough fuel: refuses before moving", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 30 } }
  saveState(0)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 6, width = 6, layers = 3, vertical = "down", side = "right" })
  eq(r.ok, false) truthy(r.error:find("needs about"), r.error)
  eq(sim.moves, 0)
end)

test("coal in inventory is burned when needed, not all of it", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5, inv = { [3] = { "minecraft:coal", 10 } } } }
  saveState(0)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 6, width = 6, layers = 3, vertical = "down", side = "right" })
  truthy(r.ok, tostring(r.error))
  eq(sim.t.inv[3].count, 9, "one coal burned")
end)

---------------------------------------------------------------- inventory full
test("full inventory: unloads into chest behind the start and resumes", function()
  local inv = {}
  for s = 1, 14 do inv[s] = { "minecraft:dirt", 64 } end
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000, inv = inv },
    terrain = function(x, y, z) if y <= 30 then return ({ "minecraft:stone", "minecraft:andesite", "minecraft:diorite", "minecraft:granite", "minecraft:tuff" })[(x + y * 3 + z * 7) % 5 + 1] end end }
  sim.set(0, 31, 1, "minecraft:chest")
  saveState(0)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 5, width = 5, layers = 5, vertical = "down", side = "right" })
  truthy(r.ok, tostring(r.error))
  truthy(r.trips >= 1, "trips " .. tostring(r.trips))
  eq(sim.lost, 0, "items lost")
  truthy(#sim.chests[sim.key(0, 31, 1)].items >= 14, "chest got items")
  eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0) eq(sim.t.h, 0)
  for k in pairs(boxCells({ x = 0, y = 31, z = 0 }, 0, 5, 5, 5, "down", "right")) do
    eq(sim.get(k:match("(-?%d+),(-?%d+),(-?%d+)")), nil, "box cell " .. k)
  end
end)

test("full inventory: unloads at home chest when none at the start", function()
  local inv = { [16] = { "minecraft:coal", 5 } }
  for s = 1, 15 do inv[s] = { "minecraft:dirt", 64 } end
  sim.reset{ gps = false, turtle = { x = 5, y = 31, z = 5, h = 0, fuel = 5000, inv = inv } }
  sim.set(-1, 31, 0, "minecraft:barrel")
  saveState(0, { x = 0, y = 31, z = 0, heading = 3 })
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "east", length = 3, width = 3, layers = 2, vertical = "down", side = "left" })
  truthy(r.ok, tostring(r.error))
  eq(r.trips, 1)
  eq(sim.t.inv[16].name, "minecraft:coal", "fuel kept")
  eq(sim.t.x, 5) eq(sim.t.z, 5) eq(sim.t.h, 0)
end)

test("full inventory and no chest anywhere: fails at the start", function()
  local inv = {}
  for s = 1, 16 do inv[s] = { "minecraft:dirt", 64 } end
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000, inv = inv } }
  saveState(0)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 3, width = 3, layers = 3, vertical = "down", side = "right" })
  eq(r.ok, false) truthy(r.error:find("cannot unload"), r.error)
  eq(sim.moves, 0)
end)

---------------------------------------------------------------- nav
test("calibration: front blocked, back free", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 3, fuel = 100 } }
  sim.set(-1, 31, 0, "minecraft:stone")
  local nav = require("bot.nav")
  nav.init()
  eq(nav.heading(), 3) eq(sim.t.x, 0) eq(sim.t.h, 3)
end)

test("calibration: front and back blocked, side free; restores facing", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 100 } }
  sim.set(0, 31, -1, "minecraft:stone") sim.set(0, 31, 1, "minecraft:stone") sim.set(1, 31, 0, "minecraft:stone")
  local nav = require("bot.nav")
  nav.init()
  eq(nav.heading(), 0) eq(sim.t.h, 0) eq(sim.t.x, 0) eq(sim.t.z, 0)
end)

test("calibration impossible: saved heading used only if position matches", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 2, fuel = 100 } }
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do sim.set(d[1], 31, d[2], "minecraft:stone") end
  saveState(2)
  local nav = require("bot.nav")
  nav.init()
  eq(nav.heading(), 2)
  sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = 9, y = 9, z = 9 }, heading = 2 })
  package.loaded["bot.nav"] = nil
  nav = require("bot.nav")
  nav.init()
  eq(nav.heading(), nil)
end)

test("mob in the way gets attacked; goTo digs through", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 100 } }
  sim.mobs[sim.key(0, 31, -2)] = true
  sim.set(0, 31, -3, "minecraft:dirt")
  saveState(0)
  local nav = require("bot.nav")
  nav.init()
  truthy(nav.goTo({ x = 0, y = 31, z = -4 }))
  eq(sim.t.z, -4) truthy(sim.attacks > 0)
end)

test("skills: move, face, goHome, setHome, unload, refuel", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 10,
    inv = { { "minecraft:cobblestone", 20 }, { "minecraft:coal", 2 } } } }
  sim.set(-1, 31, 0, "minecraft:chest")
  saveState(0)
  local nav, skills, plan = require("bot.nav"), require("bot.skills"), require("bot.plan")
  nav.init()
  local steps = assert(plan.check({
    { skill = "unload" }, { skill = "move", direction = "right", blocks = 3 }, { skill = "move", direction = "up", blocks = "2" },
    { skill = "face", direction = "south" }, { skill = "setHome" }, { skill = "goTo", x = 0, y = 31, z = 0 },
    { skill = "goHome" }, { skill = "refuel" } }, skills.list))
  local ok, n, results = plan.run(steps)
  truthy(ok, "step " .. n .. ": " .. tostring(results[n] and results[n].error))
  eq(results[1].items, 20, "unloaded")
  eq(sim.t.x, 3) eq(sim.t.y, 33) eq(sim.t.z, 0) eq(sim.t.h, 2, "home facing")
  truthy(results[8].fuel > 100, "refueled")
  eq(sim.t.inv[2], nil, "coal burned")
  local s = skills.state()
  truthy(s:find("pos 3,33,0 facing south"), s)
end)

---------------------------------------------------------------- plan checks
test("plan.check messages", function()
  sim.reset{}
  local skills, plan = require("bot.skills"), require("bot.plan")
  local function err(steps) local s, e = plan.check(steps, skills.list) eq(s, nil) return e end
  truthy(err({}):find("non%-empty"))
  truthy(err({ { skill = "fly" } }):find("unknown skill fly"))
  truthy(err({ { skill = "mineArea", direction = "north", length = 6, width = 6 } }):find("missing layers"))
  truthy(err({ { skill = "mineArea", direction = "up", length = 6, width = 6, layers = 1 } }):find("direction must be one of"))
  truthy(err({ { skill = "mineArea", direction = "north", length = 0, width = 6, layers = 1 } }):find("at least 1"))
  truthy(err({ { skill = "mineArea", direction = "north", length = 6, width = 6, layers = 1, depth = 3 } }):find("unexpected depth"))
  truthy(err({ { skill = "goTo", x = 1.5, y = 1, z = 1 } }):find("integer"))
  truthy(err({ "goHome" }):find("not an object"))
  local s = assert(plan.check({ { skill = "mineArea", direction = "north", length = "6", width = 6, layers = 3 } }, skills.list))
  eq(s[1].args.length, 6) eq(s[1].args.vertical, "down") eq(s[1].args.side, "right")
  eq(plan.format(s[1]), "mineArea direction=north length=6 width=6 layers=3 vertical=down side=right")
end)

---------------------------------------------------------------- agent loop with a scripted LLM
local function fakeClient(replies)
  local calls = {}
  package.loaded["llm.openrouter"] = { chat = function(messages, tools)
    calls[#calls + 1] = { messages = messages, n = #messages, tools = tools }
    local r = table.remove(replies, 1)
    if not r then return nil, "no more scripted replies" end
    if type(r) == "string" then return { role = "assistant", content = r }, { prompt_tokens = 100, completion_tokens = 10 } end
    return { role = "assistant", tool_calls = { { id = "c" .. #calls, type = "function",
      ["function"] = { name = "runPlan", arguments = textutils.serialiseJSON({ steps = r }) } } } },
      { prompt_tokens = 100, completion_tokens = 30 }
  end }
  return calls
end

local function brainSetup()
  local nav, skills, plan = require("bot.nav"), require("bot.skills"), require("bot.plan")
  nav.init()
  return require("llm.agent"), { runPlan = plan.tool(skills.list, skills.state) }
end

test("agent: a good plan costs exactly one LLM call", function()
  sim.reset{ turtle = { x = 442, y = 31, z = 907, h = 1, fuel = 78 } }
  local calls = fakeClient({ { { skill = "mineArea", direction = "north", length = 6, width = 6, layers = 3 }, { skill = "goHome" } } })
  local agent, tools = brainSetup()
  local text, stats = agent.run("mine a 6x6 area 3 deep north of here, then come home.", tools, "sys")
  truthy(text, tostring(stats))
  eq(#calls, 1) eq(stats.turns, 1)
  truthy(text:find("^Done: mineArea"), text)
  print("  summary: " .. text)
end)

test("agent: rejected plan, then fixed plan = two calls", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500 } }
  local calls = fakeClient({ { { skill = "mineArea", direction = "north", length = 2, width = 2, depth = 2 } },
    { { skill = "mineArea", direction = "north", length = 2, width = 2, layers = 2 } } })
  local agent, tools = brainSetup()
  local text, stats = agent.run("dig", tools, "sys")
  truthy(text, tostring(stats)) eq(#calls, 2)
  local toolMsg = calls[2].messages[calls[2].n]
  eq(toolMsg.role, "tool") truthy(toolMsg.content:find("plan rejected"), toolMsg.content)
end)

test("agent: failed step sends error + fresh state; model gives up in text", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500 } }
  sim.set(1, 30, -1, "minecraft:bedrock")
  local calls = fakeClient({ { { skill = "mineArea", direction = "north", length = 2, width = 2, layers = 2 }, { skill = "goHome" } },
    "Bedrock in the way, cannot dig there." })
  local agent, tools = brainSetup()
  local text, stats = agent.run("dig", tools, "sys")
  eq(text, "Bedrock in the way, cannot dig there.") eq(stats.turns, 2)
  local toolMsg = textutils.unserialiseJSON(calls[2].messages[calls[2].n].content)
  eq(toolMsg.ok, false) truthy(toolMsg.error:find("step 1 %(mineArea%) failed"), toolMsg.error)
  truthy(toolMsg.state:find("pos 0,31,0"), toolMsg.state)
  print("  failure payload: " .. calls[2].messages[calls[2].n].content)
end)

test("agent: a question is answered without running anything", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500 } }
  local calls = fakeClient({ "Fuel is 498." })
  local agent, tools = brainSetup()
  local text = agent.run("how much fuel?", tools, "sys")
  eq(text, "Fuel is 498.") eq(#calls, 1)
end)

test("agent: Ctrl+T inside a skill stops the program", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500 } }
  local calls = fakeClient({ { { skill = "mineArea", direction = "north", length = 4, width = 4, layers = 3 } }, "should not be asked" })
  local agent, tools = brainSetup()
  sim.terminateAtMove = sim.moves + 10
  local ok, err = pcall(agent.run, "dig", tools, "sys")
  eq(ok, false) eq(err, "Terminated") eq(#calls, 1)
end)

---------------------------------------------------------------- prompt size
test("prompt + schema", function()
  sim.reset{}
  local skills, plan = require("bot.skills"), require("bot.plan")
  local cat = plan.catalog(skills.list)
  local schema = textutils.serialiseJSON(plan.tool(skills.list, skills.state).parameters)
  print(("  prompt size: catalog %d chars, runPlan schema %d chars"):format(#cat, #schema))
end)

test("brain.lua end to end + install.lua parses", function()
  sim.reset{ turtle = { x = 442, y = 31, z = 907, h = 1, fuel = 78 } }
  local calls = fakeClient({ { { skill = "mineArea", direction = "north", length = 6, width = 6, layers = 3 }, { skill = "goHome" } } })
  local out, realPrint = {}, print
  _G.write, _G.read = io.write, function() return "" end
  _G.print = function(s) out[#out + 1] = tostring(s) end
  local ok, err = pcall(assert(loadfile(REPO .. "brain.lua")), "mine", "a", "6x6", "area", "3", "deep", "north")
  _G.print = realPrint
  truthy(ok, tostring(err))
  eq(#calls, 1)
  truthy(table.concat(out, "\n"):find("Done: mineArea"), table.concat(out, "\n"))
  assert(loadfile(REPO .. "install.lua"))
end)

print(("passed %d, failed %d"):format(passed, failed))
return failed > 0
