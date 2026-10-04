--[[ <Claude>
  Fleet dashboard daemon (`fleet dash`, fleet.lua starts it). One program on
  the brain computer that stays up:
    - a monitor (if attached) shows every turtle: state, position, fuel, the
      step it is on, the event log, and touch buttons (STOP ALL, HOME ALL, a
      stop per busy turtle). Without a monitor the dashboard takes the
      terminal.
    - the terminal's last line is a prompt: text is a goal for the LLM
      (the same flow as `fleet <goal>`), /commands run in Lua at once.
  Coroutines under parallel: listener (rednet -> bot/registry), ticker (poll
  the turtles with a quick hello, redraw every second), screen, keyboard,
  touches and runner (goals, home, refuel, update, resume: one at a time,
  because the fleet saves a single job). A blocking http.post in the runner
  only stops the runner: every other coroutine still gets every event.
  The drawing is bot/ui.lua, the state bot/registry.lua.
  /exit or Ctrl+T quits the dashboard only and gives the terminal back to
  the shell: the turtles are not told to stop and the saved job stays; the
  next `fleet dash` (e.g. from startup.lua after a reboot) waits for it
  again, and workers keep their results until acknowledged. Stopping turtles
  is /stop, or the buttons.
]]
local agent = require("llm.agent")
local fleet = require("bot.fleet")
local net = require("bot.net")
local registry = require("bot.registry")
local ui = require("bot.ui")

local M = {}

M.POLL_EVERY = 5 -- seconds between quick hellos
local HOME_WAIT = 15 -- seconds a stopped turtle gets to go idle before the goHome plan
local LOG_WIDTH = 44

local HELP = {
  "/stop [id]  stop every turtle and the goal, or one turtle",
  "/home [id]  stop everything, then send turtles home",
  "/refuel [id] idle turtles burn what burns",
  "/update [id] idle turtles reinstall and reboot",
  "/resume     wait again for an interrupted job",
  "/scale n    monitor text scale, 0.5 to 5",
  "/clear      clear the log",
  "/exit       back to the shell, turtles go on",
  "Anything else is a goal for the LLM.",
}

-- <Claude> Cuts a string to exactly w characters (padding with spaces).
local function fit(s, w)
  s = tostring(s)
  if #s > w then return s:sub(1, w) end
  return s .. (" "):rep(w - #s)
end

-- <Claude> Text broken into lines of at most `width` characters, at spaces where it can.
local function wrap(text, width)
  local out = {}
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    while #line > width do
      local cut = width
      local space = line:sub(1, width + 1):match("^.*() ")
      if space and space > width / 2 then cut = space end
      out[#out + 1] = (line:sub(1, cut):gsub("%s+$", ""))
      line = (line:sub(cut + 1):gsub("^%s+", ""))
    end
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

-- <Claude> opts = { system = LLM system prompt, skills = skill list, scale = monitor text scale }.
-- Returns when Ctrl+T is pressed; turtles keep working (see the header).
function M.run(opts)
  local skills = opts.skills or require("bot.skills").list
  local reg = registry.new()
  local state = { llm = "idle", calls = 0, tokensIn = 0, tokensOut = 0, goal = nil }
  local editor = { text = "", pos = 0, history = {}, hist = nil }
  local feedback = "type a goal, or /help"
  local queue, pending, cancelled = {}, 0, false

  local monitor = peripheral.find("monitor")
  local monName, monLayout
  if monitor then
    monName = peripheral.getName and peripheral.getName(monitor)
    monitor.setTextScale(opts.scale or 0.5)
    monitor.setCursorBlink(false)
  end

  local function dirty() os.queueEvent("dash_redraw") end

  local function say(text)
    for _, line in ipairs(wrap(text, LOG_WIDTH)) do reg.note(line) end
    dirty()
  end

  -- <Claude> ---------------------------------------------------------- drawing
  local function top(rows) -- the terminal without its last rows, for ui.draw
    return setmetatable({ getSize = function() return (term.getSize()), rows end },
      { __index = function(_, k) return term[k] end })
  end

  local function draw()
    local view = reg.view(os.clock(), { llm = state.llm, calls = state.calls, tokensIn = state.tokensIn,
      tokensOut = state.tokensOut, goal = state.goal })
    if monitor then monLayout = ui.draw(monitor, view) end
    local w, h = term.getSize()
    local body = math.max(1, h - 2)
    if monitor then
      local log = view.log
      for y = 1, body do
        term.setCursorPos(1, y)
        term.write(fit(log[#log - body + y] or "", w))
      end
    else
      ui.draw(top(body), view)
      if term.isColor and term.isColor() then
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
      end
    end
    term.setCursorPos(1, h - 1)
    term.write(fit(feedback, w))
    local room = w - 2
    local first = math.max(0, editor.pos - room + 1)
    term.setCursorPos(1, h)
    term.write(fit("> " .. editor.text:sub(first + 1, first + room), w))
    term.setCursorPos(3 + editor.pos - first, h)
    term.setCursorBlink(true)
  end

  local function screen()
    local function safeDraw()
      local ok, err = pcall(draw)
      if not ok then
        if err == "Terminated" then error(err, 0) end
        reg.note("screen error: " .. tostring(err))
        monitor = nil -- a detached monitor must not take the dashboard down
      end
    end
    safeDraw()
    while true do
      local ev
      repeat ev = os.pullEvent() until ev == "dash_redraw" or ev == "monitor_resize" or ev == "term_resize"
      -- <Claude> A burst (every turtle answering one poll) draws once, a moment later.
      local timer = os.startTimer(0.1)
      local fired
      repeat
        local e, id = os.pullEvent()
        fired = e == "timer" and id == timer
      until fired
      safeDraw()
    end
  end

  -- <Claude> ---------------------------------------------------------- network
  local function listener()
    while true do
      local from, msg = rednet.receive(net.PROTOCOL)
      if reg.apply(from, msg, os.clock()) then dirty() end
    end
  end

  local function ticker()
    local n = 0
    while true do
      if n % M.POLL_EVERY == 0 then net.broadcast({ type = "hello", quick = true }) end
      n = n + 1
      sleep(1)
      dirty()
    end
  end

  -- <Claude> ---------------------------------------------------------- jobs
  local function onTool(name, result)
    if not result.ok then say(("> %s: %s"):format(name, tostring(result.error))) end
  end

  -- progress and results are already logged by the registry (it hears the same messages)
  local function onEvent(id, msg)
    if msg.type == "silent" then say(("#%d silent for %d s, still waiting"):format(id, msg.seconds)) end
  end

  -- <Claude> The outcome of a runPlans call made without the LLM (/home, /refuel).
  local function report(r)
    say(r.ok and r.summary or (r.error .. (r.results and ("\n" .. r.results) or "")))
  end

  -- <Claude> One LLM run: find the turtles, let the model plan, wait for them.
  -- A stop ends it without another LLM call (see agent.run's stopped()).
  local function ask(display, prompt)
    state.goal, state.llm = display, "thinking"
    say("goal: " .. display)
    local turtles = fleet.discover(2)
    if next(turtles) == nil then say("no turtle answered: is `worker` running on them?") return end
    local runPlans = fleet.tool(skills, turtles, onEvent, display)
    local inner = runPlans.handler
    runPlans.handler = function(a)
      if cancelled then return { ok = false, error = "stopped by the user" } end
      state.llm = "waiting"
      dirty()
      local result = inner(a)
      state.llm = "thinking"
      dirty()
      return result
    end
    local reply, stats = agent.run(prompt .. "\nTurtles:\n" .. fleet.describe(turtles), { runPlans = runPlans },
      opts.system, onTool, function() return cancelled end)
    if reply then
      fleet.clearRun()
      state.calls = state.calls + stats.turns
      state.tokensIn, state.tokensOut = state.tokensIn + stats.tokensIn, state.tokensOut + stats.tokensOut
      say(reply)
    elseif cancelled then
      fleet.clearRun()
      say("stopped")
    else
      say("LLM: " .. tostring(stats)) -- a saved job stays: /resume can wait for it
    end
  end

  local JOBS = {}

  function JOBS.goal(job) ask(job.text, job.text) end

  -- <Claude> Same as `fleet resume`: wait again for the job saved before a reboot.
  function JOBS.resume()
    local saved = fleet.loadRun()
    if not saved then say("nothing to resume") return end
    say(("resuming job %s: %s"):format(saved.job, tostring(saved.goal)))
    state.goal, state.llm = tostring(saved.goal), "waiting"
    local turtles = fleet.discover(2)
    for id in pairs(saved.pending) do turtles[id] = turtles[id] or { label = "?", state = "no answer yet" } end
    local text, failed = fleet.outcome(fleet.wait(saved, turtles, onEvent))
    say(text)
    if failed == 0 then fleet.clearRun() return end
    ask(tostring(saved.goal), tostring(saved.goal) .. "\nThis job was interrupted, then resumed. Outcome per turtle:\n"
      .. text .. "\nPlan only the work that is left, or reply in one line.")
  end

  -- <Claude> goHome for the turtles in job.ids (all if nil): busy ones are stopped first.
  function JOBS.home(job)
    state.goal, state.llm = "go home", "waiting"
    local turtles = fleet.discover(2)
    local ids = {}
    for id in pairs(turtles) do
      if not job.ids or job.ids[id] then ids[#ids + 1] = id end
    end
    table.sort(ids)
    if #ids == 0 then say("no turtle to send home") return end
    local busy = {}
    for _, id in ipairs(ids) do
      if turtles[id].job then
        net.send(id, { type = "stop" })
        busy[#busy + 1] = id
      end
    end
    if #busy > 0 then
      say(("stopping %d turtle(s) first"):format(#busy))
      local deadline = os.clock() + HOME_WAIT
      repeat
        sleep(0.5)
        local idle = true
        for _, id in ipairs(busy) do
          if reg.turtles[id] and reg.turtles[id].job then idle = false end
        end
      until idle or os.clock() >= deadline
      turtles = fleet.discover(2)
    end
    report(fleet.runSteps(skills, turtles, ids, { { skill = "goHome" } }, onEvent, "go home"))
  end

  -- <Claude> The idle turtles in job.ids (all if nil) burn what burns. Busy ones are left alone.
  function JOBS.refuel(job)
    state.goal, state.llm = "refuel", "waiting"
    local turtles = fleet.discover(2)
    local ids, busy = fleet.idle(turtles, job.ids)
    if busy > 0 then say(("refuel: %d busy turtle(s) left alone"):format(busy)) end
    if #ids == 0 then say("no idle turtle to refuel") return end
    report(fleet.runSteps(skills, turtles, ids, { { skill = "refuel" } }, onEvent, "refuel"))
  end

  -- <Claude> Turtles reinstall from GitHub and reboot (busy ones refuse). Not
  -- this computer: it is running the code (/exit, install, fleet dash).
  function JOBS.update(job)
    state.goal, state.llm = "update", "waiting"
    local ids = {}
    for id in pairs(fleet.discover(2)) do
      if not job.ids or job.ids[id] then ids[#ids + 1] = id end
    end
    table.sort(ids)
    if #ids == 0 then say("no turtle to update") return end
    say(("updating %d turtle(s) from GitHub"):format(#ids))
    say((fleet.outcome(fleet.update(ids, function(id, msg)
      if msg.type == "updating" then say(("#%d installing"):format(id)) end
    end))))
    say("this computer: /exit, install, fleet dash")
  end

  local function enqueue(job)
    queue[#queue + 1] = job
    pending = pending + 1
    os.queueEvent("dash_job")
  end

  local function runner()
    while true do
      while #queue == 0 do os.pullEvent("dash_job") end
      local job = table.remove(queue, 1)
      cancelled = false
      local ok, err = pcall(JOBS[job.kind], job)
      pending = pending - 1
      state.goal, state.llm = nil, "idle"
      if not ok then
        if err == "Terminated" then error(err, 0) end
        say("error: " .. tostring(err))
      end
      dirty()
    end
  end

  -- <Claude> ---------------------------------------------------------- commands
  local function stopOne(id)
    if not reg.turtles[id] then feedback = "no turtle #" .. tostring(id) return end
    net.send(id, { type = "stop" })
    say(("stop sent to #%d"):format(id))
  end

  -- <Claude> Stops every working turtle and, if a goal is running, ends it
  -- without asking the LLM to replan.
  local function stopAll()
    if pending > 0 then cancelled = true end
    local n = 0
    for id, rec in pairs(reg.turtles) do
      if rec.job then
        net.send(id, { type = "stop" })
        n = n + 1
      end
    end
    say(n > 0 and ("stop sent to %d turtle(s)"):format(n) or "stop: no turtle is working")
  end

  local function homeAll()
    stopAll()
    enqueue({ kind = "home" })
  end

  local function refuelAll()
    if pending > 0 then say("refuel: wait for the current job or stop it") else enqueue({ kind = "refuel" }) end
  end

  local function command(line)
    local name, rest = line:match("^/(%S+)%s*(.*)$")
    local id = tonumber(rest)
    if name == "stop" then
      if rest == "" then stopAll() elseif id then stopOne(id) else feedback = "usage: /stop [id]" end
    elseif name == "home" then
      if rest == "" then
        homeAll()
      elseif not id then
        feedback = "usage: /home [id]"
      elseif pending > 0 then
        feedback = "a goal is running: /stop it first, or /home for every turtle"
      elseif not reg.turtles[id] then
        feedback = "no turtle #" .. rest
      else
        enqueue({ kind = "home", ids = { [id] = true } })
      end
    elseif name == "resume" then
      if pending > 0 then feedback = "busy: wait for the current job or /stop it" else enqueue({ kind = "resume" }) end
    elseif name == "refuel" or name == "update" then
      if rest ~= "" and not id then
        feedback = ("usage: /%s [id]"):format(name)
      elseif pending > 0 then
        feedback = "busy: wait for the current job or /stop it"
      else
        enqueue({ kind = name, ids = id and { [id] = true } or nil })
      end
    elseif name == "exit" or name == "quit" then
      os.queueEvent("dash_exit")
    elseif name == "scale" then
      local scale = tonumber(rest)
      if not monitor then
        feedback = "no monitor attached"
      elseif not scale or not pcall(monitor.setTextScale, scale) then
        feedback = "usage: /scale 0.5 to 5 (steps of 0.5)"
      else
        feedback = "text scale " .. rest
      end
    elseif name == "clear" then
      for i = #reg.log, 1, -1 do reg.log[i] = nil end
    elseif name == "help" then
      for _, line in ipairs(HELP) do reg.note(line) end
    else
      feedback = ("unknown command /%s (try /help)"):format(tostring(name))
    end
    dirty()
  end

  local function submit()
    local line = editor.text:match("^%s*(.-)%s*$")
    editor.text, editor.pos, editor.hist = "", 0, nil
    if line == "" then return end
    editor.history[#editor.history + 1] = line
    if line:sub(1, 1) == "/" then
      feedback = ""
      command(line)
    elseif pending > 0 then
      feedback = "busy with a goal: /stop it first"
    else
      feedback = ""
      enqueue({ kind = "goal", text = line })
    end
  end

  -- <Claude> ---------------------------------------------------------- input
  local function typed(s)
    editor.text = editor.text:sub(1, editor.pos) .. s .. editor.text:sub(editor.pos + 1)
    editor.pos = editor.pos + #s
  end

  local function recall(index)
    editor.hist = index
    editor.text = index and editor.history[index] or ""
    editor.pos = #editor.text
  end

  local function onKey(code)
    local text, pos = editor.text, editor.pos
    if code == keys.enter or code == keys.numPadEnter then
      submit()
    elseif code == keys.backspace then
      if pos > 0 then editor.text, editor.pos = text:sub(1, pos - 1) .. text:sub(pos + 1), pos - 1 end
    elseif code == keys.delete then
      editor.text = text:sub(1, pos) .. text:sub(pos + 2)
    elseif code == keys.left then
      editor.pos = math.max(0, pos - 1)
    elseif code == keys.right then
      editor.pos = math.min(#text, pos + 1)
    elseif code == keys.home then
      editor.pos = 0
    elseif code == keys["end"] then
      editor.pos = #text
    elseif code == keys.up then
      if #editor.history > 0 then recall(math.max(1, (editor.hist or #editor.history + 1) - 1)) end
    elseif code == keys.down then
      if editor.hist then recall(editor.hist < #editor.history and editor.hist + 1 or nil) end
    end
  end

  local function keyboard()
    while true do
      local ev, a = os.pullEvent()
      if ev == "char" then
        typed(a)
        dirty()
      elseif ev == "paste" then
        typed((tostring(a):gsub("[\r\n]+", " ")))
        dirty()
      elseif ev == "key" then
        onKey(a)
        dirty()
      end
    end
  end

  local function touches()
    while true do
      local _, side, x, y = os.pullEvent("monitor_touch")
      if monitor and monLayout and (monName == nil or side == monName) then
        local a = ui.hit(monLayout, x, y)
        if a and a.type == "stop" then stopOne(a.id)
        elseif a and a.type == "stopAll" then stopAll()
        elseif a and a.type == "homeAll" then homeAll()
        elseif a and a.type == "refuelAll" then refuelAll() end
      end
    end
  end

  say(monitor and "dashboard up (monitor found)" or "dashboard up (no monitor: drawing on the terminal)")
  -- <Claude> A job saved before the last stop or reboot is picked up again, like `fleet resume`.
  if fleet.loadRun() then enqueue({ kind = "resume" }) end

  local function exit() os.pullEvent("dash_exit") end -- /exit

  local ok, err = pcall(parallel.waitForAny, listener, ticker, screen, keyboard, touches, runner, exit)
  -- <Claude> Hand the screens back: the shell prompt starts on a clean terminal.
  pcall(function()
    if not monitor then return end
    monitor.setTextColor(colors.white)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Dashboard closed. `fleet dash` reopens it.")
  end)
  if term.isColor and term.isColor() then
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
  end
  term.clear()
  term.setCursorBlink(false)
  term.setCursorPos(1, 1)
  term.write("Dashboard closed. Turtles keep working;")
  term.setCursorPos(1, 2)
  term.write("`fleet dash` reopens it.")
  term.setCursorPos(1, 3)
  if not ok and err ~= "Terminated" then error(err, 0) end
end

return M
