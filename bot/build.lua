--[[ <Claude>
  Building with one block type: buildSphere and buildBox (bot/skills.lua).
  The structure (bot/shape.lua) goes up from the bottom, a level at a time:
  the turtle flies one block above the level and places down, so nothing
  above it is built yet.
  A share is a tile: a rectangle of the footprint, a run of columns across
  the longer side, and for hollow and walls also one half of the other side
  (so a share is one patch of the surface, not two far apart). The turtle
  only moves inside its tile, at most two blocks above the level it builds,
  so it never runs into what other turtles built. Every other move (the
  first one, refills, after a reboot) goes straight up to two blocks above
  the structure, across, and down where nothing is built. While building,
  the build block is never dug (nav.keep).
  Blocks come from the supply: an inventory next to home ("home"), or the
  one at "x,y,z", taken from the block above it (one turtle at a time, the
  others wait their turn). It should hold only the build block, and fuel
  if needed (bot/inv.lua take).
  A block already in place is kept; anything else there is dug, except
  protected blocks (bot/config.lua), which are skipped.
  touching (buildSphere touching=yes): a block is only placed when one of
  its sides is something other than air, the build block or a turtle (the
  top is not looked at: the turtle comes from there and may have dug it).
  The turtle goes into the cell to look, so it is slower. The others are
  left as they are (bare): e.g. a lining for a dug bowl that leaves out the
  rim sticking up into open air.
  Checkpoint after every block: { level, i, reversed, placed, kept, skipped, bare, trips }.
]]
local nav = require("bot.nav")
local inv = require("bot.inv")
local config = require("bot.config")
local shape = require("bot.shape")

local M = {}

local CEILING = 319 -- highest level a turtle can stand on

local function check(ok, err)
  if not ok then error(err, 0) end
end

-- <Claude> The tile of share part of parts: { u, v (axis names), u1, u2, v1, v2 },
-- or nil when this share gets nothing (more shares than columns).
local function tile(s, fill, part, parts)
  local u, v = shape.axes(s)
  local v1, v2 = s[v .. "1"], s[v .. "2"]
  local n, k = parts, part
  if fill ~= "solid" and parts >= 2 then
    local low, mid = shape.lowHalf(parts), math.floor((v1 + v2) / 2)
    if part <= low then n, k, v2 = low, part, mid else n, k, v1 = parts - low, part - low, mid + 1 end
  end
  local from, to = shape.share(shape.counts(s, fill, u, v1, v2), k, n)
  if not from then return nil end
  return { u = u, v = v, u1 = s[u .. "1"] + from, u2 = s[u .. "1"] + to, v1 = v1, v2 = v2 }
end

-- <Claude> The blocks of level y in the tile, in order: the first run of
-- each column (columns in order), then the second runs (the far side of a
-- shell) coming back. Each run starts at its end nearest the last block.
local function targets(s, fill, t, y)
  local cols = {}
  for c = t.u1, t.u2 do
    local runs = {}
    for _, r in ipairs(t.u == "x" and shape.ranges(s, fill, y, c, nil) or shape.ranges(s, fill, y, nil, c)) do
      local a, b = math.max(r[1], t.v1), math.min(r[2], t.v2)
      if a <= b then runs[#runs + 1] = { a, b } end
    end
    cols[#cols + 1] = { c = c, runs = runs }
  end
  local out, last = {}, nil
  local function add(c, run)
    local a, b = run[1], run[2]
    if last and math.abs(last - b) < math.abs(last - a) then a, b = b, a end
    for w = a, b, a <= b and 1 or -1 do
      out[#out + 1] = t.u == "x" and { x = c, y = y, z = w } or { x = w, y = y, z = c }
    end
    last = b
  end
  for i = 1, #cols do if cols[i].runs[1] then add(cols[i].c, cols[i].runs[1]) end end
  for i = #cols, 1, -1 do if cols[i].runs[2] then add(cols[i].c, cols[i].runs[2]) end end
  return out
end

-- <Claude> "home" or "x,y,z" -> where to stand to take blocks and the side
-- the inventory is on (nil: look for it), or nil, err.
local function supplySpot(supply)
  if supply == "home" then
    local home = nav.home()
    if not home then return nil, "no home set" end
    return { x = home.x, y = home.y, z = home.z }
  end
  local x, y, z = tostring(supply):match("^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$")
  if not x then return nil, "supply must be home or x,y,z" end
  return { x = tonumber(x), y = tonumber(y) + 1, z = tonumber(z) }, "bottom"
end

-- <Claude> Builds share part of parts of s (bot/shape.lua) with block. fill:
-- "hollow", "walls" or "solid" (shape.ranges). touching: see the top. Ends
-- two blocks above the structure, so a goHome after it flies over what was built.
local function build(s, fill, block, supply, part, parts, touching, ctx)
  local saved = ctx and ctx.state
  if part > parts then return { ok = false, error = "part must be at most parts" } end
  local t = tile(s, fill, part, parts)
  if not t then return { ok = true, placed = 0 } end
  local safe = shape.highest(s) + 2
  if safe > CEILING then return { ok = false, error = "the structure reaches too high to fly over it" } end
  local spot, side = supplySpot(supply)
  if not spot then return { ok = false, error = side } end
  for y = spot.y, shape.highest(s) do
    if shape.inside(s, spot.x, y, spot.z) then
      return { ok = false, error = ("the supply (%s) is under the structure: turtles could not reach it"):format(supply) }
    end
  end

  local placed, kept, skipped = saved and saved.placed or 0, saved and saved.kept or 0, saved and saved.skipped or 0
  local bare, trips = saved and saved.bare or 0, saved and saved.trips or 0
  local function inTile(p) return p[t.u] >= t.u1 and p[t.u] <= t.u2 and p[t.v] >= t.v1 and p[t.v] <= t.v2 end

  -- <Claude> Straight up, across two blocks above the structure, then to dest.
  local function fly(dest)
    local p = nav.pos()
    if p.y < safe then check(nav.goTo({ x = p.x, y = safe, z = p.z })) end
    check(nav.goTo({ x = dest.x, y = math.max(safe, nav.pos().y), z = dest.z }))
    check(nav.goTo(dest))
  end
  -- <Claude> To the block above c: directly when already in the tile near
  -- that level (nothing built there yet), else by fly.
  local function above(c)
    local dest, p = { x = c.x, y = c.y + 1, z = c.z }, nav.pos()
    if inTile(p) and p.y >= c.y and p.y <= c.y + 2 then check(nav.goTo(dest)) else fly(dest) end
  end
  local function patiently(fn)
    check(nav.patiently(function() return pcall(fn) end))
  end
  local function selectBlock()
    local item = turtle.getItemDetail()
    if item and item.name == block then return true end
    for slot = 1, 16 do
      item = turtle.getItemDetail(slot)
      if item and item.name == block then
        turtle.select(slot)
        return true
      end
    end
    return false
  end
  -- <Claude> Fuel to reach c and fly back to the supply from it.
  local function need(c)
    local p = nav.pos()
    return math.abs(p.x - c.x) + math.abs(p.z - c.z) + math.abs(p.y - c.y) + 2 * safe - c.y - spot.y
      + math.abs(c.x - spot.x) + math.abs(c.z - spot.z) + config.fuelMargin
  end
  local function refill()
    trips = trips + 1
    patiently(function() fly(spot) end)
    local n, err = inv.take(block, side)
    if not n then error(("cannot take %s at the supply: %s"):format(block, err), 0) end
    if n == 0 then error(("the supply has no %s (keep only that block in it)"):format(block), 0) end
  end
  -- <Claude> For touching: is a side of c other than the top something other
  -- than air, the build block or a turtle? Looks from inside c (down first,
  -- then around, stopping at the first one), then goes back above c.
  local function touches(c)
    local function solid(found, b)
      return found and b.name ~= block and not b.name:find("computercraft:turtle", 1, true)
    end
    patiently(function() check(nav.goTo(c)) end)
    local hit = solid(turtle.inspectDown())
    for i = 1, 4 do
      if hit then break end
      if i > 1 then check(nav.face((nav.heading() + 1) % 4)) end
      hit = solid(turtle.inspect())
    end
    patiently(function() above(c) end)
    return hit
  end
  -- <Claude> "placed", "kept", "skipped" or "bare" for c, the block below; nil when out of blocks.
  local function place(c)
    local found, below = turtle.inspectDown()
    if found and below.name == block then return "kept" end
    if found then
      local cleared, err = nav.clear("down")
      if not cleared then
        if tostring(err):find("protected", 1, true) then return "skipped" end
        error(err, 0)
      end
      if inv.freeSlots() < 2 then inv.discardJunk({ "top" }) end -- not below: that block is filled next
    end
    if not selectBlock() then return nil end
    if touching and not touches(c) then return "bare" end
    for _ = 1, 10 do
      if turtle.placeDown() then return "placed" end
      sleep(0.5) -- a mob or a player in the way
    end
    return "skipped"
  end

  local level, start, reversed = saved and saved.level or shape.lowest(s), saved and saved.i or 1, saved and saved.reversed
  local ok, failure = pcall(function()
    for y = level, shape.highest(s) do
      local list = targets(s, fill, t, y)
      if #list > 0 then
        if start == 1 then -- a new level: start from its end nearest the turtle
          local p = nav.pos()
          local function d(c) return math.abs(p.x - c.x) + math.abs(p.z - c.z) end
          reversed = d(list[#list]) < d(list[1])
        end
        for i = start, #list do
          local c = list[reversed and #list + 1 - i or i]
          if nav.fuel() < need(c) and not nav.refuel(need(c)) then
            refill()
            if not nav.refuel(need(c)) then error("fuel ran low: put coal in the supply", 0) end
          end
          patiently(function() above(c) end)
          local r = place(c)
          if r == nil then
            refill()
            patiently(function() above(c) end)
            r = place(c)
          end
          if r == "placed" then placed = placed + 1 elseif r == "kept" then kept = kept + 1
          elseif r == "bare" then bare = bare + 1 else skipped = skipped + 1 end
          if ctx and ctx.save then
            ctx.save({ level = y, i = i + 1, reversed = reversed, placed = placed, kept = kept, skipped = skipped,
                       bare = bare, trips = trips })
          end
        end
      end
      start = 1
    end
    local p = nav.pos()
    patiently(function() check(nav.goTo({ x = p.x, y = safe, z = p.z })) end)
  end)
  if not ok then
    if failure == "Terminated" then error(failure, 0) end
    local p = nav.pos()
    return { ok = false, error = failure, placed = placed, at = ("%d,%d,%d"):format(p.x, p.y, p.z) }
  end
  return { ok = true, placed = placed, kept = kept, skipped = skipped, bare = touching and bare or nil, trips = trips }
end

-- <Claude> Runs a build with the build block protected from digging (nav.keep).
local function guarded(s, a, ctx)
  nav.keep = a.block
  local ok, result = pcall(build, s, a.fill, a.block, a.supply, a.part, a.parts, a.touching == "yes", ctx)
  nav.keep = nil
  if not ok then error(result, 0) end
  return result
end

-- <Claude> args: x, y, z (center block), diameter, block, fill, top, bottom
-- (optional: only levels bottom..top, left open), supply, touching (no|yes), part, parts.
function M.sphere(a, ctx)
  local s = shape.cut(shape.ball(a.x, a.y, a.z, a.diameter), a.top, a.bottom)
  if not s then return { ok = false, error = "no level of the sphere is between top and bottom" } end
  return guarded(s, a, ctx)
end

-- <Claude> args: x1, y1, z1, x2, y2, z2 (opposite corners), block, fill, supply, part, parts.
function M.box(a, ctx)
  return guarded(shape.box(a.x1, a.y1, a.z1, a.x2, a.y2, a.z2), a, ctx)
end

return M
