--[[ <Claude>
  Skills the planner can put in a plan. Each is declared once:
    { name, doc, args = { { argName, type, default } }, run = function(args) -> result }
  An arg with a default is optional; types are listed in bot/plan.lua.
  run returns { ok = true, ... } or { ok = false, error = "..." }; extra
  scalar fields show up in the run summary. Keep docs short: they are sent
  with every LLM call.
]]
local nav = require("bot.nav")
local inv = require("bot.inv")
local mine = require("bot.mine")

local M = {}

local function fail(err) return { ok = false, error = err } end

-- <Claude> Refuels from the inventory for the whole trip before moving.
local function travel(target)
  local need = nav.distance(nav.pos(), target)
  if not nav.refuel(need) then return fail(("needs %d fuel, has %d"):format(need, nav.fuel())) end
  local ok, err = nav.goTo(target)
  if not ok then return fail(err) end
  return { ok = true }
end

M.list = {
  {
    name = "mineArea",
    doc = "Dig out a box, then return to the start. The box begins 1 block toward direction and is"
      .. " length blocks that way, width blocks toward side, and layers deep: vertical=down starts"
      .. " below the turtle's level (a pit), up starts at its level (a room or tunnel)."
      .. " \"6x6 area 3 deep north\" = north, 6, 6, 3.",
    args = {
      { "direction", "dir" }, { "length", "count" }, { "width", "count" }, { "layers", "count" },
      { "vertical", "down|up", "down" }, { "side", "right|left|center", "right" },
    },
    run = mine.mineArea,
  },
  {
    name = "goTo",
    doc = "Travel to coordinates.",
    args = { { "x", "int" }, { "y", "int" }, { "z", "int" } },
    run = travel,
  },
  {
    name = "move",
    doc = "Travel some blocks in a direction.",
    args = { { "direction", "dir|up|down" }, { "blocks", "count", 1 } },
    run = function(a)
      local target = nav.pos()
      if a.direction == "up" or a.direction == "down" then
        target.y = target.y + (a.direction == "up" and a.blocks or -a.blocks)
      else
        local h, err = nav.resolve(a.direction)
        if not h then return fail(err) end
        local dx, dz = nav.vector(h)
        target.x, target.z = target.x + dx * a.blocks, target.z + dz * a.blocks
      end
      return travel(target)
    end,
  },
  {
    name = "face",
    doc = "Turn toward a direction.",
    args = { { "direction", "dir" } },
    run = function(a)
      local h, err = nav.resolve(a.direction)
      if not h then return fail(err) end
      local ok, turnErr = nav.face(h)
      return ok and { ok = true } or fail(turnErr)
    end,
  },
  {
    name = "goHome",
    doc = "Travel home and face the way it was saved.",
    run = function()
      local home = nav.home()
      if not home then return fail("no home set") end
      local result = travel(home)
      if result.ok and home.heading then nav.face(home.heading) end
      return result
    end,
  },
  {
    name = "setHome",
    doc = "Make the current position and facing home.",
    run = function()
      nav.setHome()
      return { ok = true }
    end,
  },
  {
    name = "unload",
    doc = "Put everything except fuel into a chest next to the turtle.",
    run = function()
      local ok, moved = inv.unload()
      return ok and { ok = true, items = moved } or fail(moved)
    end,
  },
  {
    name = "refuel",
    doc = "Burn every fuel item in the inventory.",
    run = function()
      local before = nav.fuel()
      if before == math.huge then return { ok = true } end
      nav.refuel(math.huge)
      if nav.fuel() == before then return fail("no fuel items in the inventory") end
      return { ok = true, fuel = nav.fuel() }
    end,
  },
}

-- <Claude> One line the LLM reads instead of calling status tools.
function M.state()
  local fuel = nav.fuel()
  return ("%s; fuel %s; %s"):format(nav.describe(), fuel == math.huge and "unlimited" or tostring(fuel), inv.summary())
end

return M
