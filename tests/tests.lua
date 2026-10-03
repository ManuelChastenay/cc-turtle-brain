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
    -- a list of steps = runPlan; { plans = ... } = runPlans (fleet)
    local name, args = r.plans and "runPlans" or "runPlan", r.plans and r or { steps = r }
    return { role = "assistant", tool_calls = { { id = "c" .. #calls, type = "function",
      ["function"] = { name = name, arguments = textutils.serialiseJSON(args) } } } },
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

---------------------------------------------------------------- fleet: turtle side
local function quietly(fn, ...)
  local out, realPrint, realError = {}, print, printError
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, " ")
  end
  _G.printError = _G.print
  local res = table.pack(pcall(fn, ...))
  _G.print, _G.printError = realPrint, realError
  return out, table.unpack(res, 1, res.n)
end

test("mineBox: digs exactly the box from any side, ends just above it", function()
  local boxes = { { 3, 28, 4, 8, 30, 6 }, { 8, 30, 6, 3, 28, 4 }, { -5, 29, -9, -5, 30, -2 }, { 0, 26, 0, 3, 30, 3 } }
  local starts = { { -10, -10 }, { 20, 0 }, { 0, 20 }, { 15, 15 }, { 5, 5 } }
  for _, b in ipairs(boxes) do
    for _, s in ipairs(starts) do
      sim.reset{ gps = false, turtle = { x = s[1], y = 31, z = s[2], h = 2, fuel = 5000 } }
      saveState(2)
      local nav, mine = require("bot.nav"), require("bot.mine")
      nav.init()
      local r = mine.mineBox({ x1 = b[1], y1 = b[2], z1 = b[3], x2 = b[4], y2 = b[5], z2 = b[6] })
      local tag = table.concat(b, ",") .. " from " .. s[1] .. "," .. s[2]
      truthy(r.ok, tag .. ": " .. tostring(r.error))
      local box = {}
      for x = math.min(b[1], b[4]), math.max(b[1], b[4]) do
        for y = math.min(b[2], b[5]), math.max(b[2], b[5]) do
          for z = math.min(b[3], b[6]), math.max(b[3], b[6]) do box[sim.key(x, y, z)] = true end
        end
      end
      for _, k in ipairs(sim.dugLog) do truthy(box[k], tag .. ": collateral dig at " .. k) end
      eq(#sim.dugLog, count(box), tag .. ": dug count")
      eq(sim.t.y, math.max(b[2], b[5]) + 1, tag .. ": end level")
    end
  end
end)

test("mineBox split: slices cover the box once, sorted turtles get sorted slices", function()
  sim.reset{}
  local split
  for _, s in ipairs(require("bot.skills").list) do if s.name == "mineBox" then split = s.split end end
  local parts = split({ x1 = 15, y1 = 28, z1 = 0, x2 = 0, y2 = 30, z2 = 5 },
    { { x = 100, y = 31, z = 0 }, { x = -50, y = 31, z = 0 }, { x = 7, y = 31, z = 0 } })
  eq(parts[2].x1, 0) eq(parts[2].x2, 4)
  eq(parts[3].x1, 5) eq(parts[3].x2, 9)
  eq(parts[1].x1, 10) eq(parts[1].x2, 15)
  for i = 1, 3 do eq(parts[i].z1, 0) eq(parts[i].z2, 5) eq(parts[i].y1, 28) eq(parts[i].y2, 30) end
  local few = split({ x1 = 0, y1 = 30, z1 = 0, x2 = 1, y2 = 30, z2 = 0 },
    { { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, { x = 2, y = 0, z = 0 } })
  truthy(few[1] and few[2], "two slices") eq(few[3], nil, "third turtle gets none")
end)

test("another turtle in the way: wait for it, never dig it, give up after a while", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 100 } }
  sim.set(0, 31, -2, "computercraft:turtle_normal")
  sim.onSleep = function() if sim.sleeps == 3 then sim.set(0, 31, -2, nil) end end
  saveState(0)
  local nav = require("bot.nav")
  nav.init()
  truthy(nav.goTo({ x = 0, y = 31, z = -4 }))
  eq(sim.t.z, -4) eq(#sim.dugLog, 0, "dug")
  sim.onSleep = nil
  sim.set(0, 31, -5, "computercraft:turtle_advanced")
  local before = sim.sleeps
  local ok, err = nav.goTo({ x = 0, y = 31, z = -8 })
  eq(ok, false) eq(err, "another turtle is in the way")
  eq(sim.sleeps - before, require("bot.config").turtleWaits, "waits")
end)

test("worker: status, plan with progress, busy, rejected plan, stop", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 2000 }, modem = true, id = 5, label = "miner-1" }
  local script = {
    { type = "hello" },
    { type = "plan", job = "j1", steps = { { skill = "mineArea", direction = "north", length = 3, width = 2, layers = 3 }, { skill = "goHome" } } },
    { type = "plan", job = "j2", steps = { { skill = "fly" } } },
    { type = "plan", job = "j3", steps = { { skill = "mineArea", direction = "south", length = 8, width = 8, layers = 3 } } },
  }
  sim.onSend = function(_, msg)
    if msg.type == "progress" and msg.job == "j1" and msg.step == 1 then
      sim.deliver(99, { type = "hello" })
      sim.deliver(99, { type = "plan", job = "jx", steps = { { skill = "goHome" } } })
    elseif msg.type == "progress" and msg.job == "j3" then
      sim.deliver(99, { type = "stop" })
    end
  end
  sim.onIdle = function()
    local m = table.remove(script, 1)
    if m then sim.deliver(99, m) end
    return m ~= nil
  end
  local _, ok, err = quietly(assert(loadfile(REPO .. "worker.lua")))
  eq(ok, false) eq(err, "SIM_IDLE")
  local seq = {}
  for _, s in ipairs(sim.sent) do
    eq(s.to, 99) eq(s.proto, "ccbrain")
    seq[#seq + 1] = s.msg.type .. ":" .. tostring(s.msg.job)
  end
  eq(table.concat(seq, " "), "status:nil accepted:j1 progress:j1 status:j1 result:jx progress:j1 result:j1"
    .. " result:j2 accepted:j3 progress:j3 result:j3")
  local function msg(i) return sim.sent[i].msg end
  eq(msg(1).label, "miner-1") eq(msg(1).pos.x, 0)
  truthy(msg(5).error:find("busy with job j1"), msg(5).error)
  eq(msg(7).ok, true) truthy(msg(7).summary:find("^Done: mineArea"), msg(7).summary)
  truthy(msg(8).error:find("plan rejected"), msg(8).error)
  eq(msg(11).ok, false) eq(msg(11).error, "stopped by the brain")
  -- the stop cut a command off mid-way: position and heading must still match the world
  eq(msg(11).pos.x, sim.t.x) eq(msg(11).pos.y, sim.t.y) eq(msg(11).pos.z, sim.t.z)
  eq(textutils.unserialiseJSON(sim.files["/nav_state.json"]).heading, sim.t.h, "saved heading")
end)

---------------------------------------------------------------- fleet: brain side, scripted turtles
-- fakes[id] = { label, pos, mode }; mode: nil (works), "fail", "busy" (never
-- finishes), "lost" (silent after the plan), "forget" (acts restarted).
local function fakeFleet(fakes)
  sim.modem = true
  sim.onSend = function(to, msg)
    local ids = {}
    if to == "broadcast" then
      for id in pairs(fakes) do ids[#ids + 1] = id end
      table.sort(ids)
    else
      ids[1] = to
    end
    for _, id in ipairs(ids) do
      local f = fakes[id]
      if f and not f.gone then
        if msg.type == "hello" then
          sim.deliver(id, { type = "status", label = f.label, state = "fuel 500", pos = f.pos, job = f.job })
        elseif msg.type == "plan" then
          sim.deliver(id, { type = "accepted", job = msg.job })
          f.steps, f.job = msg.steps, msg.job
          if f.mode == "lost" then
            f.gone = true
          elseif f.mode == "forget" then
            f.job = nil
          elseif f.mode ~= "busy" then
            for i, s in ipairs(msg.steps) do sim.deliver(id, { type = "progress", job = msg.job, step = i, text = s.skill }) end
            sim.deliver(id, f.mode == "fail"
              and { type = "result", job = msg.job, ok = false, error = "step 1 (mineBox) failed: bedrock",
                    completed = "nothing", failed = "mineBox mined=3", state = "fuel 400" }
              or { type = "result", job = msg.job, ok = true, summary = "Done: " .. #msg.steps .. " steps",
                   state = "fuel 300", pos = f.pos })
            f.job = nil
          end
        elseif msg.type == "stop" then
          f.stopped = true
        end
      end
    end
  end
end

test("fleet.lua: one LLM call, mineBox split between two turtles, other steps to both", function()
  sim.reset{}
  local fakes = { [7] = { label = "a", pos = { x = 0, y = 31, z = 0 } }, [8] = { label = "b", pos = { x = 30, y = 31, z = 0 } } }
  fakeFleet(fakes)
  local calls = fakeClient({ { plans = { { turtles = { 8, 7 }, steps = {
    { skill = "mineBox", x1 = 0, y1 = 28, z1 = 5, x2 = 15, y2 = 30, z2 = 10 }, { skill = "goHome" } } } } } })
  _G.write, _G.read = io.write, function() return "" end
  local out, ok, err = quietly(assert(loadfile(REPO .. "fleet.lua")), "dig", "the", "quarry")
  truthy(ok, tostring(err))
  eq(#calls, 1)
  local user = calls[1].messages[2].content
  truthy(user:find("#7 a: fuel 500", 1, true) and user:find("#8 b: fuel 500", 1, true), user)
  eq(fakes[7].steps[1].x1, 0) eq(fakes[7].steps[1].x2, 7)
  eq(fakes[8].steps[1].x1, 8) eq(fakes[8].steps[1].x2, 15)
  eq(fakes[7].steps[2].skill, "goHome") eq(fakes[8].steps[2].skill, "goHome")
  local text = table.concat(out, "\n")
  truthy(text:find("#7 Done: 2 steps", 1, true) and text:find("#8 Done: 2 steps", 1, true), text)
end)

test("fleet: a failed turtle sends every outcome and fresh state back to the model", function()
  sim.reset{}
  fakeFleet({ [7] = { label = "a", pos = { x = 0, y = 31, z = 0 } },
              [8] = { label = "b", pos = { x = 30, y = 31, z = 0 }, mode = "fail" } })
  local calls = fakeClient({ { plans = {
    { turtles = { 7 }, steps = { { skill = "goHome" } } },
    { turtles = { 8 }, steps = { { skill = "mineArea", direction = "north", length = 2, width = 2, layers = 2 } } } } },
    "Turtle 8 hit bedrock." })
  local fleet, skills = require("bot.fleet"), require("bot.skills")
  local tools = { runPlans = fleet.tool(skills.list, fleet.discover(2)) }
  local text, stats = require("llm.agent").run("go", tools, "sys")
  eq(text, "Turtle 8 hit bedrock.") eq(stats.turns, 2)
  local payload = textutils.unserialiseJSON(calls[2].messages[calls[2].n].content)
  eq(payload.ok, false) eq(payload.error, "1 of 2 turtles failed")
  truthy(payload.results:find("#7 Done: 1 steps", 1, true), payload.results)
  truthy(payload.results:find("#8 step 1 (mineBox) failed: bedrock; completed: nothing; mineBox mined=3", 1, true), payload.results)
  truthy(payload.state:find("#8 b: fuel 400", 1, true), payload.state)
end)

test("fleet: a silent turtle counts as lost, a restarted one as dropped", function()
  sim.reset{}
  fakeFleet({ [7] = { label = "a", pos = { x = 0, y = 31, z = 0 }, mode = "lost" },
              [8] = { label = "b", pos = { x = 9, y = 31, z = 0 }, mode = "forget" } })
  local fleet, skills = require("bot.fleet"), require("bot.skills")
  local r = fleet.tool(skills.list, fleet.discover(2)).handler({ plans = { { turtles = { 7, 8 }, steps = { { skill = "goHome" } } } } })
  eq(r.ok, false)
  truthy(r.results:find("#7 no answer for 60 s", 1, true), r.results)
  truthy(r.results:find("#8 turtle restarted or dropped the plan", 1, true), r.results)
  truthy(sim.now >= 60, "virtual time " .. sim.now)
end)

test("fleet: bad plans are rejected before anything is sent", function()
  sim.reset{}
  fakeFleet({ [7] = { label = "a", pos = { x = 0, y = 31, z = 0 } } })
  local fleet, skills = require("bot.fleet"), require("bot.skills")
  local tool = fleet.tool(skills.list, fleet.discover(2))
  local sentBefore = #sim.sent
  local function err(plans)
    local r = tool.handler({ plans = plans })
    eq(r.ok, false)
    return r.error
  end
  local home = { { skill = "goHome" } }
  truthy(err({}):find("non%-empty"))
  truthy(err({ { turtles = { 9 }, steps = home } }):find("no turtle #9", 1, true))
  truthy(err({ { turtles = { 7 }, steps = home }, { turtles = { 7 }, steps = home } }):find("more than one plan"))
  truthy(err({ { turtles = { 7 }, steps = { { skill = "fly" } } } }):find("plan 1: step 1: unknown skill fly", 1, true))
  eq(#sim.sent, sentBefore, "messages sent")
end)

test("fleet: Ctrl+T while waiting stops the turtles still working", function()
  sim.reset{}
  local fakes = { [7] = { label = "a", pos = { x = 0, y = 31, z = 0 }, mode = "busy" },
                  [8] = { label = "b", pos = { x = 9, y = 31, z = 0 } } }
  fakeFleet(fakes)
  local reply, pings = sim.onSend, 0
  sim.onSend = function(to, msg, proto)
    reply(to, msg, proto)
    if to == 7 and msg.type == "hello" then
      pings = pings + 1
      if pings == 2 then os.queueEvent("terminate") end
    end
  end
  local fleet, skills = require("bot.fleet"), require("bot.skills")
  local tool = fleet.tool(skills.list, fleet.discover(2))
  local ok, err = pcall(tool.handler, { plans = { { turtles = { 7, 8 }, steps = { { skill = "goHome" } } } } })
  eq(ok, false) eq(err, "Terminated")
  eq(fakes[7].stopped, true) eq(fakes[8].stopped, nil)
end)

print(("passed %d, failed %d"):format(passed, failed))
return failed > 0
