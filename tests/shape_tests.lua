--[[ <Claude>
  Tests for bot/shape.lua, mineSphere (bot/mine.lua) and building
  (bot/build.lua: buildSphere, buildBox). Loaded by tests/tests.lua:
  dofile(SIM_DIR .. "shape_tests.lua")(test, eq, truthy, helpers)
]]
return function(test, eq, truthy, h)
  local BRICKS = "minecraft:stone_bricks"

  -- <Claude> Brute force: is x,y,z one of the blocks built with fill? A side
  -- is out when the block there is out of the shape, except across a cut
  -- level (a cut is open).
  local function wanted(shape, s, fill, x, y, z)
    if not shape.inside(s, x, y, z) then return false end
    if fill == "solid" then return true end
    local function out(x2, y2, z2, uncut)
      local top, bottom = s.top, s.bottom
      if uncut then s.top, s.bottom = nil, nil end
      local inside = shape.inside(s, x2, y2, z2)
      s.top, s.bottom = top, bottom
      return not inside
    end
    if out(x - 1, y, z) or out(x + 1, y, z) or out(x, y, z - 1) or out(x, y, z + 1) then return true end
    return fill == "hollow" and (out(x, y - 1, z, true) or out(x, y + 1, z, true))
  end

  local function structure(shape, s, fill)
    local cells, n = {}, 0
    for x = s.x1, s.x2 do for y = s.y1, s.y2 do for z = s.z1, s.z2 do
      if wanted(shape, s, fill, x, y, z) then cells[sim.key(x, y, z)], n = true, n + 1 end
    end end end
    return cells, n
  end

  -- <Claude> Every block of cells is block; nothing else above the ground is.
  local function built(s, cells, block, tag)
    for x = s.x1 - 1, s.x2 + 1 do for y = s.y1 - 1, s.y2 + 1 do for z = s.z1 - 1, s.z2 + 1 do
      local k = sim.key(x, y, z)
      if cells[k] then
        eq(sim.get(x, y, z), block, tag .. ": missing " .. k)
      elseif y > 30 then
        eq(sim.get(x, y, z) == block, false, tag .. ": extra " .. k)
      end
    end end end
  end

  local function skill(name)
    for _, sk in ipairs(require("bot.skills").list) do if sk.name == name then return sk end end
  end

  ---------------------------------------------------------------- shapes
  test("shape: hollow and walls are the blocks with a side out of the shape; a cut stays open", function()
    sim.reset{}
    local shape = require("bot.shape")
    local shapes = { shape.ball(0, 0, 0, 9), shape.ball(3, -2, 1, 8), shape.box(0, 0, 0, 4, 3, 6),
      shape.cylinder(1, 2, 7, 0, 3), shape.cut(shape.ball(0, 0, 0, 11), 2, -3), shape.box(0, 5, 0, 6, 5, 2) }
    for n, s in ipairs(shapes) do
      for _, fill in ipairs({ "solid", "hollow", "walls" }) do
        for y = s.y1 - 1, s.y2 + 1 do
          for x = s.x1 - 1, s.x2 + 1 do
            local got = {}
            for _, r in ipairs(shape.ranges(s, fill, y, x, nil)) do for z = r[1], r[2] do got[z] = true end end
            for z = s.z1 - 1, s.z2 + 1 do
              eq(got[z] or false, wanted(shape, s, fill, x, y, z), ("shape %d %s at %d,%d,%d"):format(n, fill, x, y, z))
            end
          end
          for z = s.z1 - 1, s.z2 + 1 do
            local got = {}
            for _, r in ipairs(shape.ranges(s, fill, y, nil, z)) do for x = r[1], r[2] do got[x] = true end end
            for x = s.x1 - 1, s.x2 + 1 do
              eq(got[x] or false, wanted(shape, s, fill, x, y, z), ("shape %d %s along x at %d,%d,%d"):format(n, fill, x, y, z))
            end
          end
        end
      end
    end
  end)

  test("shape: a ball's middle level is the circle of its diameter; every ball reaches its bounds", function()
    sim.reset{}
    local shape = require("bot.shape")
    local ball, disk = shape.ball(0, 0, 0, 75), shape.cylinder(0, 0, 75, 0, 0)
    for x = ball.x1, ball.x2 do
      local a, b = shape.line(ball, 0, x, nil)
      local c, d = shape.line(disk, 0, x, nil)
      eq(a, c, "x " .. x) eq(b, d, "x " .. x)
    end
    for _, d in ipairs({ 1, 2, 5, 8, 9 }) do
      local s = shape.ball(0, 0, 0, d)
      local faces = {}
      for x = s.x1, s.x2 do for y = s.y1, s.y2 do for z = s.z1, s.z2 do
        if shape.inside(s, x, y, z) then
          for _, f in ipairs({ { "x1", x }, { "x2", x }, { "y1", y }, { "y2", y }, { "z1", z }, { "z2", z } }) do
            if f[2] == s[f[1]] then faces[f[1]] = true end
          end
        end
      end end end
      for _, f in ipairs({ "x1", "x2", "y1", "y2", "z1", "z2" }) do truthy(faces[f], ("d=%d: nothing on face %s"):format(d, f)) end
    end
    eq(shape.cut(shape.ball(0, 0, 0, 9), -10, -20), nil, "a cut with nothing left")
  end)

  ---------------------------------------------------------------- mining spheres
  local function mineFrom(start, a)
    sim.reset{ gps = false, turtle = { x = start[1], y = 31, z = start[2], h = 2, fuel = 50000 } }
    h.saveState(2)
    local nav, mine = require("bot.nav"), require("bot.mine")
    nav.init()
    return mine.mineSphere(a)
  end

  test("mineSphere: digs exactly the ball, whole or cut below its middle, from any side", function()
    local cases = { { x = 2, y = 33, z = 3, diameter = 20, top = 30 }, { x = 0, y = 26, z = 0, diameter = 9 },
      { x = 1, y = 27, z = -2, diameter = 8 }, { x = -3, y = 30, z = 4, diameter = 11, top = 30, bottom = 26 } }
    for _, c in ipairs(cases) do
      c.part, c.parts = 1, 1
      for _, st in ipairs({ { -25, 0 }, { 25, 3 }, { 2, -25 }, { 0, 25 } }) do
        local r = mineFrom(st, c)
        local shape = require("bot.shape")
        local s = shape.cut(shape.ball(c.x, c.y, c.z, c.diameter), c.top, c.bottom)
        local cells = h.blocks(s)
        local tag = ("ball %d,%d,%d d=%d top=%s bottom=%s from %d,%d"):format(c.x, c.y, c.z, c.diameter,
          tostring(c.top), tostring(c.bottom), st[1], st[2])
        truthy(r.ok, tag .. ": " .. tostring(r.error))
        for k in pairs(cells) do eq(sim.get(h.at(k)), nil, tag .. ": undug " .. k) end
        for _, k in ipairs(sim.dugLog) do truthy(cells[k], tag .. ": collateral dig at " .. k) end
        eq(sim.t.y, shape.highest(s) + 1, tag .. ": end level")
      end
    end
  end)

  test("mineSphere shares: below its middle each share digs only its columns; together the whole ball", function()
    sim.reset{ gps = false, turtle = { x = -30, y = 31, z = 0, h = 1, fuel = 50000 } }
    h.saveState(1)
    local nav, mine, shape = require("bot.nav"), require("bot.mine"), require("bot.shape")
    nav.init()
    local a = { x = 0, y = 34, z = 0, diameter = 16, top = 30, parts = 4 }
    local s = shape.cut(shape.ball(0, 34, 0, 16), 30)
    local cells, total = h.blocks(s)
    for part = 1, 4 do
      local before = #sim.dugLog
      a.part = part
      local r = mine.mineSphere(a)
      truthy(r.ok, part .. ": " .. tostring(r.error))
      local from, to = shape.share(shape.counts(s, "solid", "x"), part, 4)
      for i = before + 1, #sim.dugLog do
        local k = sim.dugLog[i]
        local x = h.at(k)
        truthy(cells[k], "collateral dig at " .. k)
        truthy(x - s.x1 >= from and x - s.x1 <= to, ("share %d dug in column %d"):format(part, x))
      end
    end
    for k in pairs(cells) do eq(sim.get(h.at(k)), nil, "undug " .. k) end
    eq(#sim.dugLog, total, "dug count")
  end)

  test("mineSphere shares of a whole ball: all go in through its top; together the whole ball, nothing else", function()
    sim.reset{ gps = false, turtle = { x = 20, y = 31, z = 5, h = 3, fuel = 50000 } }
    h.saveState(3)
    local nav, mine, shape = require("bot.nav"), require("bot.mine"), require("bot.shape")
    nav.init()
    local cells, total = h.blocks(shape.ball(0, 26, 0, 9))
    for part = 1, 3 do
      local r = mine.mineSphere({ x = 0, y = 26, z = 0, diameter = 9, part = part, parts = 3 })
      truthy(r.ok, part .. ": " .. tostring(r.error))
    end
    for k in pairs(cells) do eq(sim.get(h.at(k)), nil, "undug " .. k) end
    for _, k in ipairs(sim.dugLog) do truthy(cells[k], "collateral dig at " .. k) end
    eq(#sim.dugLog, total, "dug count")
  end)

  test("mineSphere: a dome (cut above its middle) is dug bottom-up from under its floor; shares enter apart", function()
    local shape = require("bot.shape")
    local a = { x = 0, y = 28, z = 0, diameter = 21, bottom = 31 }
    local s = shape.cut(shape.ball(0, 28, 0, 21), nil, 31)
    local cells = h.blocks(s)
    local function hill(x, y, z) if y <= 30 or shape.inside(s, x, y, z) then return "minecraft:stone" end end
    local function checkDigs(tag, oneShare)
      for k in pairs(cells) do eq(sim.get(h.at(k)), nil, tag .. ": undug " .. k) end
      local under, last31, first38 = 0, 0, nil
      for i, k in ipairs(sim.dugLog) do
        local _, y = h.at(k)
        if not cells[k] then eq(y, 30, tag .. ": collateral dig at " .. k) under = under + 1 end
        if cells[k] and y == 31 then last31 = i end
        if y == 38 and not first38 then first38 = i end
      end
      if oneShare then truthy(first38 and last31 < first38, tag .. ": the floor level was not done before the top") end
      return under
    end
    for _, st in ipairs({ { -25, 0 }, { 25, 3 }, { 2, -25 }, { 0, 25 } }) do
      sim.reset{ gps = false, terrain = hill, turtle = { x = st[1], y = 31, z = st[2], h = 2, fuel = 50000 } }
      h.saveState(2)
      require("bot.nav").init()
      a.part, a.parts = 1, 1
      local r = require("bot.mine").mineSphere(a)
      local tag = ("dome from %d,%d"):format(st[1], st[2])
      truthy(r.ok, tag .. ": " .. tostring(r.error))
      eq(checkDigs(tag, true), 2, tag .. ": blocks dug under the floor (start, approach)")
      eq(sim.t.y, 30, tag .. ": ends under the floor")
    end
    sim.reset{ gps = false, terrain = hill, turtle = { x = -25, y = 31, z = 0, h = 1, fuel = 50000 } }
    h.saveState(1)
    require("bot.nav").init()
    local entries = {}
    for part = 1, 3 do
      a.part, a.parts = part, 3
      local r = require("bot.mine").mineSphere(a)
      truthy(r.ok, part .. ": " .. tostring(r.error))
      entries[sim.t.x] = true
    end
    checkDigs("3 shares")
    eq(h.count(entries), 3, "each share enters at its own column")
  end)

  test("mineSphere: split west to east; top and bottom are optional (top=none in the prompt)", function()
    sim.reset{}
    local plan, skills = require("bot.plan"), require("bot.skills")
    local cat = plan.catalog(skills.list)
    truthy(cat:find("- mineSphere(x, y, z, diameter, top=none, bottom=none):", 1, true), cat)
    local steps = assert(plan.check({ { skill = "mineSphere", x = 0, y = 100, z = 0, diameter = 200, top = 75 } }, skills.list))
    eq(steps[1].args.top, 75) eq(steps[1].args.bottom, nil) eq(steps[1].args.parts, 1)
    local parts = skill("mineSphere").split(steps[1].args,
      { { x = 50, y = 64, z = 0 }, { x = -50, y = 64, z = 0 }, { x = 0, y = 64, z = 0 } })
    eq(parts[2].part, 1) eq(parts[3].part, 2) eq(parts[1].part, 3)
    for i = 1, 3 do eq(parts[i].parts, 3) eq(parts[i].top, 75) end
  end)

  test("worker: a sphere job survives reboots at any point and digs exactly the ball", function()
    sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 1, fuel = 20000 }, modem = true, id = 5 }
    local sent = false
    sim.onIdle = function()
      if sent then return false end
      sent = true
      sim.deliver(99, { type = "plan", job = "s1", steps = {
        { skill = "mineSphere", x = 3, y = 33, z = -9, diameter = 14, top = 30 },
        { skill = "goTo", x = 0, y = 31, z = 0 } } })
      return true
    end
    local reboots, err = h.runWorkerWithReboots(function(n) return n < 40 and 5 + (n * 7) % 13 or nil end)
    eq(err, "SIM_IDLE")
    truthy(reboots >= 5, "reboots " .. reboots)
    local result = h.lastResult()
    eq(result.job, "s1") eq(result.ok, true, tostring(result.error))
    local shape = require("bot.shape")
    local cells = h.blocks(shape.cut(shape.ball(3, 33, -9, 14), 30))
    for k in pairs(cells) do eq(sim.get(h.at(k)), nil, "undug " .. k) end
    for _, k in ipairs(sim.dugLog) do truthy(cells[k], "collateral dig at " .. k) end
    eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0)
  end)

  test("worker: a dome job (bottom-up) survives reboots at any point and digs exactly the dome", function()
    local shape = require("bot.shape")
    local s = shape.cut(shape.ball(3, 28, -20, 17), nil, 31)
    local function hill(x, y, z) if y <= 30 or shape.inside(s, x, y, z) then return "minecraft:stone" end end
    sim.reset{ terrain = hill, turtle = { x = 0, y = 31, z = 0, h = 1, fuel = 20000 }, modem = true, id = 5 }
    local sent = false
    sim.onIdle = function()
      if sent then return false end
      sent = true
      sim.deliver(99, { type = "plan", job = "d1", steps = {
        { skill = "mineSphere", x = 3, y = 28, z = -20, diameter = 17, bottom = 31 },
        { skill = "goTo", x = 0, y = 31, z = 0 } } })
      return true
    end
    local reboots, err = h.runWorkerWithReboots(function(n) return n < 40 and 5 + (n * 7) % 13 or nil end)
    eq(err, "SIM_IDLE")
    truthy(reboots >= 5, "reboots " .. reboots)
    local result = h.lastResult()
    eq(result.job, "d1") eq(result.ok, true, tostring(result.error))
    local cells = h.blocks(s)
    for k in pairs(cells) do eq(sim.get(h.at(k)), nil, "undug " .. k) end
    for _, k in ipairs(sim.dugLog) do
      local _, y = h.at(k)
      truthy(cells[k] or y <= 30, "collateral dig above the ground at " .. k)
    end
    eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0)
  end)

  ---------------------------------------------------------------- building
  -- <Claude> A turtle at 0,31,0 facing south (home), a chest below home with
  -- `stacks` stacks of block, the turtle holding o.inv.
  local function builder(o)
    o = o or {}
    sim.reset{ gps = false, turtle = { x = 0, y = 31, z = 0, h = 2, fuel = o.fuel or 50000, inv = o.inv },
               terrain = o.terrain }
    h.saveState(2)
    sim.set(0, 30, 0, "minecraft:chest")
    local chest = sim.chests[sim.key(0, 30, 0)]
    for i = 1, o.stacks or 20 do chest.items[i] = { name = o.block or BRICKS, count = 64 } end
    local nav, build = require("bot.nav"), require("bot.build")
    nav.init()
    return nav, build, chest
  end

  test("buildSphere: a hollow ball is exactly its shell, from a chest at home; nothing dug, ends above it", function()
    local _, build = builder()
    local r = build.sphere({ x = 10, y = 45, z = 8, diameter = 9, block = BRICKS, fill = "hollow", supply = "home",
                             part = 1, parts = 1 })
    truthy(r.ok, tostring(r.error))
    local shape = require("bot.shape")
    local s = shape.ball(10, 45, 8, 9)
    local cells, n = structure(shape, s, "hollow")
    built(s, cells, BRICKS, "hollow ball")
    eq(r.placed, n) eq(#sim.dugLog, 0, "dug")
    eq(sim.t.y, shape.highest(s) + 2, "ends above")
    local open = shape.cut(shape.ball(10, 45, 8, 9), 47, 43)
    local _, build2 = builder()
    local r2 = build2.sphere({ x = 10, y = 45, z = 8, diameter = 9, block = BRICKS, fill = "hollow", supply = "home",
                               top = 47, bottom = 43, part = 1, parts = 1 })
    truthy(r2.ok, tostring(r2.error))
    built(open, (structure(shape, open, "hollow")), BRICKS, "cut ball")
    eq(sim.get(10, 47, 8), nil, "a cut is open: no lid")
  end)

  test("buildSphere touching=yes: lines a bowl dug half into the ground, not its rim in open air", function()
    -- <Claude> Stone up to y=30, the bowl (a ball cut at 34, center y=31) already dug.
    local shape = require("bot.shape")
    local s = shape.cut(shape.ball(10, 31, 8, 9), 34)
    local function ground(x, y, z) return y <= 30 and not shape.inside(s, x, y, z) end
    local _, build = builder({ terrain = function(x, y, z) if ground(x, y, z) then return "minecraft:stone" end end })
    local r = build.sphere({ x = 10, y = 31, z = 8, diameter = 9, block = BRICKS, fill = "hollow", top = 34,
                             supply = "home", touching = "yes", part = 1, parts = 1 })
    truthy(r.ok, tostring(r.error))
    local want, n, shell = {}, 0, 0
    for k in pairs((structure(shape, s, "hollow"))) do
      local x, y, z = h.at(k)
      shell = shell + 1
      if ground(x, y - 1, z) or ground(x - 1, y, z) or ground(x + 1, y, z) or ground(x, y, z - 1) or ground(x, y, z + 1) then
        want[k], n = true, n + 1
      end
    end
    built(s, want, BRICKS, "lining")
    eq(r.placed, n) eq(r.bare, shell - n)
    truthy(n > 0 and shell - n > 0, "some placed, some bare")
    for _, k in ipairs(sim.dugLog) do truthy(shape.inside(s, h.at(k)), "dug outside the bowl at " .. k) end
  end)

  test("buildBox: hollow, walls, solid and a flat rectangle are exactly their blocks", function()
    local cases = { { "hollow", 4, 40, 3, 9, 44, 7 }, { "walls", 4, 40, 3, 9, 44, 7 }, { "solid", 5, 40, 2, 8, 42, 6 },
                    { "hollow", 3, 50, -4, 12, 50, 2 }, { "hollow", 3, 40, 3, 4, 41, 15 } }
    for _, c in ipairs(cases) do
      local _, build = builder()
      local r = build.box({ x1 = c[2], y1 = c[3], z1 = c[4], x2 = c[5], y2 = c[6], z2 = c[7], block = BRICKS,
                            fill = c[1], supply = "home", part = 1, parts = 1 })
      local tag = c[1] .. " " .. table.concat(c, ",", 2)
      truthy(r.ok, tag .. ": " .. tostring(r.error))
      local shape = require("bot.shape")
      local s = shape.box(c[2], c[3], c[4], c[5], c[6], c[7])
      local cells, n = structure(shape, s, c[1])
      built(s, cells, BRICKS, tag)
      eq(r.placed, n, tag .. ": placed") eq(#sim.dugLog, 0, tag .. ": dug")
    end
  end)

  test("build refills from a chest at x,y,z: a turtle with little room makes several trips, keeps its own items", function()
    local own = {}
    for slot = 1, 13 do own[slot] = { "minecraft:diamond", 1 } end
    local _, build = builder({ inv = own, stacks = 0 })
    sim.set(-6, 31, 4, "minecraft:chest")
    local chest = sim.chests[sim.key(-6, 31, 4)]
    for i = 1, 10 do chest.items[i] = { name = BRICKS, count = 64 } end
    local r = build.box({ x1 = 3, y1 = 40, z1 = 3, x2 = 14, y2 = 45, z2 = 14, block = BRICKS, fill = "hollow",
                          supply = "-6,31,4", part = 1, parts = 1 })
    truthy(r.ok, tostring(r.error))
    truthy(r.trips >= 3, "trips " .. tostring(r.trips))
    local shape = require("bot.shape")
    local s = shape.box(3, 40, 3, 14, 45, 14)
    built(s, (structure(shape, s, "hollow")), BRICKS, "refilled box")
    local diamonds = 0
    for _, it in pairs(sim.t.inv) do if it.name == "minecraft:diamond" then diamonds = diamonds + it.count end end
    eq(diamonds, 13, "own items kept")
  end)

  test("build shares: tiles make the whole shell; each turtle stays in its tile, above the ball or outside it", function()
    local own = {} -- room for one stack: refills in the middle of every share
    for slot = 1, 15 do own[slot] = { "minecraft:diamond", 1 } end
    local _, build = builder({ stacks = 40, inv = own })
    local shape = require("bot.shape")
    local s = shape.ball(10, 45, 8, 15)
    local safe = shape.highest(s) + 2
    local visited
    sim.onMove = function(t) visited[#visited + 1] = { x = t.x, y = t.y, z = t.z } end
    local seen = {}
    for part = 1, 4 do
      visited = {}
      for slot, it in pairs(sim.t.inv) do if it.name == BRICKS then sim.t.inv[slot] = nil end end -- start each share empty
      local before = #sim.placeLog
      local r = build.sphere({ x = 10, y = 45, z = 8, diameter = 15, block = BRICKS, fill = "hollow", supply = "home",
                               part = part, parts = 4 })
      truthy(r.ok, part .. ": " .. tostring(r.error))
      truthy(r.trips >= 2, ("share %d: %s trips"):format(part, tostring(r.trips)))
      local x1, x2, z1, z2 = math.huge, -math.huge, math.huge, -math.huge
      for i = before + 1, #sim.placeLog do
        local k = sim.placeLog[i]
        truthy(not seen[k], "placed twice: " .. k)
        seen[k] = true
        local x, _, z = h.at(k)
        x1, x2, z1, z2 = math.min(x1, x), math.max(x2, x), math.min(z1, z), math.max(z2, z)
      end
      for _, p in ipairs(visited) do
        local inTile = p.x >= x1 and p.x <= x2 and p.z >= z1 and p.z <= z2
        local column = false -- a block of the ball above or below
        for y = s.y1, s.y2 do column = column or shape.inside(s, p.x, y, p.z) end
        truthy(inTile or p.y >= safe or not column, ("share %d went through %d,%d,%d"):format(part, p.x, p.y, p.z))
      end
    end
    sim.onMove = nil
    built(s, (structure(shape, s, "hollow")), BRICKS, "shares")
    eq(#sim.dugLog, 0, "dug")
  end)

  test("two turtles build their halves of a hollow ball at the same time", function()
    local _, _, B = h.twoTurtles({ 0, 31, 0, 2 }, { 20, 31, 16, 2 })
    for _, p in ipairs({ { 0, 30, 0 }, { 20, 30, 16 } }) do
      sim.set(p[1], p[2], p[3], "minecraft:chest")
      local chest = sim.chests[sim.key(p[1], p[2], p[3])]
      for i = 1, 10 do chest.items[i] = { name = BRICKS, count = 64 } end
    end
    local buildA, buildB = require("bot.build"), B.require("bot.build")
    local function args(part)
      return { x = 10, y = 45, z = 8, diameter = 11, block = BRICKS, fill = "hollow", supply = "home", part = part, parts = 2 }
    end
    local ra, rb = h.both(function() return buildA.sphere(args(1)) end, function() return buildB.sphere(args(2)) end)
    truthy(ra[1].ok, "A: " .. tostring(ra[1].error)) truthy(rb[1].ok, "B: " .. tostring(rb[1].error))
    local shape = require("bot.shape")
    local s = shape.ball(10, 45, 8, 11)
    built(s, (structure(shape, s, "hollow")), BRICKS, "two turtles")
    eq(#sim.dugLog, 0, "dug")
  end)

  test("worker: a build survives reboots at any point and comes out whole", function()
    sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 1, fuel = 20000 }, modem = true, id = 5 }
    sim.set(0, 30, 0, "minecraft:chest")
    local chest = sim.chests[sim.key(0, 30, 0)]
    for i = 1, 6 do chest.items[i] = { name = BRICKS, count = 64 } end
    local sent = false
    sim.onIdle = function()
      if sent then return false end
      sent = true
      sim.deliver(99, { type = "plan", job = "b1", steps = {
        { skill = "buildBox", x1 = 4, y1 = 40, z1 = 3, x2 = 9, y2 = 44, z2 = 8, block = BRICKS },
        { skill = "goHome" } } })
      return true
    end
    local reboots, err = h.runWorkerWithReboots(function(n) return n < 40 and 5 + (n * 11) % 17 or nil end)
    eq(err, "SIM_IDLE")
    truthy(reboots >= 5, "reboots " .. reboots)
    local result = h.lastResult()
    eq(result.job, "b1") eq(result.ok, true, tostring(result.error))
    local shape = require("bot.shape")
    local s = shape.box(4, 40, 3, 9, 44, 8)
    built(s, (structure(shape, s, "hollow")), BRICKS, "after reboots")
    eq(#sim.dugLog, 0, "dug")
    eq(sim.t.x, 0) eq(sim.t.y, 31) eq(sim.t.z, 0)
  end)

  test("build: a block in the way is replaced, a protected one skipped; a supply under the structure is refused", function()
    local _, build = builder()
    sim.set(5, 40, 5, "minecraft:dirt")
    sim.set(6, 40, 5, "minecraft:chest")
    sim.set(7, 40, 5, BRICKS)
    local r = build.box({ x1 = 4, y1 = 40, z1 = 4, x2 = 9, y2 = 42, z2 = 8, block = BRICKS, fill = "hollow",
                          supply = "home", part = 1, parts = 1 })
    truthy(r.ok, tostring(r.error))
    eq(r.skipped, 1, "skipped") eq(r.kept, 1, "kept")
    eq(sim.get(5, 40, 5), BRICKS) eq(sim.get(6, 40, 5), "minecraft:chest")
    eq(#sim.dugLog, 1, "only the dirt dug")
    local r2 = build.box({ x1 = -3, y1 = 40, z1 = -3, x2 = 3, y2 = 42, z2 = 3, block = BRICKS, fill = "hollow",
                           supply = "home", part = 1, parts = 1 })
    eq(r2.ok, false) truthy(tostring(r2.error):find("under the structure", 1, true), tostring(r2.error))
    local r3 = build.box({ x1 = 4, y1 = 40, z1 = 4, x2 = 9, y2 = 42, z2 = 8, block = BRICKS, supply = "nowhere",
                           fill = "hollow", part = 1, parts = 1 })
    eq(r3.ok, false) truthy(tostring(r3.error):find("x,y,z", 1, true), tostring(r3.error))
  end)

  test("build split: turtles sorted along the longer side; for hollow, each side across takes its half", function()
    sim.reset{}
    local positions = { { x = 30, y = 64, z = 50 }, { x = 0, y = 64, z = -50 }, { x = 30, y = 64, z = -50 }, { x = 0, y = 64, z = 50 } }
    local a = { x = 10, y = 45, z = 8, diameter = 11, block = BRICKS, fill = "hollow", supply = "home", part = 1, parts = 1 }
    local parts = skill("buildSphere").split(a, positions)
    eq(parts[2].part, 1) eq(parts[3].part, 2) eq(parts[4].part, 3) eq(parts[1].part, 4)
    for i = 1, 4 do eq(parts[i].parts, 4) eq(parts[i].block, BRICKS) end
    a.fill = "solid"
    parts = skill("buildSphere").split(a, positions)
    eq(parts[2].part + parts[4].part, 3, "the two western turtles take shares 1 and 2")
    local long = { x1 = 0, y1 = 40, z1 = 0, x2 = 3, y2 = 42, z2 = 40, block = BRICKS, fill = "walls", supply = "home",
                   part = 1, parts = 1 }
    local zs = { { x = 0, y = 64, z = 30 }, { x = 0, y = 64, z = 10 } }
    parts = skill("buildBox").split(long, zs)
    eq(parts[1].parts, 2) truthy(parts[1].part ~= parts[2].part, "two shares")
    local cat = require("bot.plan").catalog(require("bot.skills").list)
    truthy(cat:find("- buildSphere(x, y, z, diameter, block, fill=hollow, top=none, bottom=none, supply=home, touching=no):", 1, true), cat)
  end)
end
