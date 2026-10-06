--[[ <Claude>
  Plans: the LLM sends a whole job as one ordered list of skill steps, e.g.
    {"steps":[{"skill":"mineArea","direction":"north","length":6,...},{"skill":"goHome"}]}
  and Lua runs it with no LLM call between steps. Each skill's declaration
  (bot/skills.lua) generates the prompt catalog, the tool schema and the
  argument checks, so adding a skill is one table entry.
  Arg types: "int", "count" (integer >= 1), "str", or an enum "a|b|c" where
  "dir" stands for the 8 horizontal directions. An arg with optional = true
  may be left out (no default: the skill gets nil). Hidden args (hidden =
  true, with a default) are checked but not shown to the LLM: the fleet's
  split sets them.
]]
local config = require("bot.config")

local M = {}

local DIRS = { "north", "south", "east", "west", "forward", "back", "left", "right" }

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

-- <Claude> "dir|up|down" -> { "north", ..., "up", "down" }; nil for non-enum types.
local function enum(t)
  if t == "int" or t == "count" or t == "str" then return nil end
  local list = {}
  for word in t:gmatch("[^|]+") do
    if word == "dir" then
      for _, d in ipairs(DIRS) do list[#list + 1] = d end
    else
      list[#list + 1] = word
    end
  end
  return list
end

local function checkArg(spec, value)
  local name, t, default = spec[1], spec[2], spec[3]
  if value == nil then
    if default == nil and not spec.optional then return nil, "missing " .. name end
    return default
  end
  if t == "int" or t == "count" then
    local n = tonumber(value)
    if not n or n ~= math.floor(n) then return nil, name .. " must be an integer" end
    if t == "count" and n < 1 then return nil, name .. " must be at least 1" end
    return n
  end
  local values = enum(t)
  if values and not contains(values, value) then
    return nil, ("%s must be one of %s"):format(name, table.concat(values, "|"))
  end
  if type(value) ~= "string" then return nil, name .. " must be a string" end
  return value
end

-- <Claude> One line per skill for the system prompt: "- name(a, b=default): doc".
-- brief = no doc (the `do` command's help).
function M.catalog(skills, brief)
  local lines = {}
  for _, skill in ipairs(skills) do
    local params = {}
    for _, spec in ipairs(skill.args or {}) do
      if not spec.hidden then
        local default = spec[3] ~= nil and tostring(spec[3]) or spec.optional and "none"
        params[#params + 1] = default and ("%s=%s"):format(spec[1], default) or spec[1]
      end
    end
    lines[#lines + 1] = ("- %s(%s)%s"):format(skill.name, table.concat(params, ", "), brief and "" or ": " .. skill.doc)
  end
  return table.concat(lines, "\n")
end

-- <Claude> JSON schema of one step. Steps are flat objects; their properties
-- are the union of every skill's args (enums merged). Per-skill rules are
-- enforced by M.check.
function M.stepSchema(skills)
  local props = { skill = { type = "string", enum = {} } }
  for _, skill in ipairs(skills) do
    table.insert(props.skill.enum, skill.name)
    for _, spec in ipairs(skill.args or {}) do
      if not spec.hidden then
        local values = enum(spec[2])
        local prop = props[spec[1]]
        if not prop then
          prop = { type = (spec[2] == "int" or spec[2] == "count") and "integer" or "string" }
          props[spec[1]] = prop
        end
        for _, v in ipairs(values or {}) do
          prop.enum = prop.enum or {}
          if not contains(prop.enum, v) then table.insert(prop.enum, v) end
        end
      end
    end
  end
  return { type = "object", required = { "skill" }, properties = props }
end

-- <Claude> Validates the whole plan before anything moves.
-- Returns { { skill = <skill>, args = {...} }, ... } | nil, err.
function M.check(steps, skills)
  if type(steps) ~= "table" or #steps == 0 then return nil, "steps must be a non-empty list" end
  if #steps > config.maxSteps then return nil, ("too many steps (max %d)"):format(config.maxSteps) end
  local index = {}
  for _, skill in ipairs(skills) do index[skill.name] = skill end
  local out = {}
  for i, step in ipairs(steps) do
    if type(step) ~= "table" then return nil, ("step %d: not an object"):format(i) end
    local skill = index[step.skill]
    if not skill then return nil, ("step %d: unknown skill %s"):format(i, tostring(step.skill)) end
    local args, known = {}, { skill = true }
    for _, spec in ipairs(skill.args or {}) do
      known[spec[1]] = true
      local value, err = checkArg(spec, step[spec[1]])
      if err then return nil, ("step %d (%s): %s"):format(i, skill.name, err) end
      args[spec[1]] = value
    end
    for key in pairs(step) do
      if not known[key] then return nil, ("step %d (%s): unexpected %s"):format(i, skill.name, tostring(key)) end
    end
    out[i] = { skill = skill, args = args }
  end
  return out
end

-- <Claude> A checked step back to plain data ({ skill = name, ...args }) for rednet.
function M.flatten(name, args)
  local step = { skill = name }
  for key, value in pairs(args) do step[key] = value end
  return step
end

-- <Claude> "mineArea direction=north length=6 ..." (args in declaration order;
-- left-out optional args and hidden ones at their default are not shown).
function M.format(step)
  local parts = { step.skill.name }
  for _, spec in ipairs(step.skill.args or {}) do
    local value = step.args[spec[1]]
    if value ~= nil and not (spec.hidden and value == spec[3]) then
      parts[#parts + 1] = ("%s=%s"):format(spec[1], tostring(value))
    end
  end
  return table.concat(parts, " ")
end

-- <Claude> Steps typed by hand (the `do` command, no LLM), separated by ";":
--   "mineSphere 0 100 0 200 bottom=75; goHome; unload"
-- Bare values fill the skill's shown args in order, skipping those given as
-- name=value. Skill names ignore case. Returns raw steps (as the LLM would
-- send them, already checked) | nil, err.
function M.parse(text, skills)
  local index = {}
  for _, skill in ipairs(skills) do index[skill.name:lower()] = skill end
  local steps = {}
  for part in tostring(text):gmatch("[^;]+") do
    local words = {}
    for word in part:gmatch("%S+") do words[#words + 1] = word end
    if #words > 0 then
      local skill = index[words[1]:lower()]
      if not skill then return nil, ("step %d: unknown skill %s"):format(#steps + 1, words[1]) end
      local step, bare = { skill = skill.name }, {}
      for i = 2, #words do
        local key, value = words[i]:match("^(%w+)=(.+)$")
        if key then step[key] = value else bare[#bare + 1] = words[i] end
      end
      for _, spec in ipairs(skill.args or {}) do
        if #bare > 0 and not spec.hidden and step[spec[1]] == nil then step[spec[1]] = table.remove(bare, 1) end
      end
      if #bare > 0 then return nil, ("step %d (%s): too many values"):format(#steps + 1, skill.name) end
      steps[#steps + 1] = step
    end
  end
  local ok, err = M.check(steps, skills)
  if not ok then return nil, err end
  return steps
end

local function outcome(step, result)
  local parts = { step.skill.name }
  for key, value in pairs(result) do
    if key ~= "ok" and key ~= "error" and type(value) ~= "table" then
      parts[#parts + 1] = ("%s=%s"):format(key, tostring(value))
    end
  end
  return table.concat(parts, " ")
end

-- <Claude> Runs checked steps in order, stopping at the first failure.
-- Returns ok, stepsRun, results. onStep(i, step) is called before each step.
-- Skills get ctx = { state, save(state) }: state is the checkpoint they
-- saved before a reboot (nil on a fresh start). Saving only lasts with a
-- journal (bot/job.lua), which also says where to resume: { step, state,
-- results, begin(i), checkpoint(i, state), finish(i, result) }.
function M.run(steps, onStep, journal)
  local results = journal and journal.results or {}
  local first = journal and journal.step or 1
  for i = first, #steps do
    local step = steps[i]
    if onStep then onStep(i, step) end
    local state = journal and i == first and journal.state or nil
    if journal and state == nil then journal.begin(i) end
    local ctx = { state = state, save = function(s) if journal then journal.checkpoint(i, s) end end }
    local ok, result = pcall(step.skill.run, step.args, ctx)
    if not ok then
      if result == "Terminated" then error(result, 0) end
      result = { ok = false, error = tostring(result) }
    elseif type(result) ~= "table" then
      result = { ok = false, error = "skill returned no result" }
    end
    results[i] = result
    if journal then journal.finish(i, result) end
    if not result.ok then return false, i, results end
  end
  return true, #steps, results
end

-- <Claude> Turns M.run's return values into a compact report:
-- { ok = true, summary } | { ok = false, error, failed, completed }.
function M.report(steps, ok, n, results)
  local done = {}
  for i = 1, ok and n or n - 1 do done[i] = outcome(steps[i], results[i]) end
  if ok then return { ok = true, summary = "Done: " .. table.concat(done, "; ") } end
  return {
    ok = false,
    error = ("step %d (%s) failed: %s"):format(n, steps[n].skill.name, tostring(results[n].error)),
    failed = outcome(steps[n], results[n]),
    completed = #done > 0 and table.concat(done, "; ") or "nothing",
  }
end

-- <Claude> The runPlan tool for llm/agent.lua. It is `final`: a plan that
-- succeeds ends the run with a Lua-written summary, no extra LLM call.
-- A failure returns the step's result, what got done and fresh state, so
-- the model can send a new plan for the rest.
function M.tool(skills, state, onStep)
  return {
    description = "Run skills in order on the turtle. Nothing is reported back unless a step fails.",
    parameters = { type = "object", required = { "steps" }, properties = {
      steps = { type = "array", items = M.stepSchema(skills) },
    } },
    final = true,
    handler = function(a)
      local steps, err = M.check(a.steps, skills)
      if not steps then return { ok = false, error = "plan rejected, nothing ran: " .. err } end
      local report = M.report(steps, M.run(steps, onStep))
      if not report.ok then report.state = state() end
      return report
    end,
  }
end

return M
