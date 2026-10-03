--[[ <Claude>
  Single-turtle brain. Run on a turtle:  brain <goal...>
  One LLM call turns the goal into a plan of skills (bot/skills.lua) that
  Lua runs on its own; the LLM is called again only if a step fails.
  A fleet brain keeps this flow and sends each turtle its plan over rednet.
]]
local agent = require("llm.agent")
local nav = require("bot.nav")
local plan = require("bot.plan")
local skills = require("bot.skills")

local SYSTEM = [[You plan jobs for a ComputerCraft turtle in Minecraft.
Put the whole goal in ONE runPlan call. The turtle runs the steps by itself
and you only hear back if a step fails: then you get the error and fresh
state, and either send a plan for the remaining work or reply with one line
saying why it cannot be done. Lua already handles paths, digging through
obstacles, fuel and unloading when the inventory is full: never plan those.
Read position, fuel and inventory from State instead of planning checks.
If the goal is only a question, or no skill can do it, reply in one line
without runPlan.
Replies show on a plain-text terminal: no markdown.
Skills (dir = north|south|east|west, or forward|back|left|right relative to
where the turtle faces when that step starts):
]] .. plan.catalog(skills.list)

local goal = table.concat({ ... }, " ")
if goal == "" then write("Goal: ") goal = read() end

nav.init()
local state = skills.state()
print("State: " .. state)

local runPlan = plan.tool(skills.list, skills.state, function(i, step)
  print(("[%d] %s"):format(i, plan.format(step)))
end)

local text, stats = agent.run(goal .. "\nState: " .. state, { runPlan = runPlan }, SYSTEM, function(name, result)
  if not result.ok then printError(("> %s: %s"):format(name, tostring(result.error))) end
end)

if text then
  print(text)
  print(("[%d LLM calls, %d in / %d out tokens]"):format(stats.turns, stats.tokensIn, stats.tokensOut))
else
  printError(stats)
end
