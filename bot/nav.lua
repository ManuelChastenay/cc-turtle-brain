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
-- <Claude> { pos, heading } before a calibration, saved until the turtle is
-- back there: a reboot mid-calibration can then be undone on the next start.
local calibrating = nil
local turning = nil -- true while a turn is under way
M.dug = 0 -- blocks dug since boot; skills report the difference

local function save()
  local f = fs.open(config.statePath, "w")
  if not f then return end
  f.write(textutils.serialiseJSON({ pos = pos, heading = heading, home = home, calibrating = calibrating,
                                    turning = turning }))
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

-- <Claude> Tries every slot, not only config.fuelItems: anything that burns
-- (planks, logs, sticks...) goes into the tank, up to the fuel limit (CC
-- burns no more of a stack than fits). Returns the fuel gained.
function M.refuelAll()
  local before = M.fuel()
  if before == math.huge then return 0 end
  local selected = turtle.getSelectedSlot()
  for slot = 1, 16 do
    if M.fuel() >= turtle.getFuelLimit() then break end
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      turtle.refuel() -- false for items that do not burn
    end
  end
  turtle.select(selected)
  return M.fuel() - before
end

---------------------------------------------------------------- heading

-- <Claude> Steps one block forward or back into free space (turning if both
-- are blocked), compares GPS fixes, then steps back and turns back.
-- Returns the heading the turtle has, or nil.
local function measure()
  local start = locate()
  if not start then return nil end
  for turns = 0, 3 do
    local sign = turtle.forward() and 1 or (turtle.back() and -1)
    if sign then
      local moved = locate()
      if sign == 1 then turtle.back() else turtle.forward() end
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

-- <Claude> Last resort when there is no room to step: digs one block (never
-- a protected block or a turtle), measures through it, turns back.
local function digAndMeasure()
  for turns = 0, 3 do
    if turns > 0 then turtle.turnRight() end
    if M.dig("forward") then
      local h = measure()
      for _ = 1, turns do turtle.turnLeft() end
      return h and (h - turns) % 4
    end
  end
  turtle.turnRight() -- full circle: facing as before
  return nil
end

-- <Claude> Measures the heading where the turtle stands or, if it is boxed
-- in there, one block up or down (vertical steps do not depend on heading),
-- then puts it back as it was. Digs only if mayDig and there is no room at
-- all (one block). Returns the heading, or nil.
-- Where the turtle stood and faced is saved first (`calibrating`, kept if an
-- earlier cut-off calibration is still to undo): a reboot before the step
-- back would otherwise leave it one block off and turned for good. M.init
-- undoes it.
local function calibrate(mayDig)
  M.refuel(4)
  if M.fuel() < 2 then return nil end
  calibrating = calibrating or { pos = M.pos(), heading = heading }
  save()
  -- <Claude> Cut-off calibrations must not add up (each one could leave the
  -- turtle a block higher): start from the first one's level.
  local level = calibrating.pos.y
  while pos.y > level and turtle.down() do pos.y = pos.y - 1 end
  while pos.y < level and turtle.up() do pos.y = pos.y + 1 end
  local measured = measure()
  for _, steps in ipairs({ { turtle.up, turtle.down }, { turtle.down, turtle.up } }) do
    if measured or M.fuel() < 4 then break end
    if steps[1]() then
      measured = measure()
      steps[2]()
    end
  end
  if not measured and mayDig then measured = digAndMeasure() end
  pos = locate() or pos
  return measured
end

-- <Claude> Call once per program start. With GPS: fresh position and heading.
-- If the turtle cannot step to calibrate, the saved heading is kept when it
-- is at most one block from the saved position (a reboot can land between a
-- move and its save, and moves do not change heading) and no turn or
-- calibration was cut off; otherwise the heading is unknown and moves fail
-- rather than guess.
-- If the last start's calibration was cut off, the turtle goes back to where
-- it was and faces the way it did. Without GPS: saved state, or 0,0,0 facing
-- "north" on first run; resuming jobs is only exact with GPS. Home defaults
-- to the first position ever seen.
-- trustSaved (when resuming a job): skip calibrating if the saved state is
-- consistent, i.e. no extra moves in the middle of a dig, and no chance for
-- reboots in quick succession to keep cutting calibrations off.
function M.init(trustSaved)
  local saved = load()
  local fix = locate()
  hasGps = fix ~= nil
  local undo = type(saved.calibrating) == "table" and saved.calibrating or nil
  local consistent = saved.heading and not saved.turning and not undo
    and saved.pos and fix and M.distance(saved.pos, fix) <= 1
  if fix and trustSaved and consistent then
    pos, heading = fix, saved.heading
  elseif fix then
    pos, heading = fix, saved.heading -- heading: provisional, kept in the calibration marker
    calibrating = undo -- stays saved while going back, in case that is cut off too
    local measured = calibrate(trustSaved) -- resuming a job: may dig one block if boxed in
    if measured then
      heading = measured
    elseif undo or saved.turning or not (saved.pos and M.distance(saved.pos, pos) <= 1) then
      heading = nil -- a calibration or a turn was cut off, or it moved: the saved heading can't be trusted
    end
    if heading and undo then -- the last calibration was cut off: back to where it started
      if type(undo.pos) == "table" and M.distance(undo.pos, pos) <= 2 then M.goTo(undo.pos) end
      if undo.heading then M.face(undo.heading) end
    end
    calibrating = nil
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

-- <Claude> `turning` is saved during the turn: after a reboot right then,
-- the saved heading may be one turn off (see M.init).
local function turn(right)
  turning = true
  save()
  if right then turtle.turnRight() else turtle.turnLeft() end
  heading, turning = (heading + (right and 1 or 3)) % 4, nil
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
local PERIPHERAL_SIDE = { forward = "front", up = "top", down = "bottom" }

-- <Claude> Optional hook, called with the blocking turtle's id (or nil) while
-- waiting for it. worker.lua uses it to ask an idle turtle to move (makeWay).
M.onTurtleInWay = nil

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

-- <Claude> M.dig, but waits (up to config.turtleWaits tries) while a turtle is there.
function M.clear(side)
  for _ = 1, config.turtleWaits do
    local ok, err = M.dig(side)
    if err ~= TURTLE_IN_WAY then return ok, err end
    sleep(0.5 + math.random())
  end
  return false, TURTLE_IN_WAY
end

-- <Claude> Id of the turtle on side (adjacent computers are peripherals), or nil.
local function turtleId(side)
  local ok, id = pcall(peripheral.call, PERIPHERAL_SIDE[side], "getID")
  return ok and type(id) == "number" and id or nil
end

-- <Claude> One move with no waiting: dig (never turtles or protected blocks), then move.
local function tryMove(side)
  local cleared, err = M.dig(side)
  if not cleared then return false, err end
  local moved, reason = MOVE[side]()
  if not moved then return false, reason end
  if side == "up" then pos.y = pos.y + 1
  elseif side == "down" then pos.y = pos.y - 1
  else pos.x, pos.z = pos.x + DX[heading], pos.z + DZ[heading] end
  save()
  return true
end

-- <Claude> Moves one block off a line running along axis ("x", "y" or "z"):
-- into a free cell if there is one, else digs one. Returns whether it moved.
local function stepAside(axis)
  local options = axis ~= "y" and { { "up" }, { "down" } } or {}
  for h = 0, 3 do
    if heading and (DX[h] ~= 0 and "x" or "z") ~= axis then options[#options + 1] = { "forward", h } end
  end
  for pass = 1, 2 do
    for _, o in ipairs(options) do
      if o[2] then M.face(o[2]) end
      if (pass == 2 or not DETECT[o[1]]()) and tryMove(o[1]) then return true end
    end
  end
  return false
end

local givingWay = false

-- <Claude> Lets the turtle on side through: steps off the line, waits, then
-- comes back to the same cell and facing. Returns ok, err.
local function giveWay(side)
  local spot, facing = M.pos(), heading
  givingWay = true
  local ok, err = true, nil
  if stepAside(side == "forward" and (DX[heading] ~= 0 and "x" or "z") or "y") then
    sleep(2 + 2 * math.random())
    ok, err = M.goTo(spot) -- waits (without giving way again) if the other turtle is passing through it
  end
  if facing then M.face(facing) end
  givingWay = false
  return ok, err
end

-- <Claude> For an idle turtle that another turtle, standing next to it at
-- `from`, asks to clear the way: steps off the line between them.
function M.makeWay(from)
  if type(from) ~= "table" or type(from.x) ~= "number" or type(from.y) ~= "number" or type(from.z) ~= "number"
    or M.distance(pos, from) ~= 1 then
    return false
  end
  local facing = heading
  local moved = stepAside(from.y ~= pos.y and "y" or from.x ~= pos.x and "x" or "z")
  if facing then M.face(facing) end
  return moved
end

-- <Claude> One block forward/up/down, digging first. An obstruction with no
-- block is a mob or player: wait, then attack. Another turtle in the way:
-- wait a little (it is usually passing by), then every few tries the turtle
-- with the higher id steps aside to let the lower one through (a coin flip
-- if the id cannot be read), and onTurtleInWay can ask an idle one to move.
-- Gives up after config.turtleWaits tries.
function M.step(side)
  if side == "forward" and not heading then return false, NO_HEADING end
  if M.fuel() < 1 and not M.refuel(1) then return false, "out of fuel" end
  local obstructed, waited = 0, 0
  while true do
    local moved, err = tryMove(side)
    if moved then return true end
    if err == "Movement obstructed" then
      obstructed = obstructed + 1
      if obstructed > 8 then return false, ("path blocked at %d,%d,%d"):format(pos.x, pos.y, pos.z) end
      if obstructed > 2 then ATTACK[side]() end
      sleep(0.5)
    elseif err == TURTLE_IN_WAY then
      waited = waited + 1
      local other = turtleId(side)
      if waited > config.turtleWaits then
        return false, ("turtle %sin the way for too long"):format(other and ("#" .. other .. " ") or "")
      end
      if waited % 3 == 0 and not givingWay then
        if M.onTurtleInWay then M.onTurtleInWay(other) end
        if (other and other < os.getComputerID()) or (not other and math.random(2) == 1) then
          local back, wayErr = giveWay(side)
          if not back then return false, "could not get back after making way: " .. tostring(wayErr) end
        end
      end
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
