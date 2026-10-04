--[[ <Claude>
  What the dashboard knows about the fleet: one record per turtle, updated
  from the rednet messages the brain hears (status, progress, accepted,
  result; see bot/net.lua), plus a short event log. No rednet or terminal
  calls here: the caller passes every message in with the time it arrived,
  so it tests in a fake world and the same table can be shared with
  bot/fleet.lua (`turtles`).
    record = { id, label, state = "<status line>", pos, job, fuel,
               step, steps, text, seen, version }
  `state` is the status text the planner reads (as fleet.discover gives it).
  What the screen shows (idle / busy / lost) comes from M.mode().
]]
local M = {}

M.LOST_AFTER = 60 -- seconds without any message before a turtle shows as lost
M.LOG_MAX = 200

local function short(s, n)
  s = tostring(s or "")
  return #s > n and s:sub(1, n - 2) .. ".." or s
end

-- <Claude> reg.turtles is the roster table other code may hold on to; every
-- function below only reads or writes through it.
function M.new(opts)
  opts = opts or {}
  local reg = { turtles = {}, log = {}, stamp = opts.stamp or function() return os.date("%H:%M") end }

  function reg.note(text, now)
    reg.log[#reg.log + 1] = reg.stamp(now) .. " " .. text
    if #reg.log > M.LOG_MAX then table.remove(reg.log, 1) end
  end

  local function get(id)
    local rec = reg.turtles[id]
    if not rec then
      rec = { id = id, state = "?" }
      reg.turtles[id] = rec
    end
    return rec
  end

  -- <Claude> Returns true when what the screen shows may have changed.
  function reg.apply(from, msg, now)
    if type(msg) ~= "table" or type(from) ~= "number" then return false end
    local t = msg.type
    if t ~= "status" and t ~= "progress" and t ~= "accepted" and t ~= "result" then return false end
    local known = reg.turtles[from] ~= nil
    local rec = get(from)
    rec.seen = now
    if t == "status" then
      local before = rec.version
      rec.version = msg.version or rec.version -- "v8 d2ffe09"; workers older than versions send none
      rec.label, rec.state, rec.pos, rec.fuel = msg.label or rec.label, msg.state or rec.state, msg.pos or rec.pos, msg.fuel
      rec.job = msg.job
      if msg.job then
        rec.step, rec.steps, rec.text = msg.step, msg.steps, msg.text
      else
        rec.step, rec.steps = nil, nil
      end
      if not known then
        reg.note(("#%d %s joined%s"):format(from, rec.label or "unlabeled", rec.version and (", " .. rec.version) or ""), now)
      elseif before and rec.version ~= before then
        reg.note(("#%d now runs %s"):format(from, rec.version), now) -- back from an update
      end
    elseif t == "progress" then
      rec.job, rec.step, rec.steps, rec.text = msg.job, msg.step, msg.steps or rec.steps, msg.text
      reg.note(("#%d [%s] %s"):format(from, tostring(msg.step), tostring(msg.text)), now)
    elseif t == "accepted" then
      rec.job = msg.job
    else -- result
      rec.job, rec.step, rec.steps = nil, nil, nil
      rec.pos, rec.state = msg.pos or rec.pos, msg.state or rec.state
      if msg.ok then
        rec.text = "finished"
        reg.note(("#%d finished"):format(from), now)
      else
        rec.text = "failed: " .. tostring(msg.error)
        reg.note(("#%d %s"):format(from, short(msg.error, 70)), now)
      end
    end
    return true
  end

  function reg.mode(rec, now)
    if not rec.seen or now - rec.seen > M.LOST_AFTER then return "lost" end
    return rec.job and "busy" or "idle"
  end

  function reg.ids()
    local ids = {}
    for id in pairs(reg.turtles) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
  end

  -- <Claude> The list bot/ui.lua draws, sorted by id. `extra` adds the fields
  -- the registry does not own (llm, calls, tokensIn, tokensOut, goal, lowFuel).
  function reg.view(now, extra)
    local view, list = {}, {}
    for k, v in pairs(extra or {}) do view[k] = v end
    for _, id in ipairs(reg.ids()) do
      local rec = reg.turtles[id]
      list[#list + 1] = {
        id = id, label = rec.label, state = reg.mode(rec, now), pos = rec.pos, fuel = rec.fuel,
        step = rec.step, steps = rec.steps, text = rec.text,
        silent = rec.seen and now - rec.seen or nil,
      }
    end
    view.turtles, view.log = list, reg.log
    return view
  end

  return reg
end

return M
