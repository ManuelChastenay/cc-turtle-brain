--[[ <Claude>
  Inventory helpers: free slots, a compact summary for the LLM, dropping
  junk, and unloading into an adjacent chest (anything exposing an
  "inventory" peripheral: chests, barrels, modded storage). Unloading drops
  junk and burns what burns first, then keeps up to config.keepFuel fuel
  items.
  Junk (config.junk) is never stored: mining drops it after every cell
  (bot/mine.lua), a trip that dug through something on arrival
  (bot/skills.lua), and unloading before anything goes into the chest.
  Once per cell, not per dig: a drop takes 8 ticks, as long as a move.
]]
local nav = require("bot.nav")
local config = require("bot.config")

local M = {}

local SIDES = { "front", "top", "bottom", "left", "right", "back" }
local TURNS = { left = 3, right = 1, back = 2 }
local DROP = { top = turtle.dropUp, bottom = turtle.dropDown, front = turtle.drop }
local DETECT = { top = turtle.detectUp, bottom = turtle.detectDown, front = turtle.detect }

function M.freeSlots()
  local n = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then n = n + 1 end
  end
  return n
end

-- <Claude> Side of an adjacent inventory block, or nil.
function M.findChest()
  for _, side in ipairs(SIDES) do
    if peripheral.hasType(side, "inventory") then return side end
  end
end

-- <Claude> "14/16 slots free: 32 cobblestone, 8 coal" (minecraft: prefix dropped to save tokens).
function M.summary()
  local counts, order = {}, {}
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      local name = item.name:gsub("^minecraft:", "")
      if not counts[name] then order[#order + 1] = name end
      counts[name] = (counts[name] or 0) + item.count
    end
  end
  local text = ("%d/16 slots free"):format(M.freeSlots())
  for i, name in ipairs(order) do order[i] = counts[name] .. " " .. name end
  if #order > 0 then text = text .. ": " .. table.concat(order, ", ") end
  if M.findChest() then text = text .. "; chest next to turtle" end
  return text
end

-- <Claude> Drops junk (config.junk, exact item names) on the ground to free
-- slots without a trip home; it despawns after 5 minutes. Uses a side with
-- no inventory, so nothing lands in a chest by mistake: one of `open` (sides
-- the caller just dug), else an empty one, else a solid one. Returns items dropped.
function M.discardJunk(open)
  local junk = {}
  for _, name in ipairs(config.junk) do junk[name] = true end
  local drop -- picked at the first junk slot: a detect costs a tick, reading slots does not
  local function pick()
    for _, side in ipairs(open or {}) do
      if not peripheral.hasType(side, "inventory") then return DROP[side] end
    end
    local blocked
    for _, side in ipairs({ "top", "bottom", "front" }) do
      if not peripheral.hasType(side, "inventory") then
        if not DETECT[side]() then return DROP[side] end
        blocked = blocked or DROP[side] -- the item gets pushed out of the block, somewhere near
      end
    end
    return blocked or false
  end
  local dropped = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and junk[item.name] then
      if drop == nil then drop = pick() end
      if not drop then break end
      turtle.select(slot)
      if drop() then dropped = dropped + item.count end
    end
  end
  if drop then turtle.select(1) end
  return dropped
end

-- <Claude> Returns true, itemsMoved, junkDropped | false, err. Junk is
-- dropped first (never into the chest) and everything that burns goes into
-- the tank (nav.refuelAll) before anything is stored. Keeps up to
-- config.keepFuel fuel items, none if fuel is unlimited. Turns toward a
-- chest on the left/right/back and turns back afterwards.
function M.unload()
  local side = M.findChest()
  if not side then return false, "no chest next to the turtle" end
  local junked = M.discardJunk()
  nav.refuelAll()
  local before = nav.heading()
  if TURNS[side] then
    if not before then return false, "heading unknown, cannot turn to the chest" end
    nav.face((before + TURNS[side]) % 4)
  end
  local drop = side == "top" and turtle.dropUp or side == "bottom" and turtle.dropDown or turtle.drop
  local keep = nav.fuel() == math.huge and 0 or config.keepFuel
  local moved, err = 0, nil
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    local count = item and item.count or 0
    if item and nav.isFuel(item.name) then
      local kept = math.min(keep, count)
      keep, count = keep - kept, count - kept
    end
    if count > 0 then
      turtle.select(slot)
      if not drop(count) then err = "chest is full" break end
      moved = moved + item.count - turtle.getItemCount(slot)
    end
  end
  turtle.select(1)
  if TURNS[side] then nav.face(before) end
  if err then return false, err end
  return true, moved, junked
end

return M
