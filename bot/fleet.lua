--[[ <Claude>
  Brain side of the fleet (runs on a computer): find turtles, then the
  runPlans tool, which checks plans, splits shared steps, sends each turtle
  its steps and waits until every turtle is done. The LLM is called again
  only after that, so the blocking http.post never runs while a rednet
  message is expected. A turtle silent for LOST_AFTER seconds (unloaded
  chunk, out of range, broken) counts as failed. Ctrl+T while waiting stops
  every busy turtle. Protocol: bot/net.lua.
]]
local plan = require("bot.plan")
local net = require("bot.net")

local M = {}

local PING_EVERY, LOST_AFTER = 15, 60

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

-- <Claude> Sends each turtle its steps and waits for every result.
-- onEvent(id, msg) sees progress and result messages as they arrive.
local function dispatch(work, turtles, onEvent)
  local job = os.getComputerID() .. "-" .. os.epoch("utc")
  local pending, seen, results = {}, {}, {}
  local function finish(id, result)
    results[id], pending[id] = result, nil
    local t = turtles[id]
    t.state, t.pos, t.job = result.state or t.state, result.pos or t.pos, nil
    onEvent(id, result)
  end
  for id, steps in pairs(work) do
    if #steps > 0 then
      net.send(id, { type = "plan", job = job, steps = steps })
      pending[id], seen[id] = true, os.clock()
    end
  end

  local lastPing = os.clock()
  local ok, err = pcall(function()
    while next(pending) do
      local from, msg = rednet.receive(net.PROTOCOL, PING_EVERY)
      local now = os.clock()
      if from and pending[from] and type(msg) == "table" then
        seen[from] = now
        if msg.type == "result" and msg.job == job then
          finish(from, msg)
        elseif msg.type == "progress" and msg.job == job then
          onEvent(from, msg)
        elseif msg.type == "status" and msg.job ~= job then
          finish(from, { ok = false, error = "turtle restarted or dropped the plan" })
        end
      end
      if now - lastPing >= PING_EVERY then
        lastPing = now
        for id in pairs(pending) do
          if now - seen[id] > LOST_AFTER then
            finish(id, { ok = false, error = ("no answer for %d s: out of range, chunk unloaded or broken"):format(LOST_AFTER) })
          else
            net.send(id, { type = "hello" })
          end
        end
      end
    end
  end)
  if not ok then
    if err == "Terminated" then
      for id in pairs(pending) do net.send(id, { type = "stop" }) end
    end
    error(err, 0)
  end
  return results
end

-- <Claude> The runPlans tool for llm/agent.lua. `final` like runPlan: if
-- every turtle succeeds, the run ends with a Lua-written summary. Otherwise
-- the model gets each turtle's outcome and the fleet's fresh state.
function M.tool(skills, turtles, onEvent)
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
      local results = dispatch(work, turtles, onEvent or function() end)
      local lines, failed = {}, 0
      for _, id in ipairs(sortedIds(results)) do
        local r = results[id]
        if r.ok then
          lines[#lines + 1] = ("#%d %s"):format(id, r.summary)
        else
          failed = failed + 1
          lines[#lines + 1] = ("#%d %s%s%s"):format(id, tostring(r.error),
            r.completed and ("; completed: " .. r.completed) or "", r.failed and ("; " .. r.failed) or "")
        end
      end
      if failed == 0 then
        return { ok = true, summary = #lines > 0 and table.concat(lines, "\n") or "No turtle had anything to do." }
      end
      return {
        ok = false,
        error = ("%d of %d turtles failed"):format(failed, #lines),
        results = table.concat(lines, "\n"),
        state = M.describe(turtles),
      }
    end,
  }
end

return M
