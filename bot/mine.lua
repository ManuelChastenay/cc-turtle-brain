--[[ <Claude>
  mineArea: digs out a box next to the turtle and comes back to the start.
  Local frame: a = blocks ahead (toward direction), r = blocks to the right,
  l = layers above the start level. Layers are taken three at a time: the
  turtle walks the middle one and digs up and down, so a 3-deep area costs
  one pass of fuel. Every move stays inside the box, except the first step
  in "down" mode (the block above the box, in front of the turtle).
  When the inventory fills, it unloads into a chest next to the start or at
  home, then resumes.
]]
local nav = require("bot.nav")
local inv = require("bot.inv")
local config = require("bot.config")

local M = {}

local ORIGIN = { a = 0, r = 0, l = 0 }

local function dist(p, q)
  return math.abs(p.a - q.a) + math.abs(p.r - q.r) + math.abs(p.l - q.l)
end

local function check(ok, err)
  if not ok then error(err, 0) end
end

-- <Claude> Cells to walk, in order: a serpentine per layer group, reversed
-- every other group so each group starts above or below where the last ended.
local function visits(length, rows, layers)
  local list = {}
  for g = 1, #layers, 3 do
    local n, group = math.min(3, #layers - g + 1), {}
    for i = g, g + n - 1 do group[layers[i]] = true end
    local walk = layers[n == 3 and g + 1 or g]
    local cells = {}
    for k, r in ipairs(rows) do
      for i = 1, length do
        local a = k % 2 == 1 and i or length + 1 - i
        cells[#cells + 1] = { a = a, r = r, l = walk, up = group[walk + 1], down = group[walk - 1] }
      end
    end
    local reverse = (g - 1) / 3 % 2 == 1
    for i = 1, #cells do list[#list + 1] = cells[reverse and #cells + 1 - i or i] end
  end
  return list
end

-- <Claude> args: direction, length, width, layers, vertical ("down"|"up"), side ("right"|"left"|"center").
function M.mineArea(args)
  local h, err = nav.resolve(args.direction)
  if not h then return { ok = false, error = err } end
  local startHeading, origin = nav.heading(), nav.pos()
  if not startHeading then return { ok = false, error = "heading unknown (no GPS fix to calibrate it)" } end

  local fx, fz = nav.vector(h)
  local rx, rz = nav.vector((h + 1) % 4)
  local axes = { a = fx ~= 0 and "x" or "z", r = rx ~= 0 and "x" or "z", l = "y" }

  local rows, first = {}, ({ right = 0, left = 0, center = -math.floor((args.width - 1) / 2) })[args.side]
  for k = 1, args.width do rows[k] = first + (k - 1) * (args.side == "left" and -1 or 1) end
  local layers, entry = {}, args.vertical == "up" and 0 or -1
  for i = 1, args.layers do layers[i] = entry + (i - 1) * (args.vertical == "up" and 1 or -1) end
  local list = visits(args.length, rows, layers)
  local door = { a = 1, r = 0, l = entry } -- box cell the turtle enters and leaves through

  local function exitCost(c) return dist(c, door) + dist(door, ORIGIN) end
  local moves = exitCost(list[1]) + exitCost(list[#list])
  for i = 2, #list do moves = moves + dist(list[i - 1], list[i]) end
  local need = moves + config.fuelMargin
  if not nav.refuel(need) then
    return { ok = false, error = ("needs about %d fuel, has %d: put coal in the turtle"):format(need, nav.fuel()) }
  end

  local function go(c, order)
    local target = { x = origin.x + c.a * fx + c.r * rx, y = origin.y + c.l, z = origin.z + c.a * fz + c.r * rz }
    check(nav.goTo(target, (order:gsub(".", axes))))
  end
  local function here()
    local p = nav.pos()
    local dx, dz = p.x - origin.x, p.z - origin.z
    return { a = dx * fx + dz * fz, r = dx * rx + dz * rz, l = p.y - origin.y }
  end
  -- <Claude> Back to the start through the box only.
  local function leave()
    local c = here()
    if dist(c, ORIGIN) == 0 then return end
    if c.r == 0 and c.l == 0 then return go(ORIGIN, "a") end
    go(door, "lra")
    go(ORIGIN, "la")
  end

  local dug0, trips, outside = nav.dug, 0, false
  local function unloadTrip()
    leave()
    trips = trips + 1
    local unloaded, why = inv.unload()
    if not unloaded then
      local home = nav.home()
      if not home or nav.distance(home, origin) == 0 then
        error("inventory full and cannot unload: " .. why, 0)
      end
      if not nav.refuel(2 * nav.distance(home, origin) + config.fuelMargin) then
        error("inventory full and not enough fuel to unload at home", 0)
      end
      outside = true
      check(nav.goTo(home))
      check(inv.unload())
      check(nav.goTo(origin))
      outside = false
    end
    if inv.freeSlots() < 3 then error("inventory still full after unloading", 0) end
  end

  local ok, failure = pcall(function()
    for _, v in ipairs(list) do
      -- <Claude> A cell digs up to 3 blocks, each possibly a new item type.
      if inv.freeSlots() < 1 + (v.up and 1 or 0) + (v.down and 1 or 0) then unloadTrip() end
      local atStart = dist(here(), ORIGIN) == 0
      local cost = (atStart and exitCost(v) or dist(here(), v)) + exitCost(v) -- get there and back
      if nav.fuel() < cost and not nav.refuel(cost + config.fuelMargin) then
        error("fuel ran low", 0)
      end
      if atStart then
        go(door, "al")
        go(v, "arl")
      else
        go(v, "lra")
      end
      if v.up then check(nav.dig("up")) end
      if v.down then check(nav.dig("down")) end
    end
    leave()
  end)

  if not ok then
    if failure == "Terminated" then error(failure, 0) end
    if not outside then
      local _, e = pcall(leave) -- best effort back to the start
      if e == "Terminated" then error(e, 0) end
    end
    nav.face(startHeading)
    local p = nav.pos()
    return { ok = false, error = failure, mined = nav.dug - dug0, at = ("%d,%d,%d"):format(p.x, p.y, p.z) }
  end
  nav.face(startHeading)
  return { ok = true, mined = nav.dug - dug0, trips = trips }
end

return M
