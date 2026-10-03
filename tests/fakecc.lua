--[[ <Claude>
  Fake CC: Tweaked environment for testing outside Minecraft. sim.reset{...}
  builds a world (terrain function + overrides) and a turtle; the globals
  turtle, gps, fs, textutils, peripheral, os, parallel, rednet and sleep
  mimic CC closely enough for bot/*, worker.lua, fleet.lua and
  llm/agent.lua (same failure strings as CC, falling gravel, mobs, chests,
  events and virtual time). One simulated computer per test: the other side
  of rednet is scripted through sim.onSend / sim.deliver / sim.onIdle.
  Not a full emulator: check new CC APIs against the CC docs.
]]
local sim = {}
_G.sim = sim

---------------------------------------------------------------- JSON (CC-like)
local json_null = setmetatable({}, { __tostring = function() return "null" end })
local function encode(v)
  local t = type(v)
  if v == nil or v == json_null then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    assert(v == v and v ~= math.huge and v ~= -math.huge, "bad number in JSON")
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.14g", v)
  end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return m[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  assert(t == "table", "cannot encode " .. t)
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n > 0 and #v == n then
    local out = {}
    for i = 1, n do out[i] = encode(v[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do assert(type(k) == "string", "non-string key " .. tostring(k)); keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = encode(k) .. ":" .. encode(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end

local function decode(s)
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local value
  local function str()
    i = i + 1
    local out = {}
    while true do
      local c = s:sub(i, i)
      if c == '"' then i = i + 1 return table.concat(out) end
      if c == "" then error("unterminated string") end
      if c == "\\" then
        local e = s:sub(i + 1, i + 1)
        local m = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
        if e == "u" then out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16) % 256) i = i + 6
        else out[#out + 1] = m[e] or e i = i + 2 end
      else
        out[#out + 1] = c i = i + 1
      end
    end
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      i = i + 1 local t = {} ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        ws() local k = str() ws() assert(s:sub(i, i) == ":", "expected :") i = i + 1
        t[k] = value() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "}" then return t end
        assert(d == ",", "expected , in object")
      end
    elseif c == "[" then
      i = i + 1 local t, n = {}, 0 ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        n = n + 1 t[n] = value() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "]" then return t end
        assert(d == ",", "expected , in array")
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      assert(num and #num > 0, "bad JSON at " .. i .. ": " .. s:sub(i, i + 20))
      i = i + #num
      return tonumber(num)
    end
  end
  local ok, v = pcall(value)
  if not ok then return nil, v end
  return v
end

_G.textutils = {
  json_null = json_null,
  serialiseJSON = encode,
  unserialiseJSON = decode,
}

---------------------------------------------------------------- world
-- Turtles are tables { id, x, y, z, h, fuel, limit, inv, sel, files }.
-- sim.t is the test's main turtle, driven through the global APIs;
-- sim.spawn adds more, each with its own APIs (see sim.spawn).
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local function key(x, y, z) return x .. "," .. y .. "," .. z end
sim.key = key

local FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
  ["minecraft:lava_bucket"] = 1000 }
local DROPS = { ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:coal_ore"] = "minecraft:coal",
  ["minecraft:grass_block"] = "minecraft:dirt", ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
  ["minecraft:iron_ore"] = "minecraft:raw_iron" }

local function isMain()
  local _, main = coroutine.running()
  return main
end

-- t.fuel = "unlimited" plays a server with need_fuel = false.
local function newTurtle(id, t)
  t = t or {}
  local turtle = { id = id, x = t.x or 0, y = t.y or 31, z = t.z or 0, h = t.h or 0, fuel = t.fuel or 1000,
    limit = t.fuel == "unlimited" and "unlimited" or 20000, inv = {}, sel = 1, files = {} }
  for slot, item in pairs(t.inv or {}) do turtle.inv[slot] = { name = item[1], count = item[2] } end
  sim.over[key(turtle.x, turtle.y, turtle.z)] = false -- the cell it stands in is air once it leaves
  return turtle
end

function sim.reset(o)
  o = o or {}
  sim.terrain = o.terrain or function(x, y, z) if y <= 30 then return "minecraft:stone" end end
  sim.over = {}            -- key -> name or false (air)
  sim.mobs = {}            -- key -> true
  sim.chests = {}          -- key -> { items = {}, cap = n }
  sim.gps = o.gps ~= false
  sim.sleeps, sim.moves, sim.lost, sim.attacks = 0, 0, 0, 0
  sim.ground = {}          -- item name -> count dropped on the ground
  sim.dugLog = {}          -- keys dug, in order
  sim.terminateAtMove, sim.terminateAtAction, sim.actions = nil, nil, 0
  -- computer, events and rednet (see below)
  sim.id, sim.label, sim.modem = o.id or 1, o.label, o.modem or false
  sim.now, sim.events, sim.timers, sim.lastTimer = 0, {}, {}, 0
  sim.sent = {}            -- every rednet message sent: { to, msg, proto }
  sim.monitors = {}        -- attached fake monitors (sim.screen), found by peripheral.find("monitor")
  sim.onSend, sim.onIdle, sim.onSleep, sim.onMove = nil, nil, nil, nil
  sim.t = newTurtle(sim.id, o.turtle)
  sim.files = sim.t.files
  sim.turtles = { sim.t }
  for _, b in ipairs(o.blocks or {}) do sim.set(b[1], b[2], b[3], b[4]) end
  for k in pairs(package.loaded) do
    if k:match("^bot%.") or k:match("^llm%.") then package.loaded[k] = nil end
  end
end

function sim.turtleAt(x, y, z)
  for _, t in ipairs(sim.turtles) do
    if t.x == x and t.y == y and t.z == z then return t end
  end
end

-- Block name at a position (other turtles show up as turtle blocks), nil for air.
function sim.get(x, y, z)
  if sim.turtleAt(x, y, z) then return "computercraft:turtle_normal" end
  local v = sim.over[key(x, y, z)]
  if v == false then return nil end
  if v ~= nil then return v end
  return sim.terrain(x, y, z)
end

function sim.set(x, y, z, name)
  sim.over[key(x, y, z)] = name or false
  if name and (name:find("chest") or name:find("barrel")) then
    sim.chests[key(x, y, z)] = { items = {}, cap = 27 }
  end
end

local function liquid(name) return name and (name:find("water") or name:find("lava")) end
local function solid(name) return name ~= nil and not liquid(name) end
local function falling(name) return name and (name:find("gravel") or name:find("sand")) end

local function settle(x, y, z) -- falling blocks above (x,y,z) drop into the gap
  while sim.get(x, y, z) == nil and falling(sim.get(x, y + 1, z)) do
    sim.set(x, y, z, sim.get(x, y + 1, z))
    sim.set(x, y + 1, z, nil)
    y = y + 1
  end
end

-- side: front/back/left/right/up/down (peripheral names top/bottom accepted too)
local function target(t, side)
  if side == "up" or side == "top" then return t.x, t.y + 1, t.z end
  if side == "down" or side == "bottom" then return t.x, t.y - 1, t.z end
  if side == "back" then return t.x - DX[t.h], t.y, t.z - DZ[t.h] end
  if side == "left" then local h = (t.h + 3) % 4 return t.x + DX[h], t.y, t.z + DZ[h] end
  if side == "right" then local h = (t.h + 1) % 4 return t.x + DX[h], t.y, t.z + DZ[h] end
  return t.x + DX[t.h], t.y, t.z + DZ[t.h]
end

local function addItem(t, name, count)
  local inv = t.inv
  for slot = 1, 16 do
    local it = inv[slot]
    if it and it.name == name and it.count < 64 then
      local n = math.min(count, 64 - it.count)
      it.count, count = it.count + n, count - n
      if count == 0 then return end
    end
  end
  for slot = 1, 16 do
    if not inv[slot] then
      inv[slot] = { name = name, count = math.min(64, count) }
      count = count - inv[slot].count
      if count == 0 then return end
    end
  end
  sim.lost = sim.lost + count
end

---------------------------------------------------------------- turtle API
local function move(t, side)
  local unlimited = t.fuel == "unlimited"
  if not unlimited and t.fuel < 1 then return false, "Out of fuel" end
  local x, y, z = target(t, side)
  if solid(sim.get(x, y, z)) or sim.mobs[key(x, y, z)] then return false, "Movement obstructed" end
  if y > 319 then return false, "Too high to move" end
  t.x, t.y, t.z = x, y, z
  if not unlimited then t.fuel = t.fuel - 1 end
  sim.moves = sim.moves + 1
  if sim.onMove then sim.onMove(t) end -- may raise "Terminated" to play a reboot
  if sim.terminateAtMove and sim.moves >= sim.terminateAtMove then error("Terminated", 0) end
  return true
end

local function detect(t, side) return solid(sim.get(target(t, side))) end

local function inspect(t, side)
  local name = sim.get(target(t, side))
  if not name then return false, "No block to inspect" end
  return true, { name = name, state = {}, tags = {} }
end

local function dig(t, side)
  local x, y, z = target(t, side)
  local name = sim.get(x, y, z)
  if not solid(name) then return false, "Nothing to dig here" end
  if name == "minecraft:bedrock" or sim.turtleAt(x, y, z) then return false, "Unbreakable block detected" end
  sim.set(x, y, z, nil)
  sim.chests[key(x, y, z)] = nil
  sim.dugLog[#sim.dugLog + 1] = key(x, y, z)
  addItem(t, DROPS[name] or name, 1)
  settle(x, y, z)
  return true
end

local function attack(t, side)
  local k = key(target(t, side))
  sim.attacks = sim.attacks + 1
  if sim.mobs[k] then sim.mobs[k] = nil return true end
  return false, "Nothing to attack here"
end

local function drop(t, side, count)
  local it = t.inv[t.sel]
  if not it then return false, "No items to drop" end
  count = math.min(count or it.count, it.count)
  local chest = sim.chests[key(target(t, side))]
  if chest and #chest.items >= chest.cap then return false, "No space for items" end
  if chest then
    chest.items[#chest.items + 1] = { name = it.name, count = count }
  else
    sim.ground[it.name] = (sim.ground[it.name] or 0) + count
  end
  it.count = it.count - count
  if it.count == 0 then t.inv[t.sel] = nil end
  return true
end

-- Turtle API for whichever turtle get() returns. Commands that take a tick
-- in CC yield until a turtle_response event (inside coroutines), so other
-- coroutines and turtles run in between, like in the game.
local function makeTurtle(get)
  local api = {
    forward = function() return move(get(), "front") end,
    back = function() return move(get(), "back") end,
    up = function() return move(get(), "up") end,
    down = function() return move(get(), "down") end,
    turnLeft = function() local t = get() t.h = (t.h + 3) % 4 return true end,
    turnRight = function() local t = get() t.h = (t.h + 1) % 4 return true end,
    detect = function() return detect(get(), "front") end,
    detectUp = function() return detect(get(), "up") end,
    detectDown = function() return detect(get(), "down") end,
    inspect = function() return inspect(get(), "front") end,
    inspectUp = function() return inspect(get(), "up") end,
    inspectDown = function() return inspect(get(), "down") end,
    dig = function() return dig(get(), "front") end,
    digUp = function() return dig(get(), "up") end,
    digDown = function() return dig(get(), "down") end,
    attack = function() return attack(get(), "front") end,
    attackUp = function() return attack(get(), "up") end,
    attackDown = function() return attack(get(), "down") end,
    drop = function(n) return drop(get(), "front", n) end,
    dropUp = function(n) return drop(get(), "up", n) end,
    dropDown = function(n) return drop(get(), "down", n) end,
    getFuelLevel = function() return get().fuel end,
    getFuelLimit = function() return get().limit end,
    getSelectedSlot = function() return get().sel end,
    select = function(s) get().sel = s return true end,
    getItemCount = function(s) local t = get() local it = t.inv[s or t.sel] return it and it.count or 0 end,
    getItemDetail = function(s)
      local t = get()
      local it = t.inv[s or t.sel]
      return it and { name = it.name, count = it.count } or nil
    end,
    refuel = function(n)
      local t = get()
      local it = t.inv[t.sel]
      if not it then return false, "No items to combust" end
      local v = FUEL[it.name]
      if not v then return false, "Items not combustible" end
      n = n or it.count
      if n == 0 then return true end
      for _ = 1, n do
        if it.count == 0 then break end
        t.fuel = math.min(t.limit, t.fuel + v)
        it.count = it.count - 1
        if it.name == "minecraft:lava_bucket" then it.name, it.count = "minecraft:bucket", 1 break end
      end
      if it.count == 0 then t.inv[t.sel] = nil end
      return true
    end,
  }
  for _, name in ipairs({ "forward", "back", "up", "down", "turnLeft", "turnRight", "dig", "digUp", "digDown",
      "attack", "attackUp", "attackDown", "drop", "dropUp", "dropDown", "refuel" }) do
    local fn = api[name]
    api[name] = function(...)
      local r = table.pack(fn(...))
      sim.actions = sim.actions + 1 -- a reboot "at" an action: it happened, the program never heard back
      if sim.terminateAtAction and sim.actions >= sim.terminateAtAction then error("Terminated", 0) end
      if not isMain() then
        os.queueEvent("turtle_response")
        os.pullEvent("turtle_response")
      end
      return table.unpack(r, 1, r.n)
    end
  end
  return api
end

_G.turtle = makeTurtle(function() return sim.t end)

-- Peripherals around a turtle: chests ("inventory"), a modem on the left if
-- modem() is true, and adjacent turtles (getID), as CC exposes computers.
local function makePeripheral(get, modem)
  return {
    getNames = function() return modem() and { "left" } or {} end,
    hasType = function(side, ty)
      if ty == "modem" then return modem() and side == "left" end
      if ty ~= "inventory" then return nil end
      return sim.chests[key(target(get(), side))] ~= nil
    end,
    call = function(side, method)
      local other = sim.turtleAt(target(get(), side))
      if other and method == "getID" then return other.id end
      error("No peripheral attached", 2)
    end,
    find = function(ty)
      if ty == "monitor" then return table.unpack(sim.monitors) end
    end,
    getName = function(p) return p.side end,
  }
end

local function makeFs(files)
  return {
    open = function(path, mode)
      local store = files()
      if mode == "r" then
        local data = store[path]
        if not data then return nil end
        return { readAll = function() return data end, close = function() end }
      end
      local buf = {}
      return { write = function(s) buf[#buf + 1] = s end, close = function() store[path] = table.concat(buf) end }
    end,
    delete = function(path) files()[path] = nil end,
  }
end

-- The main computer reboots: programs and modules are gone, its event queue
-- is cleared; files, the world and the turtle's position stay.
function sim.reboot()
  for k in pairs(package.loaded) do
    if k:match("^bot%.") or k:match("^llm%.") then package.loaded[k] = nil end
  end
  sim.events, sim.timers = {}, {}
  sim.terminateAtMove, sim.terminateAtAction = nil, nil
end

-- Another turtle in the same world, with its own APIs, files and computer id.
-- Its modules load from the repo into its own environment: t.require("bot.nav").
-- Events and timers are shared, so run turtles side by side with parallel.
function sim.spawn(id, o)
  local t = newTurtle(id, o)
  sim.turtles[#sim.turtles + 1] = t
  local env = setmetatable({}, { __index = _G })
  env.turtle = makeTurtle(function() return t end)
  env.gps = { locate = function() if sim.gps then return t.x, t.y, t.z end end }
  env.peripheral = makePeripheral(function() return t end, function() return false end)
  env.fs = makeFs(function() return t.files end)
  env.os = setmetatable({ getComputerID = function() return t.id end }, { __index = os })
  local loaded = {}
  env.require = function(name)
    if loaded[name] == nil then
      loaded[name] = assert(loadfile(REPO .. name:gsub("%.", "/") .. ".lua", "t", env))(name)
    end
    return loaded[name]
  end
  t.require = env.require
  return t
end

---------------------------------------------------------------- events, os, parallel
-- The main Lua thread plays CC's top level: when it waits for an event it
-- runs the queue itself (sim.events, then timers in virtual time sim.now,
-- then sim.onIdle() for the test to inject more; nothing left = error
-- "SIM_IDLE"). Inside parallel's coroutines, waiting yields like in CC.
local function nextEvent()
  while true do
    local ev = table.remove(sim.events, 1)
    if ev then return ev end
    if #sim.timers > 0 then
      table.sort(sim.timers, function(a, b) return a.at < b.at end)
      local t = table.remove(sim.timers, 1)
      sim.now = math.max(sim.now, t.at)
      if sim.now > 3600 then error("SIM_TIMEOUT: over an hour of virtual time", 0) end
      return table.pack("timer", t.id)
    end
    if not (sim.onIdle and sim.onIdle()) then error("SIM_IDLE", 0) end
  end
end

os.clock = function() return sim.now end
os.epoch = function() return math.floor(sim.now * 1000) end
os.getComputerID = function() return sim.id end
os.getComputerLabel = function() return sim.label end
os.queueEvent = function(...) sim.events[#sim.events + 1] = table.pack(...) end
os.startTimer = function(t)
  sim.lastTimer = sim.lastTimer + 1
  sim.timers[#sim.timers + 1] = { id = sim.lastTimer, at = sim.now + t }
  return sim.lastTimer
end
os.cancelTimer = function(id)
  for i, t in ipairs(sim.timers) do
    if t.id == id then table.remove(sim.timers, i) return end
  end
end
os.pullEventRaw = function(filter)
  if not isMain() then return coroutine.yield(filter) end
  while true do
    local ev = nextEvent()
    if filter == nil or ev[1] == filter then return table.unpack(ev, 1, ev.n) end
  end
end
os.pullEvent = function(filter)
  local ev = table.pack(os.pullEventRaw(filter))
  if ev[1] == "terminate" then error("Terminated", 0) end
  return table.unpack(ev, 1, ev.n)
end

local function runAll(fns, any)
  local cos, filters, alive = {}, {}, #fns
  for i, fn in ipairs(fns) do cos[i] = coroutine.create(fn) end
  local function resume(i, ev)
    local co = cos[i]
    if not co then return false end
    if ev and filters[i] and filters[i] ~= ev[1] and ev[1] ~= "terminate" then return false end
    local res = ev and table.pack(coroutine.resume(co, table.unpack(ev, 1, ev.n))) or table.pack(coroutine.resume(co))
    if not res[1] then error(res[2], 0) end
    if coroutine.status(co) == "dead" then cos[i], alive = nil, alive - 1 return true end
    filters[i] = res[2]
    return false
  end
  for i = 1, #fns do if resume(i) and any then return i end end
  while alive > 0 do
    local ev = isMain() and nextEvent() or table.pack(coroutine.yield())
    for i = 1, #fns do if resume(i, ev) and any then return i end end
  end
end
_G.parallel = {
  waitForAny = function(...) return runAll({ ... }, true) end,
  waitForAll = function(...) runAll({ ... }, false) end,
}

---------------------------------------------------------------- rednet
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- Test side: a message arriving at this computer.
function sim.deliver(from, msg, proto)
  os.queueEvent("rednet_message", from, copy(msg), proto or "ccbrain")
end

local function send(to, msg, proto)
  msg = copy(msg)
  sim.sent[#sim.sent + 1] = { to = to, msg = msg, proto = proto }
  if sim.onSend then sim.onSend(to, msg, proto) end
  return true
end

_G.rednet = {
  open = function() end,
  send = send,
  broadcast = function(msg, proto) send("broadcast", msg, proto) end,
  receive = function(proto, timeout)
    local timer = timeout and os.startTimer(timeout)
    while true do
      local ev = table.pack(os.pullEvent())
      if ev[1] == "rednet_message" and (proto == nil or ev[4] == proto) then
        if timer then os.cancelTimer(timer) end
        return ev[2], ev[3], ev[4]
      elseif ev[1] == "timer" and ev[2] == timer then
        return nil
      end
    end
  end,
}

---------------------------------------------------------------- screens
_G.colors = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, gray = 128,
  lightGray = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
_G.keys = { enter = 257, numPadEnter = 335, backspace = 259, delete = 261, left = 263, right = 262, up = 265,
  down = 264, home = 268, ["end"] = 269 }

-- A fake terminal or monitor: a w x h grid of characters with the colors set
-- when each was written. screen.lines() gives the rows as strings, and
-- screen.at(x, y) the { char, fg, bg } of a cell. Monitors (color = true is an
-- advanced one) also have setTextScale; sim.useTerm(w, h) makes one the
-- global `term`, sim.addMonitor(w, h, side) attaches one for peripheral.find.
function sim.screen(w, h, color, side)
  local s = { w = w, h = h, side = side, scale = 1, blink = false, cx = 1, cy = 1, fg = 1, bg = 32768 }
  local grid
  local function blank()
    grid = {}
    for y = 1, h do
      grid[y] = {}
      for x = 1, w do grid[y][x] = { " ", 1, 32768 } end
    end
  end
  blank()
  s.getSize = function() return s.w, s.h end
  s.isColor = function() return color == true end
  s.isColour = s.isColor
  s.setCursorPos = function(x, y) s.cx, s.cy = x, y end
  s.getCursorPos = function() return s.cx, s.cy end
  s.setCursorBlink = function(b) s.blink = b end
  s.setTextColor = function(c) s.fg = c end
  s.setBackgroundColor = function(c) s.bg = c end
  s.setTextScale = function(n)
    if type(n) ~= "number" or n < 0.5 or n > 5 or n * 2 ~= math.floor(n * 2) then error("Expected number in range 0.5-5", 2) end
    s.scale = n
  end
  s.write = function(text)
    text = tostring(text)
    for i = 1, #text do
      local cell = grid[s.cy] and grid[s.cy][s.cx]
      if cell then cell[1], cell[2], cell[3] = text:sub(i, i), s.fg, s.bg end
      s.cx = s.cx + 1
    end
  end
  s.clear = blank
  s.clearLine = function()
    for x = 1, w do grid[s.cy][x] = { " ", 1, 32768 } end
  end
  s.at = function(x, y) return table.unpack(grid[y][x]) end
  s.lines = function()
    local rows = {}
    for y = 1, h do
      local row = {}
      for x = 1, w do row[x] = grid[y][x][1] end
      rows[y] = table.concat(row)
    end
    return rows
  end
  return s
end

function sim.useTerm(w, h, color)
  _G.term = sim.screen(w, h, color)
  return _G.term
end

function sim.addMonitor(w, h, side, color)
  local m = sim.screen(w, h, color ~= false, side or "top")
  sim.monitors[#sim.monitors + 1] = m
  return m
end

---------------------------------------------------------------- peripherals, files
_G.gps ={ locate = function() if sim.gps then return sim.t.x, sim.t.y, sim.t.z end end }
_G.peripheral = makePeripheral(function() return sim.t end, function() return sim.modem end)
_G.fs = makeFs(function() return sim.t.files end)

_G.sleep = function(t)
  sim.sleeps = sim.sleeps + 1
  if sim.onSleep then sim.onSleep() end
  if isMain() then sim.now = sim.now + (t or 0) return end
  local id = os.startTimer(t or 0)
  repeat local _, fired = os.pullEvent("timer") until fired == id
end
_G.print = print
_G.printError = function(...) print("ERR", ...) end

return sim
