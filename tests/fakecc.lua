--[[ <Claude>
  Fake CC: Tweaked environment for testing outside Minecraft. sim.reset{...}
  builds a world (terrain function + overrides) and a turtle; the globals
  turtle, gps, fs, textutils, peripheral and sleep mimic CC closely enough
  for bot/* and llm/agent.lua (same failure strings as CC, falling gravel,
  mobs, chests). Not a full emulator: check new turtle APIs against the CC docs.
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

_G.gps = { locate = function() if sim.gps then return sim.t.x, sim.t.y, sim.t.z end end }

_G.peripheral = {
  hasType = function(side, t)
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

_G.sleep = function() sim.sleeps = sim.sleeps + 1 end
_G.print = print
_G.printError = function(...) print("ERR", ...) end

return sim
