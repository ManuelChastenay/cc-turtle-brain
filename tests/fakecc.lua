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
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local function key(x, y, z) return x .. "," .. y .. "," .. z end
sim.key = key

local FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
  ["minecraft:lava_bucket"] = 1000 }
local DROPS = { ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:coal_ore"] = "minecraft:coal",
  ["minecraft:grass_block"] = "minecraft:dirt" }

function sim.reset(o)
  o = o or {}
  sim.terrain = o.terrain or function(x, y, z) if y <= 30 then return "minecraft:stone" end end
  sim.over = {}            -- key -> name or false (air)
  sim.mobs = {}            -- key -> true
  sim.chests = {}          -- key -> { items = {}, cap = n }
  sim.files = {}
  sim.gps = o.gps ~= false
  sim.sleeps, sim.moves, sim.lost, sim.attacks = 0, 0, 0, 0
  sim.dugLog = {}          -- keys dug, in order
  sim.terminateAtMove = nil
  -- computer, events and rednet (see the bottom of this file)
  sim.id, sim.label, sim.modem = o.id or 1, o.label, o.modem or false
  sim.now, sim.events, sim.timers, sim.lastTimer = 0, {}, {}, 0
  sim.sent = {}            -- every rednet message sent: { to, msg, proto }
  sim.onSend, sim.onIdle, sim.onSleep = nil, nil, nil
  local t = o.turtle or {}
  sim.t = { x = t.x or 0, y = t.y or 31, z = t.z or 0, h = t.h or 0, fuel = t.fuel or 1000, limit = 20000,
    inv = {}, sel = 1 }
  for slot, item in pairs(t.inv or {}) do sim.t.inv[slot] = { name = item[1], count = item[2] } end
  sim.over[key(sim.t.x, sim.t.y, sim.t.z)] = false
  for _, b in ipairs(o.blocks or {}) do sim.set(b[1], b[2], b[3], b[4]) end
  for k, mod in pairs(package.loaded) do
    if k:match("^bot%.") or k:match("^llm%.") then package.loaded[k] = nil end
  end
end

function sim.get(x, y, z)
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

local function target(side)
  local t = sim.t
  if side == "up" then return t.x, t.y + 1, t.z end
  if side == "down" then return t.x, t.y - 1, t.z end
  if side == "back" then return t.x - DX[t.h], t.y, t.z - DZ[t.h] end
  if side == "left" then local h = (t.h + 3) % 4 return t.x + DX[h], t.y, t.z + DZ[h] end
  if side == "right" then local h = (t.h + 1) % 4 return t.x + DX[h], t.y, t.z + DZ[h] end
  return t.x + DX[t.h], t.y, t.z + DZ[t.h]
end

local function addItem(name, count)
  local inv = sim.t.inv
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
local function move(side)
  local t = sim.t
  if t.fuel < 1 then return false, "Out of fuel" end
  local x, y, z = target(side)
  if solid(sim.get(x, y, z)) or sim.mobs[key(x, y, z)] then return false, "Movement obstructed" end
  if y > 319 then return false, "Too high to move" end
  t.x, t.y, t.z = x, y, z
  t.fuel = t.fuel - 1
  sim.moves = sim.moves + 1
  if sim.terminateAtMove and sim.moves >= sim.terminateAtMove then error("Terminated", 0) end
  return true
end

local function detect(side) return solid(sim.get(target(side))) end

local function inspect(side)
  local name = sim.get(target(side))
  if not name then return false, "No block to inspect" end
  return true, { name = name, state = {}, tags = {} }
end

local function dig(side)
  local x, y, z = target(side)
  local name = sim.get(x, y, z)
  if not solid(name) then return false, "Nothing to dig here" end
  if name == "minecraft:bedrock" then return false, "Unbreakable block detected" end
  sim.set(x, y, z, nil)
  sim.chests[key(x, y, z)] = nil
  sim.dugLog[#sim.dugLog + 1] = key(x, y, z)
  addItem(DROPS[name] or name, 1)
  settle(x, y, z)
  return true
end

local function attack(side)
  local k = key(target(side))
  sim.attacks = sim.attacks + 1
  if sim.mobs[k] then sim.mobs[k] = nil return true end
  return false, "Nothing to attack here"
end

local function drop(side)
  local it = sim.t.inv[sim.t.sel]
  if not it then return false, "No items to drop" end
  local chest = sim.chests[key(target(side))]
  if not chest then sim.t.inv[sim.t.sel] = nil return true end -- onto the ground
  if #chest.items >= chest.cap then return false, "No space for items" end
  chest.items[#chest.items + 1] = it
  sim.t.inv[sim.t.sel] = nil
  return true
end

_G.turtle = {
  forward = function() return move("front") end,
  back = function() return move("back") end,
  up = function() return move("up") end,
  down = function() return move("down") end,
  turnLeft = function() sim.t.h = (sim.t.h + 3) % 4 return true end,
  turnRight = function() sim.t.h = (sim.t.h + 1) % 4 return true end,
  detect = function() return detect("front") end,
  detectUp = function() return detect("up") end,
  detectDown = function() return detect("down") end,
  inspect = function() return inspect("front") end,
  inspectUp = function() return inspect("up") end,
  inspectDown = function() return inspect("down") end,
  dig = function() return dig("front") end,
  digUp = function() return dig("up") end,
  digDown = function() return dig("down") end,
  attack = function() return attack("front") end,
  attackUp = function() return attack("up") end,
  attackDown = function() return attack("down") end,
  drop = function() return drop("front") end,
  dropUp = function() return drop("up") end,
  dropDown = function() return drop("down") end,
  getFuelLevel = function() return sim.t.fuel end,
  getFuelLimit = function() return sim.t.limit end,
  getSelectedSlot = function() return sim.t.sel end,
  select = function(s) sim.t.sel = s return true end,
  getItemCount = function(s) local it = sim.t.inv[s or sim.t.sel] return it and it.count or 0 end,
  getItemDetail = function(s)
    local it = sim.t.inv[s or sim.t.sel]
    return it and { name = it.name, count = it.count } or nil
  end,
  refuel = function(n)
    local it = sim.t.inv[sim.t.sel]
    if not it then return false, "No items to combust" end
    local v = FUEL[it.name]
    if not v then return false, "Items not combustible" end
    n = n or it.count
    if n == 0 then return true end
    for _ = 1, n do
      if it.count == 0 then break end
      sim.t.fuel = math.min(sim.t.limit, sim.t.fuel + v)
      it.count = it.count - 1
      if it.name == "minecraft:lava_bucket" then it.name, it.count = "minecraft:bucket", 1 break end
    end
    if it.count == 0 then sim.t.inv[sim.t.sel] = nil end
    return true
  end,
}

---------------------------------------------------------------- events, os, parallel
-- The main Lua thread plays CC's top level: when it waits for an event it
-- runs the queue itself (sim.events, then timers in virtual time sim.now,
-- then sim.onIdle() for the test to inject more; nothing left = error
-- "SIM_IDLE"). Inside parallel's coroutines, waiting yields like in CC.
local function isMain()
  local _, main = coroutine.running()
  return main
end

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

-- Real turtle commands yield until the server answers (turtle_response);
-- doing the same here lets the other coroutines run in between.
for _, name in ipairs({ "forward", "back", "up", "down", "turnLeft", "turnRight", "dig", "digUp", "digDown",
    "attack", "attackUp", "attackDown", "drop", "dropUp", "dropDown", "refuel" }) do
  local fn = turtle[name]
  turtle[name] = function(...)
    local r = table.pack(fn(...))
    if not isMain() then
      os.queueEvent("turtle_response")
      os.pullEvent("turtle_response")
    end
    return table.unpack(r, 1, r.n)
  end
end

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

---------------------------------------------------------------- peripherals, files
_G.gps = { locate = function() if sim.gps then return sim.t.x, sim.t.y, sim.t.z end end }

_G.peripheral = {
  getNames = function() return sim.modem and { "left" } or {} end,
  hasType = function(side, t)
    if t == "modem" then return sim.modem and side == "left" end
    if t ~= "inventory" then return nil end
    return sim.chests[key(target(side))] ~= nil
  end,
}

_G.fs = {
  open = function(path, mode)
    if mode == "r" then
      local data = sim.files[path]
      if not data then return nil end
      return { readAll = function() return data end, close = function() end }
    end
    local buf = {}
    return { write = function(s) buf[#buf + 1] = s end, close = function() sim.files[path] = table.concat(buf) end }
  end,
}

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
