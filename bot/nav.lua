--[[ <Claude>
  Position, heading, movement and fuel. Position is tracked by dead
  reckoning and saved after every move or turn, so it survives reboots.
  With GPS (wireless modem + GPS hosts), init() resets the position and
  calibrates the heading by stepping one block and back.
  Moves dig through anything except protected blocks (bot/config.lua).
  Functions return ok, err and never throw.
  Headings: 0 north (-z), 1 east (+x), 2 south (+z), 3 west (-x).
]]
local config = require("bot.config")

local M = {}

local NAMES   = { [0] = "north", "east", "south", "west" }
local COMPASS = { north = 0, east = 1, south = 2, west = 3 }
local TURNS   = { forward = 0, right = 1, back = 2, left = 3 }
local DX, DZ  = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local TOWARD  = { x = { [true] = 1, [false] = 3 }, z = { [true] = 2, [false] = 0 } }

local MOVE    = { forward = turtle.forward, up = turtle.up,        down = turtle.down }
local DETECT  = { forward = turtle.detect,  up = turtle.detectUp,  down = turtle.detectDown }
local INSPECT = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local DIG     = { forward = turtle.dig,     up = turtle.digUp,     down = turtle.digDown }
local ATTACK  = { forward = turtle.attack,  up = turtle.attackUp,  down = turtle.attackDown }

local NO_HEADING = "heading unknown (no GPS fix to calibrate it)"

local pos, heading, home, hasGps = { x = 0, y = 0, z = 0 }, nil, nil, false
M.dug = 0 -- blocks dug since boot; skills report the difference

local function save()
  local f = fs.open(config.statePath, "w")
  if not f then return end
  f.write(textutils.serialiseJSON({ pos = pos, heading = heading, home = home }))
  f.close()
end

local function load()
  local f = fs.open(config.statePath, "r")
  if not f then return {} end
  local data = textutils.unserialiseJSON(f.readAll())
  f.close()
  return type(data) == "table" and data or {}
end

local function matches(name, patterns)
  for _, p in ipairs(patterns) do
    if name:find(p, 1, true) then return true end
  end
  return false
end

local function locate()
  local x, y, z = gps.locate(2)
  if not x then return nil end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

function M.pos() return { x = pos.x, y = pos.y, z = pos.z } end
function M.heading() return heading end
function M.vector(h) return DX[h], DZ[h] end

function M.distance(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

function M.home()
  return home and { x = home.x, y = home.y, z = home.z, heading = home.heading }
end

function M.setHome()
  home = { x = pos.x, y = pos.y, z = pos.z, heading = heading }
  save()
end

-- <Claude> "pos 1,2,3 facing east; home 1,2,3, 0 blocks away"
function M.describe()
  local text = ("pos %d,%d,%d facing %s"):format(pos.x, pos.y, pos.z, heading and NAMES[heading] or "unknown")
  if not hasGps then text = text .. " (no GPS: dead reckoning)" end
  if home then
    text = text .. ("; home %d,%d,%d, %d blocks away"):format(home.x, home.y, home.z, M.distance(pos, home))
  end
  return text
end

---------------------------------------------------------------- fuel

function M.fuel()
  local level = turtle.getFuelLevel()
  return level == "unlimited" and math.huge or level
end

function M.isFuel(name) return matches(name, config.fuelItems) end

-- <Claude> Burns fuel items one at a time until the level reaches target
-- (capped at the turtle's fuel limit). Returns whether it got there.
function M.refuel(target)
  if M.fuel() >= target then return true end
  target = math.min(target, turtle.getFuelLimit())
  local selected = turtle.getSelectedSlot()
  for slot = 1, 16 do
    local item = M.fuel() < target and turtle.getItemDetail(slot)
    if item and M.isFuel(item.name) then
      turtle.select(slot)
      while M.fuel() < target and turtle.refuel(1) do end
    end
  end
  turtle.select(selected)
  return M.fuel() >= target
end

---------------------------------------------------------------- heading

-- <Claude> Steps one block into free space (forward or back, turning if both
-- are blocked), compares GPS fixes, then puts the turtle back as it was.
-- Never digs. Returns the heading, or nil.
local function calibrate()
  if not M.refuel(2) then return nil end
  local start = M.pos()
  for turns = 0, 3 do
    local sign = turtle.forward() and 1 or (turtle.back() and -1)
    if sign then
      local moved = locate()
      if sign == 1 then turtle.back() else turtle.forward() end
      pos = locate() or pos
      for _ = 1, turns do turtle.turnLeft() end
      if not moved then return nil end
      local dx, dz = (moved.x - start.x) * sign, (moved.z - start.z) * sign
      for h = 0, 3 do
        if DX[h] == dx and DZ[h] == dz then return (h - turns) % 4 end
      end
      return nil
    end
    turtle.turnRight()
  end
  return nil
end

-- <Claude> Call once per program start. With GPS: fresh position and heading
-- (falls back to the saved heading if the turtle cannot step and has not
-- moved). Without GPS: saved state, or 0,0,0 facing "north" on first run.
-- Home defaults to the first position ever seen.
function M.init()
  local saved = load()
  local fix = locate()
  hasGps = fix ~= nil
  if fix then
    pos = fix
    heading = calibrate()
    if heading == nil and saved.pos and M.distance(saved.pos, pos) == 0 then heading = saved.heading end
  else
    pos = saved.pos or pos
    heading = saved.heading or 0
  end
  home = saved.home or { x = pos.x, y = pos.y, z = pos.z, heading = heading }
  save()
end

-- <Claude> Compass names, or forward/right/back/left relative to now.
function M.resolve(dir)
  if COMPASS[dir] then return COMPASS[dir] end
  if not TURNS[dir] then return nil, "bad direction " .. tostring(dir) end
  if not heading then return nil, NO_HEADING end
  return (heading + TURNS[dir]) % 4
end

local function turn(right)
  if right then turtle.turnRight() else turtle.turnLeft() end
  heading = (heading + (right and 1 or 3)) % 4
  save()
end

function M.face(h)
  if not heading then return false, NO_HEADING end
  local diff = (h - heading) % 4
  if diff == 3 then turn(false) else for _ = 1, diff do turn(true) end end
  return true
end

---------------------------------------------------------------- movement

local TURTLE_IN_WAY = "another turtle is in the way"

-- <Claude> Clears the block on side ("forward", "up", "down"). Air and liquids
-- count as clear. Loops because gravel and sand fall back into the gap.
function M.dig(side)
  for _ = 1, 32 do
    if not DETECT[side]() then return true end
    local _, block = INSPECT[side]()
    local name = type(block) == "table" and block.name or "unknown"
    if name:find("computercraft:turtle", 1, true) then return false, TURTLE_IN_WAY end
    if matches(name, config.protect) then return false, "protected block in the way: " .. name end
    local ok, reason = DIG[side]()
    if not ok then return false, ("cannot dig %s: %s"):format(name, tostring(reason)) end
    M.dug = M.dug + 1
    if matches(name, config.falling) then sleep(0.5) end
  end
  return false, "blocks keep falling in"
end

-- <Claude> One block forward/up/down, digging first. An obstruction with no
-- block is a mob or player: wait, then attack. Another turtle in the way:
-- wait for it to move on (random delays so two turtles meeting head-on do
-- not retry in lockstep), then give up.
function M.step(side)
  if side == "forward" and not heading then return false, NO_HEADING end
  if M.fuel() < 1 and not M.refuel(1) then return false, "out of fuel" end
  local obstructed, waited = 0, 0
  while true do
    local cleared, err = M.dig(side)
    if cleared then
      local moved, reason = MOVE[side]()
      if moved then
        if side == "up" then pos.y = pos.y + 1
        elseif side == "down" then pos.y = pos.y - 1
        else pos.x, pos.z = pos.x + DX[heading], pos.z + DZ[heading] end
        save()
        return true
      end
      if reason ~= "Movement obstructed" then return false, reason end
      obstructed = obstructed + 1
      if obstructed > 8 then return false, ("path blocked at %d,%d,%d"):format(pos.x, pos.y, pos.z) end
      if obstructed > 2 then ATTACK[side]() end
      sleep(0.5)
    elseif err == TURTLE_IN_WAY and waited < config.turtleWaits then
      waited = waited + 1
      sleep(0.5 + math.random())
    else
      return false, err
    end
  end
end

-- <Claude> Walks axis by axis in `order` (default: climb first, descend last).
function M.goTo(target, order)
  order = order or (target.y > pos.y and "yxz" or "xzy")
  for axis in order:gmatch(".") do
    while pos[axis] ~= target[axis] do
      local ok, err
      if axis == "y" then
        ok, err = M.step(target.y > pos.y and "up" or "down")
      else
        ok, err = M.face(TOWARD[axis][target[axis] > pos[axis]])
        if ok then ok, err = M.step("forward") end
      end
      if not ok then return false, err end
    end
  end
  return true
end

return M
