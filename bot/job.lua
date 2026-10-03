--[[ <Claude>
  A worker's current job, saved to disk so it survives a reboot (server
  restart, chunk unload). /job.json holds the steps (plain data), the step
  being run, that step's checkpoint (e.g. how far mineArea got) and the
  results so far. When the job ends, its result message moves to
  /job_result.json and stays there until the brain acknowledges it, so a
  brain that was down can still collect it.
]]
local M = {}

local JOB, RESULT = "/job.json", "/job_result.json"

local function read(path)
  local f = fs.open(path, "r")
  if not f then return nil end
  local data = textutils.unserialiseJSON(f.readAll())
  f.close()
  return type(data) == "table" and data or nil
end

local function write(path, data)
  local f = fs.open(path, "w")
  f.write(textutils.serialiseJSON(data))
  f.close()
end

function M.load() return read(JOB) end
function M.result() return read(RESULT) end
function M.clearResult() fs.delete(RESULT) end

-- <Claude> Saves a new job and returns its record.
function M.start(id, boss, steps)
  local record = { id = id, boss = boss, steps = steps, step = 1, results = {} }
  write(JOB, record)
  return record
end

-- <Claude> The journal plan.run saves progress through (see bot/plan.lua).
function M.journal(record)
  return {
    step = record.step, state = record.state, results = record.results,
    begin = function(i)
      record.step, record.state = i, nil
      write(JOB, record)
    end,
    checkpoint = function(i, state)
      record.step, record.state = i, state
      write(JOB, record)
    end,
    finish = function(i, result)
      record.results[i], record.step, record.state = result, i + 1, nil
      write(JOB, record)
    end,
  }
end

-- <Claude> The job is over: keep its result message until acknowledged.
function M.finish(result)
  write(RESULT, result)
  fs.delete(JOB)
end

return M
