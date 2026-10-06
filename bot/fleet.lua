--[[ <Claude>
  Brain side of the fleet (runs on a computer): find turtles, then the
  runPlans tool, which checks plans, splits shared steps, sends each turtle
  its steps and waits until every turtle is done. The LLM is called again
  only after that, so the blocking http.post never runs while a rednet
  message is expected. The job in flight is saved (/fleet_job.json), so
  `fleet resume` can wait for it again after the computer reboots. Ctrl+T
  while waiting stops every busy turtle. Also the no-LLM commands
  (runSteps: do, /home, /refuel; retry: carry on stopped or failed jobs;
  update: reinstall the workers' code).
  Protocol: bot/net.lua.
]]
local plan = require("bot.plan")
local net = require("bot.net")

local M = {}

local PING_EVERY, WARN_AFTER, LOST_AFTER = 15, 60, 600
M.UPDATE_ACK, M.UPDATE_WAIT = 5, 180 -- seconds to answer `update`, and to finish installing
local RUN_PATH = "/fleet_job.json"

local function sortedIds(t)
  local ids = {}
  for id in pairs(t) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- <Claude> Broadcasts hello and collects answers for `wait` seconds.
-- Returns { [id] = { label, state, pos, job } }.
function M.discover(wait)
  rednet.broadcast({ type = "hello" }, net.PROTOCOL)
  local found, deadline = {}, os.clock() + wait
  while true do
    local left = deadline - os.clock()
    if left <= 0 then return found end
    local from, msg = rednet.receive(net.PROTOCOL, left)
    if not from then return found end
    if type(msg) == "table" and msg.type == "status" then found[from] = msg end
  end
end

-- <Claude> One line per turtle for the prompt: "#7 miner-1: pos ..., fuel ...".
function M.describe(turtles)
  local lines = {}
  for _, id in ipairs(sortedIds(turtles)) do
    local t = turtles[id]
    lines[#lines + 1] = ("#%d %s: %s%s"):format(id, t.label or "unlabeled", t.state,
      t.job and (" (busy with job " .. tostring(t.job) .. ")") or "")
  end
  return table.concat(lines, "\n")
end

-- <Claude> plans = { { turtles = { ids }, steps = { ... } } } -> { [id] = plain steps } | nil, err.
-- A step whose skill has `split` is divided among the group (a turtle with no
-- part skips it); every other step goes to each turtle of the group.
local function expand(plans, skills, turtles)
  if type(plans) ~= "table" or #plans == 0 then return nil, "plans must be a non-empty list" end
  local work = {}
  for p, group in ipairs(plans) do
    if type(group) ~= "table" or type(group.turtles) ~= "table" or #group.turtles == 0 then
      return nil, ("plan %d: turtles must be a non-empty list of ids"):format(p)
    end
    local steps, err = plan.check(group.steps, skills)
    if not steps then return nil, ("plan %d: %s"):format(p, err) end
    local ids, positions = {}, {}
    for i, raw in ipairs(group.turtles) do
      local id = tonumber(raw)
      if not turtles[id] then return nil, ("plan %d: no turtle #%s"):format(p, tostring(raw)) end
      if work[id] then return nil, ("turtle #%d is in more than one plan"):format(id) end
      work[id], ids[i], positions[i] = {}, id, turtles[id].pos
    end
    for _, step in ipairs(steps) do
      local parts = step.skill.split and #ids > 1 and step.skill.split(step.args, positions)
      for i, id in ipairs(ids) do
        local args = parts and parts[i] or not parts and step.args
        if args then table.insert(work[id], plan.flatten(step.skill.name, args)) end
      end
    end
  end
  return work
end

-- <Claude> The job in flight, saved so `fleet resume` can pick it up after
-- the brain computer reboots: { goal, job, manual, pending = { ids }, results =
-- { ["id"] = result } } (JSON object keys must be strings). manual = sent
-- without the LLM (do, retry, home...): a resume only reports its failures.
-- In memory, pending is a set and results are keyed by number.
local function saveRun(run)
  local pending, results = {}, {}
  for id in pairs(run.pending) do pending[#pending + 1] = id end
  for id, result in pairs(run.results) do results[tostring(id)] = result end
  local f = fs.open(RUN_PATH, "w")
  f.write(textutils.serialiseJSON({ goal = run.goal, job = run.job, manual = run.manual, pending = pending, results = results }))
  f.close()
end

function M.loadRun()
  local f = fs.open(RUN_PATH, "r")
  if not f then return nil end
  local data = textutils.unserialiseJSON(f.readAll())
  f.close()
  if type(data) ~= "table" or not data.job then return nil end
  local run = { goal = data.goal, job = data.job, manual = data.manual, pending = {}, results = {} }
  for _, id in ipairs(data.pending or {}) do run.pending[id] = true end
  for id, result in pairs(data.results or {}) do run.results[tonumber(id)] = result end
  return run
end

function M.clearRun()
  fs.delete(RUN_PATH)
end

-- <Claude> Waits until every pending turtle has a result, saving progress
-- and acknowledging each result as it comes. A rebooted worker resumes its
-- job, so silence is only reported (a "silent" event) after WARN_AFTER s
-- and counts as a failure after LOST_AFTER s. onEvent(id, msg) sees
-- progress, silent and result messages. Returns run.results.
function M.wait(run, turtles, onEvent)
  onEvent = onEvent or function() end
  local seen, warned, lastPing = {}, {}, os.clock()
  for id in pairs(run.pending) do seen[id] = os.clock() end
  local function finish(id, result)
    run.results[id], run.pending[id] = result, nil
    saveRun(run)
    net.send(id, { type = "ack", job = run.job })
    local t = turtles[id]
    if t then t.state, t.pos, t.job = result.state or t.state, result.pos or t.pos, nil end
    onEvent(id, result)
  end

  local ok, err = pcall(function()
    while next(run.pending) do
      local from, msg = rednet.receive(net.PROTOCOL, PING_EVERY)
      local now = os.clock()
      if from and run.pending[from] and type(msg) == "table" then
        seen[from], warned[from] = now, nil
        if msg.type == "result" and msg.job == run.job then
          finish(from, msg)
        elseif msg.type == "progress" and msg.job == run.job then
          onEvent(from, msg)
        elseif msg.type == "status" and not msg.quick and msg.job ~= run.job then
          -- <Claude> Done while we were not listening (its result is kept), or lost the job.
          local kept = type(msg.result) == "table" and msg.result.job == run.job and msg.result
          finish(from, kept or { ok = false, error = "turtle restarted without its job" })
        end
      end
      if now - lastPing >= PING_EVERY then
        lastPing = now
        for id in pairs(run.pending) do
          local silent = now - seen[id]
          if silent > LOST_AFTER then
            finish(id, { ok = false, error = ("no answer for %d s: out of range, chunk unloaded or broken"):format(LOST_AFTER) })
          else
            if silent > WARN_AFTER and not warned[id] then
              warned[id] = true
              onEvent(id, { type = "silent", seconds = math.floor(silent) })
            end
            net.send(id, { type = "hello" })
          end
        end
      end
    end
  end)
  if not ok then
    if err == "Terminated" then
      for id in pairs(run.pending) do net.send(id, { type = "stop" }) end
      M.clearRun()
    end
    error(err, 0)
  end
  return run.results
end

-- <Claude> One line per turtle ("#7 Done: ..." / "#8 step 1 (...) failed: ...").
-- Returns text, failures, turtles.
function M.outcome(results)
  local lines, failed = {}, 0
  for _, id in ipairs(sortedIds(results)) do
    local r = results[id]
    if r.ok then
      lines[#lines + 1] = ("#%d %s"):format(id, tostring(r.summary))
    else
      failed = failed + 1
      lines[#lines + 1] = ("#%d %s%s%s"):format(id, tostring(r.error),
        r.completed and ("; completed: " .. r.completed) or "", r.failed and ("; " .. r.failed) or "")
    end
  end
  return table.concat(lines, "\n"), failed, #lines
end

-- <Claude> Sends each turtle in msgs ({ [id] = { steps } or { retry = true } })
-- its part of one new job, waits for all of them and returns the runPlans
-- result. The job is saved before anything is sent: a reboot right after
-- must still know about it.
local function launch(msgs, turtles, onEvent, goal, manual)
  local run = { goal = goal, job = os.getComputerID() .. "-" .. os.epoch("utc"), manual = manual, pending = {}, results = {} }
  for id in pairs(msgs) do run.pending[id] = true end
  saveRun(run)
  for id, msg in pairs(msgs) do
    msg.type, msg.job = "plan", run.job
    net.send(id, msg)
  end
  local text, failed, count = M.outcome(M.wait(run, turtles, onEvent))
  if failed == 0 then
    return { ok = true, summary = count > 0 and text or "No turtle had anything to do." }
  end
  return { ok = false, error = ("%d of %d turtles failed"):format(failed, count), results = text, state = M.describe(turtles) }
end

local function stepsOnly(work)
  local msgs = {}
  for id, steps in pairs(work) do
    if #steps > 0 then msgs[id] = { steps = steps } end
  end
  return msgs
end

-- <Claude> The runPlans tool for llm/agent.lua. `final` like runPlan: if
-- every turtle succeeds, the run ends with a Lua-written summary. Otherwise
-- the model gets each turtle's outcome and the fleet's fresh state.
-- goal is saved with the job for `fleet resume`. log(text), optional, hears
-- each plan the model sends ("plan for #7,8: mineBox ...; goHome").
function M.tool(skills, turtles, onEvent, goal, log)
  return {
    description = "Send plans to groups of turtles. They run in parallel; nothing is reported back unless a turtle fails.",
    parameters = { type = "object", required = { "plans" }, properties = {
      plans = { type = "array", items = { type = "object", required = { "turtles", "steps" }, properties = {
        turtles = { type = "array", items = { type = "integer" } },
        steps = { type = "array", items = plan.stepSchema(skills) },
      } } },
    } },
    final = true,
    handler = function(a)
      local work, err = expand(a.plans, skills, turtles)
      if not work then return { ok = false, error = "plans rejected, nothing ran: " .. err } end
      for _, group in ipairs(log and a.plans or {}) do
        local text = {}
        for i, step in ipairs(plan.check(group.steps, skills)) do text[i] = plan.format(step) end
        log(("plan for #%s: %s"):format(table.concat(group.turtles, ","), table.concat(text, "; ")))
      end
      return launch(stepsOnly(work), turtles, onEvent, goal, false)
    end,
  }
end

-- <Claude> Sorted ids of the idle turtles (no job), only those in the set
-- `only` if given. Returns ids, number of busy turtles left out.
function M.idle(turtles, only)
  local ids, busy = {}, 0
  for _, id in ipairs(sortedIds(turtles)) do
    if not only or only[id] then
      if turtles[id].job then busy = busy + 1 else ids[#ids + 1] = id end
    end
  end
  return ids, busy
end

-- <Claude> The same steps for the turtles in ids as one group, with no LLM
-- call (`fleet do`, `fleet refuel`, the dashboard's /do, /home, /refuel):
-- shared steps (mineBox, mineSphere, builds...) are split between them like
-- in an LLM plan. Waits like runPlans, then forgets the job. Returns the
-- runPlans result ({ ok, summary } | { ok = false, error, results }).
function M.runSteps(skills, turtles, ids, steps, onEvent, goal)
  local work, err = expand({ { turtles = ids, steps = steps } }, skills, turtles)
  if not work then return { ok = false, error = "plans rejected, nothing ran: " .. err } end
  local result = launch(stepsOnly(work), turtles, onEvent, goal, true)
  M.clearRun()
  return result
end

-- <Claude> Idle turtles (only those in the set `only`, if given) that kept a
-- stopped or failed job (status `retry`, see bot/job.lua) carry on with it
-- from its last checkpoint, as one new job, with no LLM call. Returns the
-- runPlans result.
function M.retry(turtles, only, onEvent)
  local msgs, any = {}, false
  for _, id in ipairs((M.idle(turtles, only))) do
    if turtles[id].retry then msgs[id], any = { retry = true }, true end
  end
  if not any then return { ok = false, error = "no idle turtle has a stopped or failed job to retry" } end
  local result = launch(msgs, turtles, onEvent, "retry", true)
  M.clearRun()
  return result
end

-- <Claude> Has the turtles in ids install `target` ({ n, sha } from
-- bot/version.lua: the commit this computer runs, so the whole fleet runs
-- one commit and GitHub's API is asked once; nil = each the newest). The
-- worker runs /install.lua and reboots into it (a busy one refuses). One
-- that does not answer within UPDATE_ACK s runs a worker from before
-- `update` existed: run `install` on it by hand once. onEvent(id, msg) sees
-- `updating` and `updated`. Returns { [id] = { ok, summary | error } } for M.outcome.
function M.update(ids, target, onEvent)
  onEvent = onEvent or function() end
  local start, waiting, results = os.clock(), {}, {}
  for _, id in ipairs(ids) do
    waiting[id] = "asked"
    net.send(id, { type = "update", sha = target and target.sha, n = target and target.n })
  end
  while next(waiting) do
    local from, msg = rednet.receive(net.PROTOCOL, 1)
    if from and waiting[from] and type(msg) == "table" then
      if msg.type == "updating" then
        waiting[from] = "installing"
        onEvent(from, msg)
      elseif msg.type == "updated" then
        waiting[from], results[from] = nil, msg
        onEvent(from, msg)
      end
    end
    local elapsed = os.clock() - start
    for id, stage in pairs(waiting) do
      if stage == "asked" and elapsed >= M.UPDATE_ACK then
        waiting[id], results[id] = nil, { ok = false, error = "no answer: an older worker? run `install` on it by hand once" }
      elseif elapsed >= M.UPDATE_WAIT then
        waiting[id], results[id] = nil, { ok = false, error = ("install still running after %d s"):format(M.UPDATE_WAIT) }
      end
    end
  end
  return results
end

return M
