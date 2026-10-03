--[[ <Claude>
  Inventory helpers: free slots, a compact summary for the LLM, and
  unloading into an adjacent chest (anything exposing an "inventory"
  peripheral: chests, barrels, modded storage). Fuel items are kept.
]]
local nav = require("bot.nav")

local M = {}

local SIDES = { "front", "top", "bottom", "left", "right", "back" }
local TURNS = { left = 3, right = 1, back = 2 }

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

-- <Claude> Returns true, itemsMoved | false, err. Turns toward a chest on the
-- left/right/back and turns back afterwards.
function M.unload()
  local side = M.findChest()
  if not side then return false, "no chest next to the turtle" end
  local before = nav.heading()
  if TURNS[side] then
    if not before then return false, "heading unknown, cannot turn to the chest" end
    nav.face((before + TURNS[side]) % 4)
  end
  local drop = side == "top" and turtle.dropUp or side == "bottom" and turtle.dropDown or turtle.drop
  local moved, err = 0, nil
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not nav.isFuel(item.name) then
      turtle.select(slot)
      if not drop() then err = "chest is full" break end
      moved = moved + item.count - turtle.getItemCount(slot)
    end
  end
  turtle.select(1)
  if TURNS[side] then nav.face(before) end
  if err then return false, err end
  return true, moved
end

return M
