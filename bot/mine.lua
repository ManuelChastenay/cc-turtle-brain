--[[ <Claude>
  mineArea: digs out a box next to the turtle and comes back to the start.
  mineBox: same digging for a box given by world coordinates (fleet jobs).
  Local frame: a = blocks ahead (toward direction), r = blocks to the right,
  l = layers above the start level. Layers are taken three at a time: the
  turtle walks the middle one and digs up and down, so a 3-deep area costs
  one pass of fuel. Every move stays inside the box, except the first step
  in "down" mode (the block above the box, in front of the turtle).
  Junk (bot/config.lua) is dropped into the hole after every cell. When the
  inventory fills anyway, it burns what burns; if that is not enough, it
  unloads into a chest next to the start or at home, then resumes.
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

-- <Claude> Cells to visit, the door (box cell the turtle enters and leaves
-- through), the number of moves and the box bounds ({ min, max } per axis),
-- all in the local frame.
-- args: length, width, layers, vertical ("down"|"up"), side ("right"|"left"|"center").
local function layout(args)
  local rows, first = {}, ({ right = 0, left = 0, center = -math.floor((args.width - 1) / 2) })[args.side]
  for k = 1, args.width do rows[k] = first + (k - 1) * (args.side == "left" and -1 or 1) end
  local layers, entry = {}, args.vertical == "up" and 0 or -1
  for i = 1, args.layers do layers[i] = entry + (i - 1) * (args.vertical == "up" and 1 or -1) end
  local list = visits(args.length, rows, layers)
  local door = { a = 1, r = 0, l = entry }
  local moves = dist(ORIGIN, door) * 2 + dist(door, list[1]) + dist(list[#list], door)
  for i = 2, #list do moves = moves + dist(list[i - 1], list[i]) end
  local box = {
    a = { 1, args.length },
    r = { math.min(rows[1], rows[#rows]), math.max(rows[1], rows[#rows]) },
    l = { math.min(layers[1], layers[#layers]), math.max(layers[1], layers[#layers]) },
  }
  return list, door, moves, box
end

local function fuelError(need)
  return { ok = false, error = ("needs about %d fuel, has %d: put coal in the turtle"):format(need, nav.fuel()) }
end

-- <Claude> Digs the box toward heading h from where the turtle stands or,
-- given a checkpoint in ctx.state, carries on after a reboot. Saves one
-- before starting and after every cell: { h, args, origin, startHeading,
-- next, mined, trips, junked }.
local function dig(h, args, ctx)
  local saved = ctx and ctx.state
  local startHeading, origin = nav.heading(), nav.pos()
  if saved then h, args, startHeading, origin = saved.h, saved.args, saved.startHeading, saved.origin end
  if not nav.heading() then return { ok = false, error = "heading unknown (no GPS fix to calibrate it)" } end
  local shape = { length = args.length, width = args.width, layers = args.layers, vertical = args.vertical, side = args.side }

  local fx, fz = nav.vector(h)
  local rx, rz = nav.vector((h + 1) % 4)
  local axes = { a = fx ~= 0 and "x" or "z", r = rx ~= 0 and "x" or "z", l = "y" }

  local list, door, _, box = layout(shape)
  local first = saved and saved.next or 1
  local function exitCost(c) return dist(c, door) + dist(door, ORIGIN) end

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

  local need, last = config.fuelMargin, here()
  for k = first, #list do need, last = need + dist(last, list[k]), list[k] end
  need = need + exitCost(last)
  if not nav.refuel(need) then return fuelError(need) end

  local mined0, dug0 = saved and saved.mined or 0, nav.dug
  local trips, junked, outside = saved and saved.trips or 0, saved and saved.junked or 0, false
  local function mined() return mined0 + nav.dug - dug0 end
  local function checkpoint(next)
    if ctx and ctx.save then
      ctx.save({ h = h, args = shape, origin = origin, startHeading = startHeading, next = next,
                 mined = mined(), trips = trips, junked = junked })
    end
  end
  if not saved then checkpoint(1) end

  -- <Claude> After a reboot the turtle can be anywhere on its route: in the
  -- box, one block beside it (it was giving way), on the approach, or on a
  -- trip home. Get back onto the route first.
  local function rejoin()
    local c = here()
    local function within(v, range) return v >= range[1] and v <= range[2] end
    if within(c.a, box.a) and within(c.r, box.r) and within(c.l, box.l) then return end
    if c.r == 0 and c.l == 0 and (c.a == 0 or c.a == 1) then return end
    local function clamp(v, range) return math.max(range[1], math.min(range[2], v)) end
    local near = { a = clamp(c.a, box.a), r = clamp(c.r, box.r), l = clamp(c.l, box.l) }
    if dist(c, near) == 1 then return go(near, "lra") end
    outside = true
    check(nav.goTo(origin))
    outside = false
  end

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
    if saved then rejoin() end
    for idx = first, #list do
      local v = list[idx]
      -- <Claude> A cell digs up to 3 blocks, each possibly a new item type.
      -- Dropping junk usually frees enough room to skip the trip home.
      local room = 1 + (v.up and 1 or 0) + (v.down and 1 or 0)
      if inv.freeSlots() < room then junked = junked + inv.discardJunk() end
      if inv.freeSlots() < room then nav.refuelAll() end -- coal and wood: into the tank, not the chest
      if inv.freeSlots() < room then unloadTrip() end
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
      if v.up then check(nav.clear("up")) end
      if v.down then check(nav.clear("down")) end
      -- <Claude> The cell's junk goes into a block just dug, so it stays in the hole.
      local open = {}
      if v.down then open[#open + 1] = "bottom" end
      if v.up then open[#open + 1] = "top" end
      junked = junked + inv.discardJunk(open)
      checkpoint(idx + 1)
    end
    junked = junked + inv.discardJunk() -- leftovers, e.g. dug while rejoining after a reboot
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
    return { ok = false, error = failure, mined = mined(), at = ("%d,%d,%d"):format(p.x, p.y, p.z) }
  end
  nav.face(startHeading)
  return { ok = true, mined = mined(), trips = trips, junked = junked }
end

-- <Claude> args: direction plus the layout() args. Box relative to the turtle.
function M.mineArea(args, ctx)
  if ctx and ctx.state then return dig(nil, nil, ctx) end -- resuming: direction and layout are saved
  local h, err = nav.resolve(args.direction)
  if not h then return { ok = false, error = err } end
  return dig(h, args, ctx)
end

-- <Claude> args: x1, y1, z1, x2, y2, z2 (opposite corners, any order).
-- Enters from just above the box at its top corner nearest the turtle, digs
-- top-down with rows along the longer side, and ends at that entry point.
function M.mineBox(a, ctx)
  if ctx and ctx.state then return dig(nil, nil, ctx) end -- resuming: corner and layout are saved
  local lo = { x = math.min(a.x1, a.x2), y = math.min(a.y1, a.y2), z = math.min(a.z1, a.z2) }
  local hi = { x = math.max(a.x1, a.x2), y = math.max(a.y1, a.y2), z = math.max(a.z1, a.z2) }
  local p = nav.pos()
  local function nearest(v, low, high) return math.abs(v - low) <= math.abs(v - high) and low or high end
  local cx, cz = nearest(p.x, lo.x, hi.x), nearest(p.z, lo.z, hi.z)
  local sizeX, sizeZ = hi.x - lo.x + 1, hi.z - lo.z + 1
  local alongX = sizeX >= sizeZ
  local h -- rows run from the corner into the box along the longer side
  if alongX then h = cx == lo.x and 1 or 3 else h = cz == lo.z and 2 or 0 end
  local fx, fz = nav.vector(h)
  local rx, rz = nav.vector((h + 1) % 4)
  local inward = alongX and (cz == lo.z and 1 or -1) or (cx == lo.x and 1 or -1)
  local args = {
    length = alongX and sizeX or sizeZ, width = alongX and sizeZ or sizeX, layers = hi.y - lo.y + 1,
    vertical = "down", side = (alongX and rz or rx) == inward and "right" or "left",
  }
  local entry = { x = cx - fx, y = hi.y + 1, z = cz - fz }
  local _, _, moves = layout(args)
  local need = nav.distance(p, entry) + moves + config.fuelMargin
  if not nav.refuel(need) then return fuelError(need) end
  local ok, err = nav.goTo(entry)
  if not ok then return { ok = false, error = "could not reach the box: " .. err } end
  return dig(h, args, ctx)
end

return M
