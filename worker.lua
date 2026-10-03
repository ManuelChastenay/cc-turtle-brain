--[[ <Claude>
  Fleet worker. Run on each turtle:  worker   (or from startup.lua)
  Waits for plans from the fleet brain (fleet.lua) over rednet and runs them
  with the same skills as brain.lua. Two loops share the turtle: one runs
  plans, the other keeps answering the brain (status pings, "busy", stop).
  Protocol: bot/net.lua.
]]
local nav = require("bot.nav")
local plan = require("bot.plan")
local skills = require("bot.skills")
local net = require("bot.net")

if not net.open() then error("worker needs a modem (wireless or ender)", 0) end
nav.init()
print(("Worker #%d %s ready"):format(os.getComputerID(), os.getComputerLabel() or ""))
print(skills.state())

local job -- { id, boss, steps } while a plan runs

local function status()
  return { type = "status", label = os.getComputerLabel(), state = skills.state(), pos = nav.pos(), job = job and job.id }
end

-- <Claude> Runs the current job until it ends or a stop arrives; returns the result message.
local function runJob()
  local report
  parallel.waitForAny(function()
    report = plan.report(job.steps, plan.run(job.steps, function(i, step)
      print(("[%d] %s"):format(i, plan.format(step)))
      net.send(job.boss, { type = "progress", job = job.id, step = i, text = plan.format(step) })
    end))
  end, function()
    os.pullEvent("ccbrain_stop")
  end)
  if not report then
    nav.init() -- the plan was cut off, maybe mid-move: resync position and heading
    report = { ok = false, error = "stopped by the brain" }
  end
  report.type, report.job, report.state, report.pos = "result", job.id, skills.state(), nav.pos()
  return report
end

local function runner()
  while true do
    os.pullEvent("ccbrain_job")
    local result = runJob()
    print(result.ok and result.summary or result.error)
    net.send(job.boss, result)
    job = nil
  end
end

local function handle(from, msg)
  if msg.type == "hello" then
    net.send(from, status())
  elseif msg.type == "plan" and job then
    net.send(from, { type = "result", job = msg.job, ok = false, error = "busy with job " .. tostring(job.id) })
  elseif msg.type == "plan" then
    local steps, err = plan.check(msg.steps, skills.list)
    if steps then
      job = { id = msg.job, boss = from, steps = steps }
      net.send(from, { type = "accepted", job = msg.job })
      os.queueEvent("ccbrain_job")
    else
      net.send(from, { type = "result", job = msg.job, ok = false, error = "plan rejected, nothing ran: " .. err })
    end
  elseif msg.type == "stop" and job then
    os.queueEvent("ccbrain_stop")
  end
end

local function listener()
  while true do
    local from, msg = rednet.receive(net.PROTOCOL)
    if type(msg) == "table" then handle(from, msg) end
  end
end

parallel.waitForAny(runner, listener)
