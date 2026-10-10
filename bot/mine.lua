--[[ <Claude>
  mineArea: digs out a box next to the turtle and comes back to the start.
  mineBox: same digging for a box given by world coordinates (fleet jobs).
  mineCircle, mineSphere: a cylinder or a ball (bot/shape.lua), possibly cut
  to a range of levels, shared among turtles by runs of x columns, dug from
  its wider end level (bottom-up for a dome).
  Local frame: a = blocks ahead (toward direction), r = blocks to the right,
  l = layers above the start level. Layers are taken three at a time: the
  turtle walks the middle one and digs up and down, so a 3-deep area costs
  one pass of fuel. In a ball, a layer of the group can be wider than the
  middle one: its extra ring is walked on that layer. Every move stays inside
  the shape, except the first step in "down" mode (the block above the door,
  in front of the turtle; below it for a round shape dug bottom-up).
  Junk (bot/config.lua) is dropped into the hole after every cell. When the
  inventory fills anyway, it burns what burns; if that is not enough, it
  unloads into a chest next to the start or at home, then resumes.
  A move another turtle kept blocked (nav.step gives up after ~20 s) is not
  a failure yet: the turtle gets back onto its route and tries again a few
  times (nav.patiently, config.turtleRetries).
]]
local nav = require("bot.nav")
local inv = require("bot.inv")
local config = require("bot.config")
local shape = require("bot.shape")

local M = {}

local ORIGIN = { a = 0, r = 0, l = 0 }
local NEIGHBOURS = { { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 }, { 1, 0, 0 }, { -1, 0, 0 } }
local BIG = 4096 -- cells listed between two yields: a big share takes seconds to list

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

local function moves(list, door)
  local n = dist(ORIGIN, door) * 2 + dist(door, list[1]) + dist(list[#list], door)
  for i = 2, #list do n = n + dist(list[i - 1], list[i]) end
  return n
end

-- <Claude> A box in the local frame: cells to visit, the door (the cell the
-- turtle enters and leaves through), the number of moves, and inside(c).
-- args: length, width, layers, vertical ("down"|"up"), side ("right"|"left"|"center").
local function layout(args)
  local rows, first = {}, ({ right = 0, left = 0, center = -math.floor((args.width - 1) / 2) })[args.side]
  for k = 1, args.width do rows[k] = first + (k - 1) * (args.side == "left" and -1 or 1) end
  local layers, entry = {}, args.vertical == "up" and 0 or -1
  for i = 1, args.layers do layers[i] = entry + (i - 1) * (args.vertical == "up" and 1 or -1) end
  local list = visits(args.length, rows, layers)
  local door = { a = 1, r = 0, l = entry }
  local r1, r2 = math.min(rows[1], rows[#rows]), math.max(rows[1], rows[#rows])
  local l1, l2 = math.min(layers[1], layers[#layers]), math.max(layers[1], layers[#layers])
  local function inside(c)
    return c.a >= 1 and c.a <= args.length and c.r >= r1 and c.r <= r2 and c.l >= l1 and c.l <= l2
  end
  return list, door, moves(list, door), inside
end

-- <Claude> A round shape's share in the local frame of heading h with the
-- start at origin (above the door, below it when upward). args: shape (world,
-- bot/shape.lua), upward (levels bottom-up instead of top-down) and
-- from, to: the share's x columns, the first one nearest the door. Rows run
-- along z (a) and the frame's r runs along x. inside(c) is the whole shape,
-- not only the share: the turtle may cross other shares to reach its own.
local function roundLayout(args, h, origin)
  local s = args.shape
  local fx, fz = nav.vector(h)
  local rx, rz = nav.vector((h + 1) % 4)
  local function inside(c)
    return shape.inside(s, origin.x + c.a * fx + c.r * rx, origin.y + c.l, origin.z + c.a * fz + c.r * rz)
  end
  -- <Claude> Column x's run at level l, as a range of a (nil when empty).
  local function run(x, l)
    local z1, z2 = shape.line(s, origin.y + l, x, nil)
    if not z1 then return nil end
    local a1, a2 = (z1 - origin.z) * fz, (z2 - origin.z) * fz
    return math.min(a1, a2), math.max(a1, a2)
  end
  local list, step = {}, args.from <= args.to and 1 or -1
  local function add(cell)
    list[#list + 1] = cell
    if #list % BIG == 0 then sleep(0) end
  end
  local layers, y1, y2, dy = {}, shape.highest(s), shape.lowest(s), -1
  if args.upward then y1, y2, dy = y2, y1, 1 end
  for y = y1, y2, dy do layers[#layers + 1] = y - origin.y end
  for g = 1, #layers, 3 do
    local n, group = math.min(3, #layers - g + 1), {}
    for i = g, g + n - 1 do group[layers[i]] = true end
    local walk = layers[n == 3 and g + 1 or g]
    -- <Claude> The walked layer, serpentine, digging up and down where the shape goes on.
    local cells, k = {}, 0
    for x = args.from, args.to, step do
      local lo, hi = run(x, walk)
      if lo then
        k = k + 1
        local r = (x - origin.x) * rx
        for i = lo, hi do
          local a = k % 2 == 1 and i or lo + hi - i
          cells[#cells + 1] = { a = a, r = r, l = walk,
            up = group[walk + 1] and inside({ a = a, r = r, l = walk + 1 }) or nil,
            down = group[walk - 1] and inside({ a = a, r = r, l = walk - 1 }) or nil }
        end
      end
    end
    local reverse = (g - 1) / 3 % 2 == 1
    for i = 1, #cells do add(cells[reverse and #cells + 1 - i or i]) end
    -- <Claude> Rings: blocks of the group's other layers beyond the walked layer's run.
    for _, l in ipairs({ walk + 1, walk - 1 }) do
      if group[l] then
        k = 0
        for x = args.from, args.to, step do
          local lo, hi = run(x, l)
          if lo then
            local wlo, whi = run(x, walk)
            local parts = {}
            if not wlo then
              parts[1] = { lo, hi }
            else
              if lo < wlo then parts[#parts + 1] = { lo, math.min(hi, wlo - 1) } end
              if hi > whi then parts[#parts + 1] = { math.max(lo, whi + 1), hi } end
            end
            if #parts > 0 then
              k = k + 1
              local r = (x - origin.x) * rx
              if k % 2 == 0 then parts = { parts[2] or parts[1], parts[2] and parts[1] or nil } end
              for _, p in ipairs(parts) do
                for i = p[1], p[2] do add({ a = k % 2 == 1 and i or p[1] + p[2] - i, r = r, l = l }) end
              end
            end
          end
        end
      end
    end
  end
  local door = { a = 1, r = 0, l = args.upward and 1 or -1 }
  if #list == 0 then return list, door, 0, inside end
  return list, door, moves(list, door), inside
end

local function fuelError(need)
  return { ok = false, error = ("needs about %d fuel, has %d: put coal in the turtle"):format(need, nav.fuel()) }
end

-- <Claude> Digs the shape toward heading h from where the turtle stands or,
-- given a checkpoint in ctx.state, carries on after a reboot. Saves one
-- before starting and after every cell: { h, args, origin, startHeading,
-- next, mined, trips, junked }.
local function dig(h, args, ctx)
  local saved = ctx and ctx.state
  local startHeading, origin = nav.heading(), nav.pos()
  if saved then h, args, startHeading, origin = saved.h, saved.args, saved.startHeading, saved.origin end
  if not nav.heading() then return { ok = false, error = "heading unknown (no GPS fix to calibrate it)" } end

  local fx, fz = nav.vector(h)
  local rx, rz = nav.vector((h + 1) % 4)
  local axes = { a = fx ~= 0 and "x" or "z", r = rx ~= 0 and "x" or "z", l = "y" }

  local round = args.shape ~= nil
  local list, door, _, inside
  if round then
    list, door, _, inside = roundLayout(args, h, origin)
  else
    args = { length = args.length, width = args.width, layers = args.layers, vertical = args.vertical, side = args.side }
    list, door, _, inside = layout(args)
  end
  if #list == 0 then return { ok = true, mined = 0 } end
  local first = saved and saved.next or 1
  local outside = false -- on a trip away from the shape (home, or back to the start after a reboot)
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
  -- <Claude> From a cell of the shape to another, never out of it. A box
  -- holds every path between its cells, so `order` (the one through dug
  -- space) is used. A round shape is walked a block at a time toward c,
  -- along an axis whose next block is inside (the one it is going along
  -- first): in a ball, cylinder or box, cut flat or not, there always is
  -- one. A step toward the center never leaves the shape, and when every
  -- step toward c moves away from the center, c is further out than the new
  -- block on each axis, so the new block is no further out than c.
  -- Straight runs are walked with one goTo each.
  local function walk(c, order)
    if not round then return go(c, order) end
    local p, axis = here(), nil
    while dist(p, c) > 0 do
      local nextAxis
      for _, ax in ipairs({ axis or "l", "l", "r", "a" }) do
        if not nextAxis and p[ax] ~= c[ax] then
          local q = { a = p.a, r = p.r, l = p.l }
          q[ax] = q[ax] + (c[ax] > p[ax] and 1 or -1)
          if inside(q) then nextAxis = ax end
        end
      end
      if not nextAxis then
        if axis then go(p, axis) end
        return go(c, order) -- only from outside the shape (the approach next to the door)
      end
      if axis and nextAxis ~= axis then go(p, axis) end
      axis = nextAxis
      p[axis] = p[axis] + (c[axis] > p[axis] and 1 or -1)
    end
    if axis then go(p, axis) end
  end

  -- <Claude> After a reboot the turtle can be anywhere on its route: in the
  -- shape, one block beside it (it was giving way), on the approach, or on a
  -- trip home. Get back onto the route first.
  local function rejoin()
    local c = here()
    if inside(c) then return end
    if c.r == 0 and c.l == 0 and (c.a == 0 or c.a == 1) then return end
    for _, d in ipairs(NEIGHBOURS) do
      local n = { a = c.a + d[1], r = c.r + d[2], l = c.l + d[3] }
      if inside(n) then return go(n, "lra") end
    end
    outside = true
    check(nav.goTo(origin))
    outside = false
  end

  -- <Claude> Back to the start through the shape only.
  local function leave()
    rejoin() -- giving way may have left it just outside
    local c = here()
    if dist(c, ORIGIN) == 0 then return end
    if c.r == 0 and c.l == 0 then return go(ORIGIN, "a") end
    walk(door, "lra")
    go(ORIGIN, "la")
  end

  local need, last = config.fuelMargin, here()
  if config.fuelForWholeDig then
    for k = first, #list do need, last = need + dist(last, list[k]), list[k] end
    need = need + exitCost(last)
  else -- only back to the start (a retry from home); the check before each cell does the rest
    need = need + dist(last, ORIGIN)
  end
  if not nav.refuel(need) then return fuelError(need) end

  local mined0, dug0 = saved and saved.mined or 0, nav.dug
  local trips, junked = saved and saved.trips or 0, saved and saved.junked or 0
  local function mined() return mined0 + nav.dug - dug0 end
  local function checkpoint(next)
    if ctx and ctx.save then
      ctx.save({ h = h, args = args, origin = origin, startHeading = startHeading, next = next,
                 mined = mined(), trips = trips, junked = junked })
    end
  end
  if not saved then checkpoint(1) end

  -- <Claude> Runs fn (it throws). When another turtle kept the way blocked,
  -- pauses and runs it again (nav.patiently), first getting back onto the
  -- route with back() if given: giving way can leave the turtle beside it.
  local function patiently(fn, back)
    check(nav.patiently(function(retry)
      return pcall(function()
        if retry and back then back() end
        fn()
      end)
    end))
  end

  local function unloadTrip()
    patiently(leave, rejoin)
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
      patiently(function() check(nav.goTo(home)) end)
      check(inv.unload())
      patiently(function() check(nav.goTo(origin)) end)
      outside = false
    end
    if inv.freeSlots() < 3 then error("inventory still full after unloading", 0) end
  end

  local ok, failure = pcall(function()
    if saved then patiently(rejoin) end
    for idx = first, #list do
      local v = list[idx]
      -- <Claude> A cell digs up to 3 blocks, each possibly a new item type.
      -- Dropping junk usually frees enough room to skip the trip home.
      local room = 1 + (v.up and 1 or 0) + (v.down and 1 or 0)
      if inv.freeSlots() < room then junked = junked + inv.discardJunk() end
      if inv.freeSlots() < room then nav.refuelAll() end -- coal and wood: into the tank, not the chest
      if inv.freeSlots() < room then unloadTrip() end
      patiently(function()
        local atStart = dist(here(), ORIGIN) == 0
        local cost = (atStart and exitCost(v) or dist(here(), v)) + exitCost(v) -- get there and back
        if nav.fuel() < cost and not nav.refuel(cost + config.fuelMargin) then
          error("fuel ran low: refuel, then retry", 0)
        end
        if atStart then
          go(door, "al")
          walk(v, "arl")
        else
          walk(v, "lra")
        end
        if v.up then check(nav.clear("up")) end
        if v.down then check(nav.clear("down")) end
        -- <Claude> Bottom-up, the level above is not dug yet: sand or gravel there
        -- falls into the block just dug up, onto the turtle. ponytail: one more
        -- look; a block still falling by then ends on the floor of the hole.
        if v.up and args.upward then check(nav.clear("up")) end
      end, rejoin)
      -- <Claude> The cell's junk goes into a block just dug, so it stays in the hole.
      local open = {}
      if v.down then open[#open + 1] = "bottom" end
      if v.up then open[#open + 1] = "top" end
      junked = junked + inv.discardJunk(open)
      checkpoint(idx + 1)
    end
    junked = junked + inv.discardJunk() -- leftovers, e.g. dug while rejoining after a reboot
    patiently(leave, rejoin)
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
  local need = nav.distance(p, entry) + (config.fuelForWholeDig and moves or 0) + config.fuelMargin
  if not nav.refuel(need) then return fuelError(need) end
  local ok, err = nav.patiently(function() return nav.goTo(entry) end)
  if not ok then return { ok = false, error = "could not reach the box: " .. err } end
  return dig(h, args, ctx)
end

-- <Claude> Share part of parts of a round shape s (bot/shape.lua): a run of
-- x columns with about as many blocks as the others. Rows run along z. It
-- digs from its wider end level: top-down, or bottom-up when the bottom is
-- wider (a ball cut above its middle, a dome), so the turtles start spread
-- over that level instead of queuing at the pole. The turtle enters the end
-- level from just above (or below) it, at its block on the middle row nearest
-- the share (a whole ball's pole is that block for every share), and ends at
-- that entry point.
local function mineRound(s, part, parts, ctx)
  if part > parts then return { ok = false, error = "part must be at most parts" } end
  local from, to = shape.share(shape.counts(s, "solid", "x"), part, parts)
  if not from then return { ok = true, mined = 0 } end -- more parts than columns: nothing left for this one
  local x1, x2 = s.x1 + from, s.x1 + to
  local top, bottom = shape.highest(s), shape.lowest(s)
  local zmid = math.floor(s.cz / 2) -- the middle row: in every column of every level
  local p = nav.pos()
  local near = math.abs(p.x - x1) <= math.abs(p.x - x2) and x1 or x2
  local xa, xb = shape.line(s, top, nil, zmid)
  local ba, bb = shape.line(s, bottom, nil, zmid)
  local upward = bb - ba > xb - xa
  if upward then xa, xb = ba, bb end
  local h = p.z <= zmid and 2 or 0 -- rows run away from the turtle: south if it is north of the middle row
  local _, fz = nav.vector(h)
  local entry = { x = math.max(xa, math.min(xb, near)), y = upward and bottom - 1 or top + 1, z = zmid - fz }
  local args = { shape = s, from = near, to = near == x1 and x2 or x1, upward = upward }
  local need = nav.distance(p, entry) + config.fuelMargin
  if config.fuelForWholeDig then need = need + select(3, roundLayout(args, h, entry)) end
  if not nav.refuel(need) then return fuelError(need) end
  local ok, err = nav.patiently(function() return nav.goTo(entry) end)
  if not ok then return { ok = false, error = "could not reach the shape: " .. err } end
  return dig(h, args, ctx)
end

-- <Claude> args: x, z (center block), diameter, y1, y2 (levels, any order),
-- part, parts (this turtle's share).
function M.mineCircle(a, ctx)
  if ctx and ctx.state then return dig(nil, nil, ctx) end -- resuming: frame and shape are saved
  return mineRound(shape.cylinder(a.x, a.z, a.diameter, a.y1, a.y2), a.part, a.parts, ctx)
end

-- <Claude> args: x, y, z (center block), diameter, top, bottom (optional:
-- only levels bottom..top), part, parts.
function M.mineSphere(a, ctx)
  if ctx and ctx.state then return dig(nil, nil, ctx) end
  local s = shape.cut(shape.ball(a.x, a.y, a.z, a.diameter), a.top, a.bottom)
  if not s then return { ok = false, error = "no level of the sphere is between top and bottom" } end
  return mineRound(s, a.part, a.parts, ctx)
end

return M
