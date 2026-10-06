--[[ <Claude>
  mineArea: digs out a box next to the turtle and comes back to the start.
  mineBox: same digging for a box given by world coordinates (fleet jobs).
  mineCircle: a round hole (a cylinder) given by its center and diameter.
  Local frame: a = blocks ahead (toward direction), r = blocks to the right,
  l = layers above the start level. Layers are taken three at a time: the
  turtle walks the middle one and digs up and down, so a 3-deep area costs
  one pass of fuel. A shape is rows (one per r) of cells along a: in a box
  every row runs from 1 to length; a circle's rows (spans) have different
  lengths, but each is unbroken and holds the door column (a = 1), so moves
  go along rows and that column. Every move stays inside the shape, except
  the first step in "down" mode (the block above the door, in front of the
  turtle).
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

local M = {}

local ORIGIN = { a = 0, r = 0, l = 0 }
local NEIGHBOURS = { { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 }, { 1, 0, 0 }, { -1, 0, 0 } }

local function dist(p, q)
  return math.abs(p.a - q.a) + math.abs(p.r - q.r) + math.abs(p.l - q.l)
end

local function check(ok, err)
  if not ok then error(err, 0) end
end

-- <Claude> Cells to walk, in order: a serpentine per layer group, reversed
-- every other group so each group starts above or below where the last ended.
-- span(k) gives the first and last a of row k.
local function visits(span, rows, layers)
  local list = {}
  for g = 1, #layers, 3 do
    local n, group = math.min(3, #layers - g + 1), {}
    for i = g, g + n - 1 do group[layers[i]] = true end
    local walk = layers[n == 3 and g + 1 or g]
    local cells = {}
    for k, r in ipairs(rows) do
      local lo, hi = span(k)
      for i = lo, hi do
        local a = k % 2 == 1 and i or lo + hi - i
        cells[#cells + 1] = { a = a, r = r, l = walk, up = group[walk + 1], down = group[walk - 1] }
      end
    end
    local reverse = (g - 1) / 3 % 2 == 1
    for i = 1, #cells do list[#list + 1] = cells[reverse and #cells + 1 - i or i] end
  end
  return list
end

-- <Claude> Cells to visit, the door (the cell the turtle enters and leaves
-- through), the number of moves, and inside(c): whether a cell of the local
-- frame is part of the shape.
-- args: length, width, layers, vertical ("down"|"up"), side ("right"|"left"|"center"),
-- spans (optional: { first a, last a } per row instead of 1..length; each must hold a = 1).
local function layout(args)
  local rows, first = {}, ({ right = 0, left = 0, center = -math.floor((args.width - 1) / 2) })[args.side]
  for k = 1, args.width do rows[k] = first + (k - 1) * (args.side == "left" and -1 or 1) end
  local layers, entry = {}, args.vertical == "up" and 0 or -1
  for i = 1, args.layers do layers[i] = entry + (i - 1) * (args.vertical == "up" and 1 or -1) end
  local function span(k)
    if args.spans then return args.spans[k][1], args.spans[k][2] end
    return 1, args.length
  end
  local list = visits(span, rows, layers)
  local door = { a = 1, r = 0, l = entry }
  local moves = dist(ORIGIN, door) * 2 + dist(door, list[1]) + dist(list[#list], door)
  for i = 2, #list do moves = moves + dist(list[i - 1], list[i]) end
  local row, low, high = {}, math.min(layers[1], layers[#layers]), math.max(layers[1], layers[#layers])
  for k, r in ipairs(rows) do row[r] = k end
  local function inside(c)
    local k = row[c.r]
    if not k or c.l < low or c.l > high then return false end
    local lo, hi = span(k)
    return c.a >= lo and c.a <= hi
  end
  return list, door, moves, inside
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
  local shape = { length = args.length, width = args.width, layers = args.layers, vertical = args.vertical,
                  side = args.side, spans = args.spans }

  local fx, fz = nav.vector(h)
  local rx, rz = nav.vector((h + 1) % 4)
  local axes = { a = fx ~= 0 and "x" or "z", r = rx ~= 0 and "x" or "z", l = "y" }

  local list, door, _, inside = layout(shape)
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
  -- space) is used. With spans it goes across rows along the column it is in
  -- or the one it goes to, whichever is inside, else by the door column.
  local function walk(c, order)
    if not shape.spans then return go(c, order) end
    local p = here()
    if inside({ a = p.a, r = c.r, l = c.l }) then return go(c, "lra") end
    if inside({ a = c.a, r = p.r, l = c.l }) then return go(c, "lar") end
    go({ a = door.a, r = p.r, l = c.l }, "la")
    go(c, "ra")
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
  for k = first, #list do need, last = need + dist(last, list[k]), list[k] end
  need = need + exitCost(last)
  if not nav.refuel(need) then return fuelError(need) end

  local mined0, dug0 = saved and saved.mined or 0, nav.dug
  local trips, junked = saved and saved.trips or 0, saved and saved.junked or 0
  local function mined() return mined0 + nav.dug - dug0 end
  local function checkpoint(next)
    if ctx and ctx.save then
      ctx.save({ h = h, args = shape, origin = origin, startHeading = startHeading, next = next,
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
          error("fuel ran low", 0)
        end
        if atStart then
          go(door, "al")
          walk(v, "arl")
        else
          walk(v, "lra")
        end
        if v.up then check(nav.clear("up")) end
        if v.down then check(nav.clear("down")) end
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
  local need = nav.distance(p, entry) + moves + config.fuelMargin
  if not nav.refuel(need) then return fuelError(need) end
  local ok, err = nav.patiently(function() return nav.goTo(entry) end)
  if not ok then return { ok = false, error = "could not reach the box: " .. err } end
  return dig(h, args, ctx)
end

-- <Claude> A circle d blocks wide, column by column: for each x offset 0..d-1,
-- its first and last z offset. A block is in when its distance to the center
-- is at most (d - 1) / 2, so odd diameters have a one-block bump at each of
-- the four ends (as on the 75-block chart this was made from). Counted in half
-- blocks so even diameters work too; they get two-block bumps.
function M.circle(d)
  local c = d - 1
  local limit = c * c + (d % 2 == 0 and 1 or 0)
  local cols = {}
  for i = 0, c do
    local u = 2 * i - c
    local s = limit - u * u
    local m = math.floor(math.sqrt(s))
    while m * m > s do m = m - 1 end
    while (m + 1) * (m + 1) <= s do m = m + 1 end
    cols[i + 1] = { math.ceil((c - m) / 2), math.floor((c + m) / 2) }
  end
  return cols
end

-- <Claude> Share `part` of `parts` of the circle cols: a run of columns with
-- about 1/parts of its blocks (edge columns are short, so edge shares are
-- wider). Returns the first and last column offset, or nil when there are
-- more parts than columns and this one gets none. Every turtle of a fleet
-- computes the same split, so each column is dug by exactly one of them.
function M.share(cols, part, parts)
  local n = #cols
  parts = math.min(parts, n)
  if part > parts then return nil end
  local function size(i) return cols[i][2] - cols[i][1] + 1 end
  local total = 0
  for i = 1, n do total = total + size(i) end
  local from, sum = 1, 0
  for k = 1, parts do
    local to = from
    sum = sum + size(to)
    if k == parts then to = n end
    while to < n - (parts - k) and sum + size(to + 1) / 2 <= total * k / parts do
      to = to + 1
      sum = sum + size(to)
    end
    if k == part then return from - 1, to - 1 end
    from = to + 1
  end
end

-- <Claude> args: x, z (center block), diameter, y1, y2 (levels, any order),
-- part, parts (this turtle's share, see M.share). Rows run along z, one per
-- x column of the share; the turtle enters above the share's edge column
-- nearest to it, on the circle's middle row (in every column), digs top-down
-- and ends at that entry point.
function M.mineCircle(a, ctx)
  if ctx and ctx.state then return dig(nil, nil, ctx) end -- resuming: frame and spans are saved
  if a.part > a.parts then return { ok = false, error = "part must be at most parts" } end
  local d = a.diameter
  local cols = M.circle(d)
  local from, to = M.share(cols, a.part, a.parts)
  if not from then return { ok = true, mined = 0 } end -- more parts than columns: nothing left for this one
  local lo = { x = a.x - math.floor((d - 1) / 2), z = a.z - math.floor((d - 1) / 2) }
  local mid = lo.z + math.floor((d - 1) / 2)
  local top, bottom = math.max(a.y1, a.y2), math.min(a.y1, a.y2)
  local p = nav.pos()
  local x1, x2 = lo.x + from, lo.x + to
  local near = math.abs(p.x - x1) <= math.abs(p.x - x2) and x1 or x2
  local inward = near == x1 and 1 or -1
  local h = p.z <= mid and 2 or 0 -- rows run away from the turtle: south if it is north of the middle row
  local _, fz = nav.vector(h)
  local rx = nav.vector((h + 1) % 4)
  local spans = {}
  for k = 1, to - from + 1 do
    local col = cols[near + (k - 1) * inward - lo.x + 1]
    local a1, a2 = 1 + (lo.z + col[1] - mid) * fz, 1 + (lo.z + col[2] - mid) * fz
    spans[k] = { math.min(a1, a2), math.max(a1, a2) }
  end
  local args = { width = to - from + 1, layers = top - bottom + 1, vertical = "down",
                 side = rx == inward and "right" or "left", spans = spans }
  local entry = { x = near, y = top + 1, z = mid - fz }
  local _, _, moves = layout(args)
  local need = nav.distance(p, entry) + moves + config.fuelMargin
  if not nav.refuel(need) then return fuelError(need) end
  local ok, err = nav.patiently(function() return nav.goTo(entry) end)
  if not ok then return { ok = false, error = "could not reach the circle: " .. err } end
  return dig(h, args, ctx)
end

return M
