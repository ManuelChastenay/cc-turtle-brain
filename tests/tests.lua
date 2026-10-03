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
-- Non-junk items, so these exercise the trip home (junk has its own tests below).
local ORES = { "minecraft:iron_ore", "minecraft:copper_ore", "minecraft:gold_ore", "minecraft:lapis_ore", "minecraft:emerald_ore" }

test("full inventory: unloads into chest behind the start and resumes", function()
  local inv = {}
  for s = 1, 14 do inv[s] = { "minecraft:raw_iron", 64 } end
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000, inv = inv },
    terrain = function(x, y, z) if y <= 30 then return ORES[(x + y * 3 + z * 7) % 5 + 1] end end }
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
  for s = 1, 15 do inv[s] = { "minecraft:raw_iron", 64 } end
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
  for s = 1, 16 do inv[s] = { "minecraft:raw_iron", 64 } end
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000, inv = inv } }
  saveState(0)
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 3, width = 3, layers = 3, vertical = "down", side = "right" })
  eq(r.ok, false) truthy(r.error:find("cannot unload"), r.error)
  eq(sim.moves, 0)
end)

---------------------------------------------------------------- junk and fuel items
test("junk is dropped instead of a trip home; ores, fuel and look-alikes are kept", function()
  local inv = { [14] = { "create:andesite_alloy", 64 } }
  for s = 1, 13 do inv[s] = { "minecraft:cobblestone", 64 } end
  local function block(x, y, z)
    if y > 30 then return nil end
    local n = (x * 7 + y * 13 + z * 3) % 20
    return n == 0 and "minecraft:iron_ore" or n == 1 and "minecraft:coal_ore" or n < 10 and "minecraft:deepslate" or "minecraft:stone"
  end
  sim.reset{ gps = false, terrain = block, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000, inv = inv } }
  saveState(0) -- no chest anywhere: a trip home would fail
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 6, width = 6, layers = 9, vertical = "down", side = "right" })
  truthy(r.ok, tostring(r.error))
  eq(r.trips, 0) truthy(r.junked > 0, "junked " .. tostring(r.junked))
  eq(sim.lost, 0, "items lost")
  local iron, coal = 0, 0
  for k in pairs(boxCells({ x = 0, y = 31, z = 0 }, 0, 6, 6, 9, "down", "right")) do
    local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
    local b = block(tonumber(x), tonumber(y), tonumber(z))
    if b == "minecraft:iron_ore" then iron = iron + 1 elseif b == "minecraft:coal_ore" then coal = coal + 1 end
  end
  local held = {}
  for _, it in pairs(sim.t.inv) do held[it.name] = (held[it.name] or 0) + it.count end
  eq(held["minecraft:raw_iron"], iron, "raw iron kept")
  eq(held["minecraft:coal"], coal, "coal kept")
  eq(held["create:andesite_alloy"], 64, "andesite alloy kept")
  eq(sim.ground["create:andesite_alloy"], nil, "andesite alloy dropped")
  truthy((sim.ground["minecraft:cobblestone"] or 0) > 0, "cobblestone dropped")
end)

test("junk never goes into a chest next to the turtle", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500,
    inv = { { "minecraft:cobblestone", 64 }, { "minecraft:raw_iron", 3 } } } }
  sim.set(0, 32, 0, "minecraft:chest") -- above, where junk would go first
  saveState(0)
  local nav, inv = require("bot.nav"), require("bot.inv")
  nav.init()
  eq(inv.discardJunk(), 64)
  eq(#sim.chests[sim.key(0, 32, 0)].items, 0, "stacks in the chest")
  eq(sim.ground["minecraft:cobblestone"], 64)
  eq(sim.t.inv[2].count, 3, "raw iron kept")
end)

test("unloading keeps one stack of fuel and stores the rest", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500, inv = {
    { "minecraft:coal", 64 }, { "minecraft:coal", 64 }, { "minecraft:charcoal", 30 }, { "minecraft:raw_iron", 10 } } } }
  sim.set(0, 31, -1, "minecraft:chest")
  saveState(0)
  local nav, inv = require("bot.nav"), require("bot.inv")
  nav.init()
  local ok, moved = inv.unload()
  truthy(ok, tostring(moved)) eq(moved, 64 + 30 + 10)
  local kept = 0
  for _, it in pairs(sim.t.inv) do kept = kept + it.count end
  eq(kept, 64, "fuel items kept")
end)

test("unlimited fuel (need_fuel = false): jobs run and no fuel is kept back", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = "unlimited",
    inv = { { "minecraft:coal", 10 }, { "minecraft:raw_iron", 5 } } } }
  sim.set(0, 31, 1, "minecraft:chest")
  saveState(0)
  local nav, inv, mine, skills = require("bot.nav"), require("bot.inv"), require("bot.mine"), require("bot.skills")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 4, width = 4, layers = 3, vertical = "down", side = "right" })
  truthy(r.ok, tostring(r.error))
  truthy(skills.state():find("fuel unlimited", 1, true), skills.state())
  local ok, moved = inv.unload()
  truthy(ok, tostring(moved))
  eq(next(sim.t.inv), nil, "inventory empty")
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
  sim.set(0, 32, 0, "minecraft:stone") -- and above (below is ground): no room to step anywhere
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
  sim.set(0, 31, -5, "computercraft:turtle_advanced") -- a block whose id can't be read: coin flips
  local ok, err = nav.goTo({ x = 0, y = 31, z = -8 })
  eq(ok, false) eq(err, "turtle in the way for too long")
  eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, -4, "back on its path")
  eq(#sim.dugLog, 0, "dug")
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

---------------------------------------------------------------- turtles meeting (two turtles, one world)
-- a, b = { x, y, z, heading, id = n }. Main turtle (global APIs) is a, sim.spawn makes b.
local function twoTurtles(a, b, terrain)
  sim.reset{ gps = false, terrain = terrain, id = a.id or 1, turtle = { x = a[1], y = a[2], z = a[3], h = a[4], fuel = 500 } }
  saveState(a[4])
  local B = sim.spawn(b.id or 2, { x = b[1], y = b[2], z = b[3], h = b[4], fuel = 500 })
  B.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = b[1], y = b[2], z = b[3] }, heading = b[4] })
  local navA, navB = require("bot.nav"), B.require("bot.nav")
  navA.init()
  navB.init()
  return navA, navB, B
end

local function both(fa, fb)
  local ra, rb
  parallel.waitForAll(function() ra = table.pack(fa()) end, function() rb = table.pack(fb()) end)
  return ra, rb
end

local function solidExcept(air)
  return function(x, y, z) if not air(x, y, z) then return "minecraft:stone" end end
end

test("meeting head-on in the open: one steps aside, both arrive, nothing dug", function()
  local navA, navB, B = twoTurtles({ 0, 31, 0, 1 }, { 8, 31, 0, 3 })
  local ra, rb = both(function() return navA.goTo({ x = 8, y = 31, z = 0 }) end,
                      function() return navB.goTo({ x = 0, y = 31, z = 0 }) end)
  truthy(ra[1], "A: " .. tostring(ra[2])) truthy(rb[1], "B: " .. tostring(rb[2]))
  eq(sim.t.x, 8) eq(B.x, 0) eq(sim.t.y, 31) eq(B.y, 31)
  eq(#sim.dugLog, 0, "dug")
end)

test("meeting head-on in a 1-wide tunnel: one digs a 1-block nook, both arrive", function()
  local navA, navB, B = twoTurtles({ 0, 31, 0, 1 }, { 8, 31, 0, 3 },
    solidExcept(function(x, y, z) return y == 31 and z == 0 and x >= 0 and x <= 8 end))
  local ra, rb = both(function() return navA.goTo({ x = 8, y = 31, z = 0 }) end,
                      function() return navB.goTo({ x = 0, y = 31, z = 0 }) end)
  truthy(ra[1], "A: " .. tostring(ra[2])) truthy(rb[1], "B: " .. tostring(rb[2]))
  eq(sim.t.x, 8) eq(B.x, 0)
  truthy(#sim.dugLog <= 2, "dug " .. #sim.dugLog)
end)

test("meeting head-on vertically: one steps sideways, both arrive", function()
  local navA, navB, B = twoTurtles({ 0, 31, 0, 0 }, { 0, 38, 0, 0 })
  local ra, rb = both(function() return navA.goTo({ x = 0, y = 38, z = 0 }) end,
                      function() return navB.goTo({ x = 0, y = 31, z = 0 }) end)
  truthy(ra[1], "A: " .. tostring(ra[2])) truthy(rb[1], "B: " .. tostring(rb[2]))
  eq(sim.t.y, 38) eq(B.y, 31) eq(B.x, 0) eq(B.z, 0)
  eq(#sim.dugLog, 0, "dug")
end)

test("an idle turtle in the way is asked to move aside", function()
  local navA, navB, B = twoTurtles({ 0, 31, 0, 1, id = 5 }, { 4, 31, 0, 0 })
  local asked
  navA.onTurtleInWay = function(id)
    asked = id
    navB.makeWay(navA.pos()) -- what worker.lua does when it gets "makeway"
  end
  local ok, err = navA.goTo({ x = 8, y = 31, z = 0 })
  truthy(ok, tostring(err))
  eq(asked, 2) eq(sim.t.x, 8)
  truthy(B.y ~= 31 or B.z ~= 0, "B moved off the line")
  eq(#sim.dugLog, 0, "dug")
end)

test("a turtle that never moves: give up with its id, back on the path, nothing dug", function()
  local navA, _, B = twoTurtles({ 0, 31, 0, 1, id = 1 }, { 4, 31, 0, 0 })
  local ok, err = navA.goTo({ x = 8, y = 31, z = 0 })
  eq(ok, false) eq(err, "turtle #2 in the way for too long")
  eq(sim.t.x, 3) eq(sim.t.y, 31) eq(sim.t.z, 0) eq(B.x, 4)
  eq(#sim.dugLog, 0, "dug")
end)

test("mineArea waits for a turtle passing through a cell it digs above itself", function()
  sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500 } }
  saveState(0)
  local B = sim.spawn(2, { x = 0, y = 30, z = -2 }) -- top layer of the box, dug from below
  sim.onSleep = function() if sim.sleeps == 2 then B.x, B.y, B.z = 5, 31, 5 end end
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  local r = mine.mineArea({ direction = "north", length = 3, width = 1, layers = 3, vertical = "down", side = "right" })
  truthy(r.ok, tostring(r.error))
  for z = -3, -1 do for y = 28, 30 do eq(sim.get(0, y, z), nil, "box cell") end end
end)

test("two turtles crossing to their slices and back home both finish their mineBox", function()
  -- A starts at x=7 but digs the x=0..3 slice; B starts at x=0 and digs x=4..7: their paths cross
  local navA, navB, B = twoTurtles({ 7, 31, 0, 0 }, { 0, 31, 0, 0 })
  local mineA, mineB = require("bot.mine"), B.require("bot.mine")
  local ra, rb = both(function()
    local r = mineA.mineBox({ x1 = 0, y1 = 28, z1 = 3, x2 = 3, y2 = 30, z2 = 6 })
    if not r.ok then return r end
    local ok, err = navA.goTo(navA.home())
    return { ok = ok, error = err }
  end, function()
    local r = mineB.mineBox({ x1 = 4, y1 = 28, z1 = 3, x2 = 7, y2 = 30, z2 = 6 })
    if not r.ok then return r end
    local ok, err = navB.goTo(navB.home())
    return { ok = ok, error = err }
  end)
  truthy(ra[1].ok, "A: " .. tostring(ra[1].error)) truthy(rb[1].ok, "B: " .. tostring(rb[1].error))
  eq(sim.t.x, 7) eq(sim.t.z, 0) eq(B.x, 0) eq(B.z, 0)
  for x = 0, 7 do for y = 28, 30 do for z = 3, 6 do eq(sim.get(x, y, z), nil, "box cell") end end end
end)

test("worker: moves aside on makeway when idle, ignores it when busy", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 2000 }, modem = true, id = 5 }
  local nav = require("bot.nav") -- the same module worker.lua will get
  local makeWay, calls = nav.makeWay, 0
  nav.makeWay = function(...) calls = calls + 1 return makeWay(...) end
  local stage, aside = 0, nil
  sim.onIdle = function()
    stage = stage + 1
    if stage == 1 then -- idle: a turtle south of it wants to come through along z
      sim.deliver(9, { type = "makeway", from = { x = 0, y = 31, z = 1 } })
    elseif stage == 2 then
      aside = { x = sim.t.x, y = sim.t.y, z = sim.t.z }
      sim.deliver(9, { type = "plan", job = "j1", steps = { { skill = "move", direction = "east", blocks = 3 } } })
    end
    return stage <= 2
  end
  sim.onSend = function(_, msg) -- busy: a makeway arrives while it travels
    if msg.type == "progress" then
      sim.deliver(9, { type = "makeway", from = { x = sim.t.x, y = sim.t.y, z = sim.t.z + 1 } })
    end
  end
  local _, _, err = quietly(assert(loadfile(REPO .. "worker.lua")))
  eq(err, "SIM_IDLE")
  eq(calls, 1, "makeWay calls")
  eq(aside.z, 0) truthy(aside.x ~= 0 or aside.y ~= 31, "stepped off the z line")
  local result = sim.sent[#sim.sent].msg
  eq(result.type, "result") eq(result.ok, true, tostring(result.error))
  eq(sim.t.x, aside.x + 3, "travelled undisturbed")
end)

---------------------------------------------------------------- fleet: brain side, scripted turtles
-- fakes[id] = { label, pos, mode, job, kept, silentUntil, finishAfter }; mode: nil
-- (works), "fail", "busy" (never finishes), "lost" (silent after the plan),
-- "forget" (acts restarted). job = a job it is running, kept = a result it
-- holds until acked, silentUntil = ignores everything until that virtual
-- time, finishAfter = finishes `job` after answering that many pings.
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
      if f and not f.gone and not (f.silentUntil and sim.now < f.silentUntil) then
        if msg.type == "hello" then
          f.pings = (f.pings or 0) + 1
          sim.deliver(id, { type = "status", label = f.label, state = "fuel 500", pos = f.pos, job = f.job,
                            result = not f.job and f.kept or nil })
          if f.job and f.finishAfter and f.pings >= f.finishAfter then
            f.kept = { type = "result", job = f.job, ok = true, summary = "Done: late", state = "fuel 200", pos = f.pos }
            f.job = nil
            sim.deliver(id, f.kept)
          end
        elseif msg.type == "ack" then
          f.acked = msg.job
          if f.kept and f.kept.job == msg.job then f.kept = nil end
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
  local silent
  local tool = fleet.tool(skills.list, fleet.discover(2), function(id, msg) if msg.type == "silent" then silent = id end end)
  local r = tool.handler({ plans = { { turtles = { 7, 8 }, steps = { { skill = "goHome" } } } } })
  eq(r.ok, false)
  truthy(r.results:find("#7 no answer for 600 s", 1, true), r.results)
  truthy(r.results:find("#8 turtle restarted without its job", 1, true), r.results)
  eq(silent, 7, "warned about the silent turtle")
  truthy(sim.now >= 600, "virtual time " .. sim.now)
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
  eq(sim.files["/fleet_job.json"], nil, "saved job cleared")
end)

---------------------------------------------------------------- resume after reboots
-- Runs worker.lua until it ends, rebooting it whenever it dies with "Terminated"
-- (raised by sim.terminateAtAction or sim.onMove). nextGap(n) gives the turtle
-- actions (moves, turns, digs...) until the next reboot after reboot n (nil:
-- no more reboots).
local function runWorkerWithReboots(nextGap)
  local reboots, err, first = 0, nil, nextGap(0)
  sim.terminateAtAction = first and sim.actions + first
  repeat
    local _
    _, _, err = quietly(assert(loadfile(REPO .. "worker.lua")))
    if err == "Terminated" then
      reboots = reboots + 1
      sim.reboot()
      local gap = nextGap(reboots)
      sim.terminateAtAction = gap and sim.actions + gap
    end
  until err ~= "Terminated" or reboots > 300
  return reboots, err
end

local function lastResult()
  for i = #sim.sent, 1, -1 do
    if sim.sent[i].msg.type == "result" then return sim.sent[i].msg end
  end
end

test("worker: a job survives reboots at any point and digs exactly the box", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 1, fuel = 5000 }, modem = true, id = 5 }
  local sent = false
  sim.onIdle = function()
    if sent then return false end
    sent = true
    sim.deliver(99, { type = "plan", job = "j1", steps = {
      { skill = "mineArea", direction = "north", length = 5, width = 4, layers = 7 },
      { skill = "move", direction = "left", blocks = 2 } } })
    return true
  end
  local reboots, err = runWorkerWithReboots(function(n) return n < 40 and 5 + (n * 7) % 13 or nil end)
  eq(err, "SIM_IDLE")
  truthy(reboots >= 5, "reboots " .. reboots)
  local result = lastResult()
  eq(result.job, "j1") eq(result.ok, true, tostring(result.error))
  -- the box is north (z -1..-5), east of the start (x 0..3), y 30..24
  local box = boxCells({ x = 0, y = 31, z = 0 }, 0, 5, 4, 7, "down", "right")
  for k in pairs(box) do eq(sim.get(k:match("(-?%d+),(-?%d+),(-?%d+)")), nil, "box cell " .. k) end
  for _, k in ipairs(sim.dugLog) do truthy(box[k], "collateral dig at " .. k) end
  -- "left" was north once the dig ended facing east: 2 blocks north of the start, not more
  eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, -2)
  eq(sim.files["/job.json"], nil, "job file")
end)

test("mineArea resumed from one block beside its box steps back in, no digging outside", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 2000 } }
  local args = { direction = "north", length = 4, width = 3, layers = 6, vertical = "down", side = "right" }
  local box = boxCells({ x = 0, y = 31, z = 0 }, 0, 4, 3, 6, "down", "right") -- x 0..2, z -1..-4, y 30..25
  local nav, mine = require("bot.nav"), require("bot.mine")
  nav.init()
  -- cut off just after the first 3 layers: the next cell is 3 layers lower
  local saved
  local ok, err = pcall(mine.mineArea, args, { save = function(s)
    saved = s
    if s.next == 13 then error("Terminated", 0) end
  end })
  eq(ok, false) eq(err, "Terminated")
  local p = sim.t
  truthy(box[sim.key(p.x, p.y, p.z)], ("cut off inside the box, at %d,%d,%d"):format(p.x, p.y, p.z))
  -- it had stepped aside, out through the box wall, to let a turtle by
  local outside
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    if not outside and not box[sim.key(p.x + d[1], p.y, p.z + d[2])] then outside = { x = p.x + d[1], z = p.z + d[2] } end
  end
  truthy(outside, "a wall next to the turtle")
  sim.set(outside.x, p.y, outside.z, nil)
  p.x, p.z = outside.x, outside.z
  sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = p.x, y = p.y, z = p.z }, heading = p.h })
  sim.reboot()
  nav, mine = require("bot.nav"), require("bot.mine")
  nav.init(true)
  local r = mine.mineArea(args, { state = saved, save = function(s) saved = s end })
  truthy(r.ok, tostring(r.error))
  for k in pairs(box) do eq(sim.get(k:match("(-?%d+),(-?%d+),(-?%d+)")), nil, "box cell " .. k) end
  for _, k in ipairs(sim.dugLog) do truthy(box[k], "collateral dig at " .. k) end
  eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0) eq(sim.t.h, 0)
end)

test("nav: sealed in after a turn was cut off, it refuses to trust the saved heading", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 1, fuel = 100 } }
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do sim.set(d[1], 31, d[2], "minecraft:stone") end
  sim.set(0, 32, 0, "minecraft:stone")
  sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = 0, y = 31, z = 0 }, heading = 0, turning = true })
  local nav = require("bot.nav")
  nav.init()
  eq(nav.heading(), nil)
  eq(#sim.dugLog, 0, "dug")
end)

test("nav: calibrations cut off while climbing a shaft are undone from the first one's level", function()
  -- a shaft at x=0,z=0 from y=31 to 35, with a side opening only at y=31
  local function terrain(x, y, z)
    if x == 0 and z == 0 and y >= 31 and y <= 35 then return nil end
    if x == 1 and z == 0 and y == 31 then return nil end
    return "minecraft:stone"
  end
  sim.reset{ terrain = terrain, turtle = { x = 0, y = 34, z = 0, h = 2, fuel = 100 } }
  sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = 0, y = 34, z = 0 }, heading = 3,
    calibrating = { pos = { x = 0, y = 31, z = 0 }, heading = 3 } })
  local nav = require("bot.nav")
  nav.init()
  eq(nav.heading(), 3) eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0) eq(sim.t.h, 3)
  eq(#sim.dugLog, 0, "dug")
end)

test("worker: a reboot on the way to unload resumes the trip and the dig", function()
  local inv = {}
  for s = 1, 14 do inv[s] = { "minecraft:raw_iron", 64 } end
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 5000, inv = inv }, modem = true, id = 5,
    terrain = function(x, y, z) if y <= 30 then return ORES[(x + y * 3 + z * 7) % 5 + 1] end end }
  sim.set(0, 31, 11, "minecraft:chest") -- home is 10 blocks south, chest beyond it
  sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = 0, y = 31, z = 0 }, heading = 0,
    home = { x = 0, y = 31, z = 10, heading = 2 } })
  local sent, tripped = false, false
  sim.onIdle = function()
    if sent then return false end
    sent = true
    sim.deliver(99, { type = "plan", job = "j2", steps = { { skill = "mineArea", direction = "north", length = 4, width = 4, layers = 6 } } })
    return true
  end
  sim.onMove = function(t)
    if not tripped and t.x == 0 and t.z == 5 then tripped = true error("Terminated", 0) end -- halfway home
  end
  local reboots, err = runWorkerWithReboots(function() return nil end)
  eq(err, "SIM_IDLE") eq(reboots, 1) truthy(tripped, "rebooted on the trip")
  local result = lastResult()
  eq(result.ok, true, tostring(result.error))
  truthy(#sim.chests[sim.key(0, 31, 11)].items >= 14, "chest got the load")
  eq(sim.lost, 0, "items lost")
  local box = boxCells({ x = 0, y = 31, z = 0 }, 0, 4, 4, 6, "down", "right")
  for k in pairs(box) do eq(sim.get(k:match("(-?%d+),(-?%d+),(-?%d+)")), nil, "box cell " .. k) end
  for _, k in ipairs(sim.dugLog) do truthy(box[k], "collateral dig at " .. k) end
  eq(sim.t.x, 0) eq(sim.t.z, 0)
end)

test("nav: a reboot in the middle of calibrating is undone at the next start", function()
  -- rebootAt: moves (counted from the start of each run) at which a run is cut off
  local function scenario(blocked, rebootAt)
    sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 1, fuel = 100 } }
    for _, b in ipairs(blocked) do sim.set(b[1], 31, b[2], "minecraft:stone") end
    sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = 0, y = 31, z = 0 }, heading = 1 })
    for _, n in ipairs(rebootAt) do
      sim.terminateAtMove = sim.moves + n
      local ok, err = pcall(function() require("bot.nav").init() end)
      eq(ok, false) eq(err, "Terminated")
      sim.reboot()
    end
    local nav = require("bot.nav")
    nav.init()
    eq(sim.t.x, 0) eq(sim.t.z, 0) eq(sim.t.h, 1, "facing")
    eq(nav.pos().x, 0) eq(nav.pos().z, 0) eq(nav.heading(), 1)
    eq(textutils.unserialiseJSON(sim.files["/nav_state.json"]).calibrating, nil, "marker cleared")
  end
  scenario({}, { 1 })                         -- stepped forward, rebooted before stepping back
  scenario({ { 1, 0 }, { -1, 0 } }, { 1 })    -- had to turn first: displaced and turned
  scenario({}, { 1, 3 })                      -- rebooted again while going back
  scenario({ { 1, 0 }, { -1, 0 } }, { 1, 2, 3 })  -- and once more, mid-way back
end)

test("nav: walled in, it measures its heading one block up; sealed in after a cut-off calibration, it refuses to guess", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 3, fuel = 100 } }
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do sim.set(d[1], 31, d[2], "minecraft:stone") end
  local nav = require("bot.nav")
  nav.init() -- no saved state: only measuring can tell
  eq(nav.heading(), 3) eq(sim.t.y, 31, "back down") eq(sim.t.h, 3)
  -- now sealed (above too), and the last calibration was cut off after a turn
  sim.set(0, 32, 0, "minecraft:stone")
  sim.t.h = 0
  sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = 0, y = 31, z = 0 }, heading = 3,
    calibrating = { pos = { x = 0, y = 31, z = 0 }, heading = 3 } })
  sim.reboot()
  nav = require("bot.nav")
  local moves = sim.moves
  nav.init()
  eq(nav.heading(), nil, "heading")
  eq(sim.moves, moves, "moved") eq(#sim.dugLog, 0, "dug")
  local ok, err = nav.goTo({ x = 5, y = 31, z = 0 })
  eq(ok, false) truthy(err:find("heading unknown", 1, true), err)
end)

test("worker: 30 random jobs, rebooted at random actions, end exactly as without reboots", function()
  local NAMES = { [0] = "north", "east", "south", "west" }
  local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
  for seed = 1, 30 do
    math.randomseed(seed)
    local h0, hd = math.random(0, 3), math.random(0, 3)
    local L, W, N = math.random(1, 6), math.random(1, 5), math.random(1, 8)
    local vertical = math.random(2) == 1 and "down" or "up"
    local side = ({ "right", "left", "center" })[math.random(3)]
    -- "up" digs start at the turtle's level: dig them inside a hill, from a 3x3x2 pocket
    local terrain = function(x, y, z)
      local pocket = math.abs(x) <= 1 and math.abs(z) <= 1 and y <= 32
      if y <= 30 or (vertical == "up" and y <= 45 and not pocket) then return "minecraft:stone" end
    end
    sim.reset{ terrain = terrain, turtle = { x = 0, y = 31, z = 0, h = h0, fuel = 5000 }, modem = true, id = 5 }
    sim.files["/nav_state.json"] = textutils.serialiseJSON({ pos = { x = 0, y = 31, z = 0 }, heading = h0 })
    local sent = false
    sim.onIdle = function()
      if sent then return false end
      sent = true
      sim.deliver(99, { type = "plan", job = "s", steps = {
        { skill = "mineArea", direction = NAMES[hd], length = L, width = W, layers = N, vertical = vertical, side = side },
        { skill = "move", direction = "left", blocks = 2 }, { skill = "face", direction = "right" } } })
      return true
    end
    local _, err = runWorkerWithReboots(function(n) return n < 60 and math.random(1, 25) or nil end)
    local tag = ("seed %d (%s %s %s %dx%dx%d)"):format(seed, NAMES[hd], vertical, side, L, W, N)
    eq(err, "SIM_IDLE", tag)
    local result = lastResult()
    eq(result.ok, true, tag .. ": " .. tostring(result.error))
    local box = boxCells({ x = 0, y = 31, z = 0 }, hd, L, W, N, vertical, side)
    local here = sim.key(sim.t.x, sim.t.y, sim.t.z)
    for k in pairs(box) do
      local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
      truthy(k == here or not sim.get(tonumber(x), tonumber(y), tonumber(z)), tag .. ": undug " .. k)
    end
    -- after the dig it faces h0 at the start; "left" is h0 - 1, then "right" turns back to h0
    local hl = (h0 + 3) % 4
    local allowed = { [sim.key(DX[hd], 31, DZ[hd])] = true } -- the door when digging down
    for k = 1, 2 do allowed[sim.key(k * DX[hl], 31, k * DZ[hl])] = true end -- the move's path
    for _, k in ipairs(sim.dugLog) do truthy(box[k] or allowed[k], tag .. ": collateral dig at " .. k) end
    eq(sim.t.x, 2 * DX[hl], tag) eq(sim.t.y, 31, tag) eq(sim.t.z, 2 * DZ[hl], tag) eq(sim.t.h, h0, tag .. ": facing")
  end
end)

test("worker: keeps its result until the brain acks it; reports a job it cannot resume", function()
  sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500 }, modem = true, id = 5 }
  local script = {
    { type = "plan", job = "j1", steps = { { skill = "face", direction = "east" } } },
    { type = "hello" }, { type = "ack", job = "j1" }, { type = "hello" },
  }
  sim.onIdle = function()
    local m = table.remove(script, 1)
    if m then sim.deliver(99, m) end
    return m ~= nil
  end
  local _, _, err = quietly(assert(loadfile(REPO .. "worker.lua")))
  eq(err, "SIM_IDLE")
  local statuses = {}
  for _, s in ipairs(sim.sent) do if s.msg.type == "status" then statuses[#statuses + 1] = s.msg end end
  eq(statuses[1].result.job, "j1") eq(statuses[1].result.ok, true)
  eq(statuses[2].result, nil, "result after ack")
  -- a saved job naming a skill this code does not have
  sim.reboot()
  sim.files["/job.json"] = textutils.serialiseJSON({ id = "j9", boss = 99, steps = { { skill = "fly" } }, step = 1, results = {} })
  script = { { type = "hello" } }
  quietly(assert(loadfile(REPO .. "worker.lua")))
  local status = sim.sent[#sim.sent].msg
  eq(status.job, nil) eq(status.result.job, "j9")
  truthy(status.result.error:find("could not resume", 1, true), status.result.error)
end)

test("fleet: the job is saved before plans go out, and cleared once done", function()
  sim.reset{}
  local fakes = { [7] = { label = "a", pos = { x = 0, y = 31, z = 0 } } }
  fakeFleet(fakes)
  local reply, savedAtSend = sim.onSend, nil
  sim.onSend = function(to, msg, proto)
    if msg.type == "plan" then savedAtSend = textutils.unserialiseJSON(sim.files["/fleet_job.json"] or "null") end
    reply(to, msg, proto)
  end
  local calls = fakeClient({ { plans = { { turtles = { 7 }, steps = { { skill = "goHome" } } } } } })
  local _, ok, err = quietly(assert(loadfile(REPO .. "fleet.lua")), "come", "home")
  truthy(ok, tostring(err)) eq(#calls, 1)
  truthy(savedAtSend, "saved before sending")
  eq(savedAtSend.goal, "come home") eq(savedAtSend.pending[1], 7)
  eq(fakes[7].acked, savedAtSend.job, "result acked")
  eq(sim.files["/fleet_job.json"], nil, "cleared after the run")
end)

test("fleet resume: collects results turtles kept while the brain was down, no LLM call", function()
  sim.reset{}
  local fakes = {
    [7] = { label = "a", pos = { x = 0, y = 31, z = 0 },
            kept = { type = "result", job = "1-5", ok = true, summary = "Done: mineBox mined=40", state = "fuel 100" } },
    [8] = { label = "b", pos = { x = 9, y = 31, z = 0 }, job = "1-5", finishAfter = 2 },
  }
  fakeFleet(fakes)
  sim.files["/fleet_job.json"] = textutils.serialiseJSON({ goal = "dig the quarry", job = "1-5", pending = { 7, 8 }, results = {} })
  local calls = fakeClient({})
  local out, ok, err = quietly(assert(loadfile(REPO .. "fleet.lua")), "resume")
  truthy(ok, tostring(err))
  eq(#calls, 0, "LLM calls")
  local text = table.concat(out, "\n")
  truthy(text:find("#7 Done: mineBox mined=40", 1, true) and text:find("#8 Done: late", 1, true), text)
  eq(fakes[7].acked, "1-5") eq(fakes[8].acked, "1-5")
  eq(sim.files["/fleet_job.json"], nil, "cleared")
end)

test("fleet resume: a failure while the brain was down gets one LLM call with the outcome", function()
  sim.reset{}
  fakeFleet({ [7] = { label = "a", pos = { x = 0, y = 31, z = 0 },
    kept = { type = "result", job = "1-6", ok = false, error = "step 1 (mineBox) failed: bedrock", completed = "nothing" } } })
  sim.files["/fleet_job.json"] = textutils.serialiseJSON({ goal = "dig the quarry", job = "1-6", pending = { 7 }, results = {} })
  local calls = fakeClient({ "Turtle 7 hit bedrock, nothing else to dig." })
  local out, ok, err = quietly(assert(loadfile(REPO .. "fleet.lua")), "resume")
  truthy(ok, tostring(err))
  eq(#calls, 1)
  local user = calls[1].messages[2].content
  truthy(user:find("dig the quarry", 1, true) and user:find("interrupted", 1, true)
    and user:find("#7 step 1 (mineBox) failed: bedrock", 1, true), user)
  truthy(table.concat(out, "\n"):find("Turtle 7 hit bedrock", 1, true))
end)

test("fleet resume with nothing saved does nothing", function()
  sim.reset{}
  fakeFleet({ [7] = { label = "a", pos = { x = 0, y = 31, z = 0 } } })
  local calls = fakeClient({})
  local out, ok, err = quietly(assert(loadfile(REPO .. "fleet.lua")), "resume")
  truthy(ok, tostring(err)) eq(#calls, 0)
  eq(out[1], "Nothing to resume.")
end)

test("fleet: a turtle silent for two minutes that comes back is waited for", function()
  sim.reset{}
  local fakes = { [7] = { label = "a", pos = { x = 0, y = 31, z = 0 }, job = "j", silentUntil = 130, finishAfter = 1 } }
  fakeFleet(fakes)
  local fleet = require("bot.fleet")
  local events = {}
  local run = { goal = "g", job = "j", pending = { [7] = true }, results = {} }
  local results = fleet.wait(run, { [7] = { label = "a", state = "?" } }, function(id, msg) events[#events + 1] = msg.type or "result" end)
  eq(results[7].ok, true, tostring(results[7].error))
  truthy(sim.now >= 130 and sim.now < 600, "virtual time " .. sim.now)
  eq(events[1], "silent")
end)

print(("passed %d, failed %d"):format(passed, failed))
return failed > 0
