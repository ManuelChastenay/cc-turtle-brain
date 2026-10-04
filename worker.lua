--[[ <Claude>
  Fleet worker. Run on each turtle from startup.lua (shell.run("worker")),
  so it comes back after a server restart or chunk reload.
  Waits for plans from the fleet brain (fleet.lua) over rednet and runs them
  with the same skills as brain.lua. Two loops share the turtle: one runs
  plans, the other keeps answering the brain (status pings, "busy", stop)
  and other turtles (makeway). Jobs are saved to disk (bot/job.lua): after
  a reboot the worker carries on where it stopped, and keeps the result
  until the brain acknowledges it. When idle, `update` from the brain
  installs a commit from GitHub and reboots into it. Every status carries
  the version it runs (bot/version.lua). Protocol: bot/net.lua.
]]
local nav = require("bot.nav")
local plan = require("bot.plan")
local skills = require("bot.skills")
local net = require("bot.net")
local jobs = require("bot.job")
local version = require("bot.version")

if not net.open() then error("worker needs a modem (wireless or ender)", 0) end
local saved = jobs.load()
nav.init(saved ~= nil) -- resuming: no calibration moves in the middle of a job unless needed
local running = version.read() -- the code running now, until the next reboot
local VERSION = version.text(running)
print(("Worker #%d %s ready, %s"):format(os.getComputerID(), os.getComputerLabel() or "", VERSION))
print(skills.state())

local current -- { id, boss, steps, record } while a job runs

-- <Claude> A job saved before a reboot: run it again from its last checkpoint.
if saved then
  local steps, err = plan.check(saved.steps, skills.list)
  if steps then
    current = { id = saved.id, boss = saved.boss, steps = steps, record = saved }
    print(("Resuming job %s at step %d"):format(tostring(saved.id), saved.step))
    os.queueEvent("ccbrain_job")
  else
    jobs.finish({ type = "result", job = saved.id, ok = false, error = "could not resume: " .. err })
  end
end

-- <Claude> Blocked by another turtle: ask it to move. It only does if idle;
-- a busy one sorts it out in nav.step (lower id has right of way).
nav.onTurtleInWay = function(id)
  if id then net.send(id, { type = "makeway", from = nav.pos() }) end
end

-- <Claude> `result` is the last job's result until the brain acknowledges it.
-- A quick status (the dashboard's poll every few seconds) leaves out
-- `state` and `result` to stay small.
local function status(quick)
  local fuel = nav.fuel()
  local msg = { type = "status", label = os.getComputerLabel(), pos = nav.pos(), job = current and current.id,
                fuel = fuel == math.huge and "unlimited" or fuel, version = VERSION }
  if current then msg.step, msg.steps, msg.text = current.step, #current.steps, current.text end
  if quick then
    msg.quick = true
  else
    msg.state, msg.result = skills.state(), not current and jobs.result() or nil
  end
  return msg
end

-- <Claude> Runs the current job until it ends or a stop arrives; returns the result message.
local function runJob()
  local report
  parallel.waitForAny(function()
    report = plan.report(current.steps, plan.run(current.steps, function(i, step)
      current.step, current.text = i, plan.format(step)
      print(("[%d] %s"):format(i, current.text))
      net.send(current.boss, { type = "progress", job = current.id, step = i, steps = #current.steps, text = current.text })
    end, jobs.journal(current.record)))
  end, function()
    os.pullEvent("ccbrain_stop")
  end)
  if not report then
    nav.init() -- the plan was cut off, maybe mid-move: resync position and heading
    report = { ok = false, error = "stopped by the brain" }
  end
  report.type, report.job, report.state, report.pos = "result", current.id, skills.state(), nav.pos()
  return report
end

local function runner()
  while true do
    os.pullEvent("ccbrain_job")
    local result = runJob()
    print(result.ok and result.summary or result.error)
    jobs.finish(result)
    net.send(current.boss, result)
    current = nil
  end
end

-- <Claude> Runs /install.lua for msg.sha (the commit the brain runs; the
-- newest one if none), then reboots: startup.lua starts the new worker. No
-- reboot when this worker already runs that commit. The listener is busy
-- meanwhile; nothing else needs it, the turtle is idle.
local function update(from, msg)
  net.send(from, { type = "updating" })
  print("Updating from GitHub")
  local args = { "/install.lua" }
  if type(msg.sha) == "string" and msg.sha:match("^%x+$") then
    args[2], args[3] = msg.sha, tonumber(msg.n) and tostring(math.floor(msg.n)) or nil
  end
  if not shell.run(table.unpack(args)) then
    net.send(from, { type = "updated", ok = false, error = "install failed (see the turtle's screen)" })
    return
  end
  local after = version.read()
  if running and after and running.sha == after.sha then
    net.send(from, { type = "updated", ok = true, summary = "already at " .. version.text(after) })
    return
  end
  net.send(from, { type = "updated", ok = true, summary = ("updated to %s, rebooting"):format(version.text(after)) })
  os.reboot()
end

local function handle(from, msg)
  if msg.type == "hello" then
    net.send(from, status(msg.quick))
  elseif msg.type == "plan" and current then
    net.send(from, { type = "result", job = msg.job, ok = false, error = "busy with job " .. tostring(current.id) })
  elseif msg.type == "plan" then
    local steps, err = plan.check(msg.steps, skills.list)
    if steps then
      current = { id = msg.job, boss = from, steps = steps, record = jobs.start(msg.job, from, msg.steps) }
      net.send(from, { type = "accepted", job = msg.job })
      os.queueEvent("ccbrain_job")
    else
      net.send(from, { type = "result", job = msg.job, ok = false, error = "plan rejected, nothing ran: " .. err })
    end
  elseif msg.type == "ack" then
    local result = jobs.result()
    if result and result.job == msg.job then jobs.clearResult() end
  elseif msg.type == "stop" and current then
    os.queueEvent("ccbrain_stop")
  elseif msg.type == "makeway" and not current then
    nav.makeWay(msg.from)
  elseif msg.type == "update" and current then -- the job would resume under different code
    net.send(from, { type = "updated", ok = false, error = ("busy with job %s, not updated"):format(tostring(current.id)) })
  elseif msg.type == "update" then
    update(from, msg)
  end
end

local function listener()
  while true do
    local from, msg = rednet.receive(net.PROTOCOL)
    if type(msg) == "table" then handle(from, msg) end
  end
end

parallel.waitForAny(runner, listener)
