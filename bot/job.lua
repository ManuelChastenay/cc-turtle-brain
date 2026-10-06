--[[ <Claude>
  A worker's current job, saved to disk so it survives a reboot (server
  restart, chunk unload). /job.json holds the steps (plain data), the step
  being run, that step's checkpoint (e.g. how far mineArea got) and the
  results so far. When the job ends, its result message moves to
  /job_result.json and stays there until the brain acknowledges it, so a
  brain that was down can still collect it. A job that did not finish
  (stopped, or a step failed) moves to /job_last.json with its step and
  checkpoint, until a `retry` carries on with it (or another job is stopped
  or fails); jobs that finish in between leave it alone, so a dig can be
  stopped, sent home, then retried.
]]
local M = {}

local JOB, RESULT, LAST = "/job.json", "/job_result.json", "/job_last.json"

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
function M.last() return read(LAST) end
function M.canRetry() return fs.exists(LAST) end

-- <Claude> Saves a new job and returns its record.
function M.start(id, boss, steps)
  local record = { id = id, boss = boss, steps = steps, step = 1, results = {} }
  write(JOB, record)
  return record
end

-- <Claude> The last job that did not finish (M.last()) is the current job
-- again, under a new id and boss, from the step and checkpoint it stopped at.
function M.retry(record, id, boss)
  record.id, record.boss = id, boss
  write(JOB, record)
  fs.delete(LAST)
  return record
end

-- <Claude> The journal plan.run saves progress through (see bot/plan.lua).
-- A failed step keeps its step number and checkpoint, for a retry.
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
      record.results[i] = result
      if result.ok then record.step, record.state = i + 1, nil end
      write(JOB, record)
    end,
  }
end

-- <Claude> The job is over: keep its result message until acknowledged, and
-- the job itself for a retry if it did not finish.
function M.finish(result)
  write(RESULT, result)
  local record = not result.ok and read(JOB)
  if record then write(LAST, record) end
  fs.delete(JOB)
end

return M
