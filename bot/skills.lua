--[[ <Claude>
  Skills the planner can put in a plan. Each is declared once:
    { name, doc, args = { { argName, type, default } }, run = function(args, ctx) -> result,
      split = function(args, positions) -> argsPerTurtle }   -- optional, fleet only
  An arg with a default is optional; types are listed in bot/plan.lua.
  run returns { ok = true, ... } or { ok = false, error = "..." }; extra
  scalar fields show up in the run summary. A worker can reboot in the
  middle of a step and run it again: ctx.state is what the step last passed
  to ctx.save (nil on a fresh start), so a step must either be safe to
  repeat or save enough to carry on. split divides one step between
  the turtles of a fleet group (see bot/fleet.lua). Keep docs short: they
  are sent with every LLM call.
]]

-- <Claude> Turtle modules load on first use, so the fleet brain (a computer,
-- no turtle API) can read the declarations and split functions.
local function lazy(name)
  return setmetatable({}, { __index = function(_, key) return require(name)[key] end })
end
local nav, inv, mine = lazy("bot.nav"), lazy("bot.inv"), lazy("bot.mine")

local M = {}

local function fail(err) return { ok = false, error = err } end

-- <Claude> Slices a mineBox along its longer side, one slice per turtle (fewer
-- if the box is narrower than the group). Turtles sorted along that side get
-- the slices in the same order, so each starts near its own. Runs on the brain.
local function splitBox(a, positions)
  local alongX = math.abs(a.x2 - a.x1) >= math.abs(a.z2 - a.z1)
  local axis, k1, k2 = alongX and "x" or "z", alongX and "x1" or "z1", alongX and "x2" or "z2"
  local lo, hi = math.min(a[k1], a[k2]), math.max(a[k1], a[k2])
  local size = hi - lo + 1
  local n = math.min(#positions, size)
  local order = {}
  for i = 1, #positions do order[i] = i end
  table.sort(order, function(i, j)
    local pi, pj = positions[i][axis], positions[j][axis]
    return pi < pj or (pi == pj and i < j)
  end)
  local parts = {}
  for k = 1, n do
    local part = {}
    for key, value in pairs(a) do part[key] = value end
    part[k1], part[k2] = lo + math.floor((k - 1) * size / n), lo + math.floor(k * size / n) - 1
    parts[order[k]] = part
  end
  return parts
end

-- <Claude> Refuels from the inventory for the whole trip before moving.
-- Junk from digging through obstacles on the way is dropped on arrival.
local function travel(target)
  local need = nav.distance(nav.pos(), target)
  if not nav.refuel(need) then return fail(("needs %d fuel, has %d"):format(need, nav.fuel())) end
  local dug = nav.dug
  local ok, err = nav.goTo(target)
  if nav.dug > dug then inv.discardJunk() end
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
    run = function(a, ctx) return mine.mineArea(a, ctx) end,
  },
  {
    name = "mineBox",
    doc = "Dig out the box between two corners (world coordinates, all blocks included)."
      .. " Enters from above its nearest top corner and ends there.",
    args = { { "x1", "int" }, { "y1", "int" }, { "z1", "int" }, { "x2", "int" }, { "y2", "int" }, { "z2", "int" } },
    run = function(a, ctx) return mine.mineBox(a, ctx) end,
    split = splitBox,
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
    -- <Claude> The target is saved first: after a reboot, "3 blocks left"
    -- must not be counted again from wherever the turtle stopped.
    run = function(a, ctx)
      local target = ctx.state and ctx.state.target
      if not target then
        target = nav.pos()
        if a.direction == "up" or a.direction == "down" then
          target.y = target.y + (a.direction == "up" and a.blocks or -a.blocks)
        else
          local h, err = nav.resolve(a.direction)
          if not h then return fail(err) end
          local dx, dz = nav.vector(h)
          target.x, target.z = target.x + dx * a.blocks, target.z + dz * a.blocks
        end
        ctx.save({ target = target })
      end
      return travel(target)
    end,
  },
  {
    name = "face",
    doc = "Turn toward a direction.",
    args = { { "direction", "dir" } },
    run = function(a, ctx)
      local h = ctx.state and ctx.state.h
      if not h then
        local err
        h, err = nav.resolve(a.direction)
        if not h then return fail(err) end
        ctx.save({ h = h })
      end
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
    doc = "Put everything into a chest next to the turtle (burns what burns first, keeps some fuel).",
    run = function()
      local ok, moved, junked = inv.unload()
      if not ok then return fail(moved) end
      local fuel = nav.fuel()
      return { ok = true, items = moved, junked = junked, fuel = fuel ~= math.huge and fuel or nil }
    end,
  },
  {
    name = "refuel",
    doc = "Burn everything in the inventory that burns, up to the fuel limit.",
    run = function()
      if nav.fuel() == math.huge then return { ok = true } end
      local gained = nav.refuelAll()
      if gained == 0 and nav.fuel() < turtle.getFuelLimit() then
        return fail(("nothing in the inventory burns (fuel %d)"):format(nav.fuel()))
      end
      return { ok = true, fuel = nav.fuel(), gained = gained }
    end,
  },
}

-- <Claude> One line the LLM reads instead of calling status tools.
function M.state()
  local fuel = nav.fuel()
  return ("%s; fuel %s; %s"):format(nav.describe(), fuel == math.huge and "unlimited" or tostring(fuel), inv.summary())
end

return M
