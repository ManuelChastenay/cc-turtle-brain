--[[ <Claude>
  Single-turtle demo. Run on a turtle:  brain <goal...>
  These tools are placeholders until the rednet turtle agent exists; only
  the tools table changes when moving to a fleet, not the agent loop.
]]
local agent = require("llm.agent")

local moves = {
  forward = turtle.forward, back = turtle.back, up = turtle.up,
  down = turtle.down, left = turtle.turnLeft, right = turtle.turnRight,
}
local inspects = { front = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }

local tools = {
  getStatus = {
    description = "Fuel level and GPS position (null if no GPS).",
    handler = function()
      local x, y, z = gps.locate(2)
      return { ok = true, fuel = turtle.getFuelLevel(), pos = x and { x, y, z } or textutils.json_null }
    end,
  },
  move = {
    description = "Move or turn the turtle up to 16 times. Stops at the first failure.",
    parameters = { type = "object", required = { "direction" }, properties = {
      direction = { type = "string", enum = { "forward", "back", "up", "down", "left", "right" } },
      steps     = { type = "integer", minimum = 1, maximum = 16 },
    } },
    handler = function(a)
      local fn = moves[a.direction]
      if not fn then return { ok = false, error = "bad direction" } end
      for done = 0, (a.steps or 1) - 1 do
        local ok, reason = fn()
        if not ok then return { ok = false, done = done, error = reason } end
      end
      return { ok = true, done = a.steps or 1 }
    end,
  },
  inspect = {
    description = "Block name in front, above or below the turtle.",
    parameters = { type = "object", required = { "side" }, properties = {
      side = { type = "string", enum = { "front", "up", "down" } },
    } },
    handler = function(a)
      local fn = inspects[a.side]
      if not fn then return { ok = false, error = "bad side" } end
      local hasBlock, data = fn()
      return { ok = true, block = hasBlock and data.name or "air" }
    end,
  },
}

local SYSTEM = [[You control a ComputerCraft turtle in Minecraft through tools.
Never invent tool results. Check fuel before long trips. When the goal is done
or impossible, reply with a one-line summary and no tool call.]]

local goal = table.concat({ ... }, " ")
if goal == "" then write("Goal: ") goal = read() end

local text, stats = agent.run(goal, tools, SYSTEM, function(name, result)
  print(("> %s %s"):format(name, textutils.serialiseJSON(result)))
end)

if text then
  print(text)
  print(("[%d turns, %d in / %d out tokens]"):format(stats.turns, stats.tokensIn, stats.tokensOut))
else
  printError(stats)
end
