--[[ <Claude>
  Fleet brain. Run on a computer with a modem:  fleet <goal...>
  Turtles must be running `worker`. One LLM call turns the goal into plans
  for groups of turtles, which run in parallel; the LLM is called again only
  if some turtle failed, once all have finished. Ctrl+T stops every turtle
  that is still working. After this computer reboots, `fleet resume` waits
  for the job again (put it in startup.lua).
]]
local agent = require("llm.agent")
local plan = require("bot.plan")
local skills = require("bot.skills")
local net = require("bot.net")
local fleet = require("bot.fleet")

local SYSTEM = [[You plan jobs for a fleet of ComputerCraft turtles in Minecraft.
Put the whole goal in ONE runPlans call: a list of plans, each giving a group
of turtles (by id) the steps they run. Turtles work on their own and in
parallel; you only hear back, once all are done, if something failed: then
you get each turtle's outcome and fresh state, and either send plans for the
remaining work or reply with one line saying why it cannot be done.
A turtle can be in one plan only. In a plan with several turtles, mineBox is
split between them (each digs a slice) and every other step is done by each
of them. Use world coordinates (mineBox, goTo) for shared work; mineArea and
move are relative to each turtle. Lua already handles paths, digging through
obstacles, fuel and unloading. Read positions, fuel and inventories from the
Turtles list. If the goal is only a question, or no skill can do it, reply in
one line without runPlans. Replies show on a plain-text terminal: no markdown.
Skills (dir = north|south|east|west, or forward|back|left|right relative to
where the turtle faces when that step starts):
]] .. plan.catalog(skills.list)

local function onEvent(id, msg)
  if msg.type == "progress" then
    print(("#%d [%d] %s"):format(id, msg.step, msg.text))
  elseif msg.type == "silent" then
    printError(("#%d silent for %d s (unloaded chunk or out of range?), still waiting"):format(id, msg.seconds))
  elseif msg.ok then
    print(("#%d finished"):format(id))
  else
    printError(("#%d %s"):format(id, tostring(msg.error)))
  end
end

local goal = table.concat({ ... }, " ")
if not net.open() then error("fleet needs a modem (wireless or ender)", 0) end

-- <Claude> `fleet dash`: stay up as the dashboard (monitor + prompt, bot/dash.lua).
-- Goals typed there run exactly like `fleet <goal>`; a job saved before a
-- reboot is waited for again by itself.
if goal == "dash" then
  require("bot.dash").run({ system = SYSTEM, skills = skills.list })
  return
end

local saved = fleet.loadRun()

-- <Claude> `fleet resume` (e.g. from startup.lua): wait again for the job
-- that was running when this computer rebooted. The LLM is only called if
-- some turtle failed, to plan what is left.
if goal == "resume" then
  if not saved then print("Nothing to resume.") return end
  print(("Resuming job %s: %s"):format(saved.job, tostring(saved.goal)))
  local turtles = fleet.discover(2)
  for id in pairs(saved.pending) do turtles[id] = turtles[id] or { label = "?", state = "no answer yet" } end
  local text, failed = fleet.outcome(fleet.wait(saved, turtles, onEvent))
  print(text)
  if failed == 0 then fleet.clearRun() return end
  goal = tostring(saved.goal) .. "\nThis job was interrupted, then resumed. Outcome per turtle:\n" .. text
    .. "\nPlan only the work that is left, or reply in one line."
elseif saved then
  printError(("Unfinished job %s dropped (`fleet resume` would have waited for it)."):format(saved.job))
  fleet.clearRun()
end
if goal == "" then write("Goal: ") goal = read() end

print("Looking for turtles...")
local turtles = fleet.discover(2)
if next(turtles) == nil then error("no turtle answered: run `worker` on them", 0) end
local roster = fleet.describe(turtles)
print(roster)

local runPlans = fleet.tool(skills.list, turtles, onEvent, goal)
local text, stats = agent.run(goal .. "\nTurtles:\n" .. roster, { runPlans = runPlans }, SYSTEM, function(name, result)
  if not result.ok then printError(("> %s: %s"):format(name, tostring(result.error))) end
end)

if text then
  fleet.clearRun()
  print(text)
  print(("[%d LLM calls, %d in / %d out tokens]"):format(stats.turns, stats.tokensIn, stats.tokensOut))
else
  printError(stats) -- the job (if any) stays saved: `fleet resume` can pick it up
end
