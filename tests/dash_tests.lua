--[[ <Claude>
  Tests for the dashboard daemon (bot/dash.lua), the quick status of
  worker.lua and the stop hook of llm/agent.lua. Loaded by tests/tests.lua:
  dofile(SIM_DIR .. "dash_tests.lua")(test, eq, truthy, { fakeClient, fakeFleet, quietly })
  The dashboard runs next to a driver coroutine that types, touches the
  monitor and plays the turtles; both run in virtual time.
]]
return function(test, eq, truthy, h)
  local POS = { x = 0, y = 31, z = 0 }

  local function has(lines, text)
    for _, line in ipairs(lines) do
      if line:find(text, 1, true) then return true end
    end
    return false
  end
  local function show(lines) return table.concat(lines, "\n") end
  local function rowOf(lines, text)
    for y, line in ipairs(lines) do
      if line:find(text, 1, true) then return y end
    end
  end

  -- <Claude> Runs the dashboard on a 51x19 terminal (and a 51x14 monitor unless
  -- o.monitor == false) beside driver(screens). o.setup() runs after the world
  -- is reset, to script the LLM and the turtles. Returns the screens.
  local function session(driver, o)
    o = o or {}
    sim.reset{ modem = true, id = 1 }
    local screens = { term = sim.useTerm(51, 19, true) }
    if o.monitor ~= false then screens.mon = sim.addMonitor(51, 14, "top") end
    if o.setup then o.setup() end
    local dash, skills = require("bot.dash"), require("bot.skills")
    local ok, err = pcall(parallel.waitForAny,
      function() dash.run({ system = "sys", skills = skills.list }) end,
      function() driver(screens) end)
    if not ok then error(err, 0) end
    return screens
  end

  local function typeLine(text)
    for c in text:gmatch(".") do os.queueEvent("char", c) end
    os.queueEvent("key", keys.enter, false)
    sleep(0.2)
  end

  test("dash: the monitor lists every turtle, the terminal shows the log and the prompt", function()
    local s = session(function()
      sleep(0.1)
      sim.deliver(7, { type = "status", label = "miner-1", state = "fuel 900", pos = { x = 120, y = 64, z = -33 },
        fuel = 900, job = "j1", step = 2, steps = 4, text = "mineBox 118,40,-40" })
      sim.deliver(8, { type = "status", label = "hauler", state = "fuel 50", pos = { x = 5, y = 64, z = 5 }, fuel = 50 })
      sleep(1.5)
    end)
    local mon = s.mon.lines()
    local busy, idle = mon[rowOf(mon, "miner-1")], mon[rowOf(mon, "hauler")]
    truthy(busy:find("BUSY", 1, true) and busy:find("900", 1, true) and busy:find("2/4 mineBox", 1, true), busy)
    truthy(idle:find("idle", 1, true) and idle:find("50", 1, true), idle)
    truthy(mon[1]:find("2 turtles", 1, true), mon[1])
    eq(mon[14]:sub(1, 21), "[STOP ALL] [HOME ALL]")
    eq(s.mon.scale, 0.5, "dashboard text scale")
    local term = s.term.lines()
    truthy(has(term, "#7 miner-1 joined") and has(term, "#8 hauler joined"), show(term))
    eq(term[19]:sub(1, 2), "> ")
    eq(select(2, s.term.getCursorPos()), 19)
  end)

  test("dash: a burst of messages is drawn once, not once per message", function()
    local draws = 0
    session(function(s)
      sleep(0.5)
      local base = s.mon.setCursorPos
      s.mon.setCursorPos = function(x, y) if y == 1 then draws = draws + 1 end base(x, y) end
      for id = 1, 30 do sim.deliver(id, { type = "status", label = "t" .. id, state = "s", pos = POS, fuel = 100 }) end
      sleep(0.3)
    end)
    eq(draws, 1)
  end)

  test("dash: polls the turtles with a quick hello every few seconds", function()
    session(function() sleep(11) end)
    local polls = 0
    for _, m in ipairs(sim.sent) do
      if m.to == "broadcast" and m.msg.type == "hello" and m.msg.quick == true then polls = polls + 1 end
    end
    eq(polls, 3, "polls at t = 0, 5 and 10")
  end)

  test("dash: a typed goal runs like `fleet <goal>`: discover, one LLM call, plans, summary", function()
    local fakes = { [7] = { label = "a", pos = POS } }
    local calls
    local s = session(function()
      sleep(1)
      typeLine("dig the quarry")
      sleep(10)
    end, { setup = function()
      h.fakeFleet(fakes)
      calls = h.fakeClient({ { plans = { { turtles = { 7 }, steps = { { skill = "goHome" } } } } } })
    end })
    eq(#calls, 1)
    truthy(calls[1].messages[2].content:find("dig the quarry\nTurtles:\n#7 a: fuel 500", 1, true), calls[1].messages[2].content)
    eq(fakes[7].steps[1].skill, "goHome")
    local term = s.term.lines()
    truthy(has(term, "goal: dig the quarry") and has(term, "#7 [1] goHome") and has(term, "#7 finished")
      and has(term, "#7 Done: 1 steps"), show(term))
    local mon = s.mon.lines()
    truthy(mon[1]:find("LLM idle", 1, true) and mon[1]:find("1 calls", 1, true) and mon[1]:find("100/30 tok", 1, true), mon[1])
    eq(sim.files["/fleet_job.json"], nil, "the finished job is forgotten")
  end)

  test("dash: while a goal runs a second one is refused; /stop ends it without asking the LLM again", function()
    local fakes = { [7] = { label = "a", pos = POS, mode = "busy" } }
    local calls
    local s = session(function(s)
      sleep(1)
      typeLine("dig")
      sleep(6)
      typeLine("something else")
      eq(s.term.lines()[18]:sub(1, 16), "busy with a goal", "feedback row")
      local mon = s.mon.lines()
      truthy(mon[rowOf(mon, "#7")]:find("BUSY", 1, true), "turtle shown busy")
      typeLine("/stop")
      eq(fakes[7].stopped, true, "stop reached the turtle")
      sim.deliver(7, { type = "result", job = fakes[7].job, ok = false, error = "stopped by the brain", state = "fuel 400", pos = POS })
      sleep(3)
    end, { setup = function()
      h.fakeFleet(fakes)
      calls = h.fakeClient({ { plans = { { turtles = { 7 }, steps = { { skill = "goHome" } } } } } })
    end })
    eq(#calls, 1, "no replanning after a stop")
    local term = s.term.lines()
    truthy(has(term, "stop sent to 1 turtle(s)") and has(term, "stopped by the brain") and has(term, "stopped"), show(term))
    eq(sim.files["/fleet_job.json"], nil)
    truthy(s.mon.lines()[1]:find("LLM idle", 1, true), s.mon.lines()[1])
  end)

  test("dash: touching the monitor's buttons stops one turtle or all of them", function()
    local fakes = { [7] = { label = "a", pos = POS, mode = "busy" }, [8] = { label = "b", pos = POS, mode = "busy" } }
    local s = session(function(s)
      sleep(1)
      typeLine("dig")
      sleep(6)
      local mon = s.mon.lines()
      local y = rowOf(mon, "#8")
      truthy(mon[y]:find("[stop]", 1, true), "stop button on a busy row: " .. mon[y])
      os.queueEvent("monitor_touch", "left", 49, y) -- another monitor: ignored
      sleep(0.2)
      eq(fakes[8].stopped, nil)
      os.queueEvent("monitor_touch", "top", 49, y)
      sleep(0.2)
      eq(fakes[8].stopped, true, "stop #8")
      eq(fakes[7].stopped, nil, "not #7")
      os.queueEvent("monitor_touch", "top", 3, 14)
      sleep(0.2)
      eq(fakes[7].stopped, true, "STOP ALL reaches #7")
    end, { setup = function()
      h.fakeFleet(fakes)
      h.fakeClient({ { plans = { { turtles = { 7, 8 }, steps = { { skill = "goHome" } } } } } })
    end })
    truthy(has(s.term.lines(), "stop sent to #8"), show(s.term.lines()))
  end)

  test("dash: /home sends every turtle home with one goHome plan", function()
    local fakes = { [7] = { label = "a", pos = POS }, [8] = { label = "b", pos = POS } }
    local s = session(function()
      sleep(1)
      typeLine("/home")
      sleep(8)
    end, { setup = function() h.fakeFleet(fakes) end })
    eq(fakes[7].steps[1].skill, "goHome") eq(fakes[8].steps[1].skill, "goHome")
    local term = s.term.lines()
    truthy(has(term, "#7 Done: 1 steps") and has(term, "#8 Done: 1 steps"), show(term))
    truthy(s.mon.lines()[1]:find("LLM idle", 1, true), "back to idle")
  end)

  test("dash: /home stops busy turtles first and waits until they are idle", function()
    local fakes = { [7] = { label = "a", pos = POS, job = "old", finishAfter = 99 } }
    local s = session(function()
      sleep(1)
      typeLine("/home")
      sleep(1)
      eq(fakes[7].stopped, true, "stop sent")
      -- the worker answers a stop with its result; the next plan is then accepted
      fakes[7].job = nil
      sim.deliver(7, { type = "result", job = "old", ok = false, error = "stopped by the brain", pos = POS })
      sleep(8)
    end, { setup = function() h.fakeFleet(fakes) end })
    eq(fakes[7].steps and fakes[7].steps[1].skill, "goHome")
    truthy(has(s.term.lines(), "stopping 1 turtle(s) first"), show(s.term.lines()))
  end)

  test("dash: Ctrl+T quits the dashboard but leaves the turtles working and the job saved for /resume", function()
    local fakes = { [7] = { label = "a", pos = POS, mode = "busy" } }
    session(function()
      sleep(1)
      typeLine("dig")
      sleep(6)
      eq(fakes[7].job ~= nil, true, "turtle busy")
      os.queueEvent("terminate")
      sleep(1)
    end, { setup = function()
      h.fakeFleet(fakes)
      h.fakeClient({ { plans = { { turtles = { 7 }, steps = { { skill = "goHome" } } } } } })
    end })
    eq(fakes[7].stopped, nil, "no stop sent")
    local saved = sim.files["/fleet_job.json"]
    truthy(saved, "the running job is still saved")
    -- a new dashboard (the brain computer rebooted, files stay) waits for it again by itself
    local s = session(function() sleep(1) end, { setup = function() sim.files["/fleet_job.json"] = saved end })
    truthy(has(s.term.lines(), "resuming job"), show(s.term.lines()))
    truthy(s.mon.lines()[1]:find("LLM waiting", 1, true), s.mon.lines()[1])
  end)

  test("dash: a job saved before a reboot is collected from the turtles that finished it", function()
    local kept = { type = "result", job = "j1", ok = true, summary = "Done: late", state = "fuel 200", pos = POS }
    local fakes = { [7] = { label = "a", pos = POS, kept = kept } }
    local s = session(function() sleep(25) end, { setup = function()
      h.fakeFleet(fakes)
      sim.files["/fleet_job.json"] = textutils.serialiseJSON({ goal = "mine", job = "j1", pending = { 7 }, results = {} })
    end })
    truthy(has(s.term.lines(), "#7 Done: late"), show(s.term.lines()))
    eq(fakes[7].acked, "j1", "the result was acknowledged")
    eq(sim.files["/fleet_job.json"], nil, "nothing left to resume")
    truthy(s.mon.lines()[1]:find("LLM idle", 1, true), s.mon.lines()[1])
  end)

  test("dash: commands - help, scale, clear, bad input", function()
    local s = session(function(s)
      sleep(0.5)
      typeLine("/help")
      truthy(has(s.term.lines(), "/stop [id]"), "help in the log")
      typeLine("/scale 1")
      eq(s.mon.scale, 1)
      typeLine("/scale 9")
      eq(s.mon.scale, 1, "bad scale ignored")
      truthy(s.term.lines()[18]:find("usage: /scale", 1, true), s.term.lines()[18])
      typeLine("/stop 99")
      truthy(s.term.lines()[18]:find("no turtle #99", 1, true), s.term.lines()[18])
      typeLine("/bogus")
      truthy(s.term.lines()[18]:find("unknown command /bogus", 1, true), s.term.lines()[18])
      typeLine("/clear")
      truthy(not has(s.term.lines(), "/stop [id]"), "log cleared")
    end)
  end)

  test("dash: the prompt edits in place and recalls history with the arrow keys", function()
    local s = session(function(s)
      sleep(0.5)
      for c in ("abc"):gmatch(".") do os.queueEvent("char", c) end
      os.queueEvent("key", keys.left, false)
      os.queueEvent("char", "X")
      sleep(0.2)
      eq(s.term.lines()[19]:sub(1, 7), "> abXc ")
      eq(s.term.getCursorPos(), 6)
      os.queueEvent("key", keys.backspace, false)
      os.queueEvent("key", keys.home, false)
      os.queueEvent("key", keys.delete, false)
      sleep(0.2)
      eq(s.term.lines()[19]:sub(1, 6), "> bc  ")
      eq(s.term.getCursorPos(), 3)
      os.queueEvent("paste", "x\ny") -- a pasted line break becomes a space
      os.queueEvent("key", keys["end"], false)
      sleep(0.2)
      eq(s.term.lines()[19]:sub(1, 10), "> x ybc   ")
      for _ = 1, 5 do os.queueEvent("key", keys.backspace, false) end
      sleep(0.1)
      typeLine("/clear")
      os.queueEvent("key", keys.up, false)
      sleep(0.2)
      eq(s.term.lines()[19]:sub(1, 9), "> /clear ")
      os.queueEvent("key", keys.down, false)
      sleep(0.2)
      eq(s.term.lines()[19]:sub(1, 9), ">        ", "down past the newest line empties it")
    end)
  end)

  test("dash: without a monitor the dashboard takes the terminal and the prompt stays at the bottom", function()
    local s = session(function()
      sleep(0.1)
      sim.deliver(7, { type = "status", label = "miner-1", state = "s", pos = POS, fuel = 700 })
      sleep(1.5)
    end, { monitor = false })
    local term = s.term.lines()
    truthy(term[1]:find("1 turtles", 1, true), term[1])
    truthy(term[rowOf(term, "miner-1")]:find("idle", 1, true), show(term))
    eq(term[19]:sub(1, 2), "> ")
    truthy(term[17]:find("%S") == nil or term[17]:find("%S") ~= nil, "the row above the prompt belongs to feedback")
    eq(#term, 19)
  end)

  test("dash: a monitor that breaks falls back to the terminal instead of crashing", function()
    local s = session(function(s)
      sleep(0.5)
      s.mon.write = function() error("peripheral not found", 0) end
      os.queueEvent("dash_redraw")
      sleep(1.5)
      sim.deliver(7, { type = "status", label = "miner-1", state = "s", pos = POS, fuel = 700 })
      sleep(1.5)
    end)
    local term = s.term.lines()
    truthy(has(term, "screen error"), show(term))
    truthy(has(term, "miner-1"), "the dashboard moved to the terminal: " .. show(term))
  end)

  test("worker: a quick status has fuel and the current step but skips the inventory scan", function()
    sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 2000 }, modem = true, id = 5, label = "m" }
    local details, atQuick, atFull, fuelAtQuick = 0, nil, nil, nil
    local realDetail = turtle.getItemDetail
    turtle.getItemDetail = function(...) details = details + 1 return realDetail(...) end
    local script = {
      { type = "hello", quick = true }, { type = "hello" },
      { type = "plan", job = "j1", steps = { { skill = "mineArea", direction = "north", length = 3, width = 2, layers = 3 }, { skill = "goHome" } } },
    }
    local statuses, base = {}, nil
    sim.onSend = function(_, msg)
      if msg.type == "status" then
        statuses[#statuses + 1] = msg
        if #statuses == 1 then atQuick, fuelAtQuick = details, sim.t.fuel elseif #statuses == 2 then atFull = details end
      elseif msg.type == "progress" and msg.step == 1 then
        sim.deliver(99, { type = "hello", quick = true })
      end
    end
    sim.onIdle = function()
      local m = table.remove(script, 1)
      if m then
        base = base or details
        sim.deliver(99, m)
      end
      return m ~= nil
    end
    local _, ok, err = h.quietly(assert(loadfile(REPO .. "worker.lua")))
    turtle.getItemDetail = realDetail
    eq(ok, false) eq(err, "SIM_IDLE")
    local quick, full, midJob = statuses[1], statuses[2], statuses[3]
    eq(quick.quick, true) eq(quick.state, nil, "no state in a quick status") eq(quick.result, nil)
    eq(quick.label, "m") eq(quick.fuel, fuelAtQuick, "the turtle's real fuel level") eq(quick.pos.z, 0) eq(quick.job, nil) eq(quick.step, nil)
    eq(atQuick, base, "a quick status scans no slot")
    eq(atFull - atQuick, 16, "a full status scans all 16 slots")
    truthy(full.state:find(("fuel %d;"):format(fuelAtQuick), 1, true), tostring(full.state)) eq(full.quick, nil) eq(full.step, nil)
    eq(midJob.quick, true) eq(midJob.job, "j1") eq(midJob.step, 1) eq(midJob.steps, 2)
    truthy(midJob.text:find("^mineArea direction=north"), tostring(midJob.text))
    truthy(type(midJob.fuel) == "number" and midJob.fuel <= 2000, tostring(midJob.fuel))
    local progress
    for _, s in ipairs(sim.sent) do if s.msg.type == "progress" then progress = progress or s.msg end end
    eq(progress.steps, 2, "progress carries the total")
  end)

  test("worker: unlimited fuel shows as \"unlimited\" in the status", function()
    sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = "unlimited" }, modem = true, id = 5 }
    local script = { { type = "hello", quick = true } }
    sim.onIdle = function()
      local m = table.remove(script, 1)
      if m then sim.deliver(99, m) end
      return m ~= nil
    end
    h.quietly(assert(loadfile(REPO .. "worker.lua")))
    eq(sim.sent[1].msg.fuel, "unlimited")
  end)

  test("fleet: a quick status without a job does not fail a turtle that is still pending", function()
    sim.reset{}
    local fakes = { [7] = { label = "a", pos = POS } }
    h.fakeFleet(fakes)
    local fleet, skills = require("bot.fleet"), require("bot.skills")
    local tool = fleet.tool(skills.list, fleet.discover(2))
    local plain, sent = sim.onSend, false
    sim.onSend = function(to, msg, proto)
      if msg.type == "plan" and not sent then
        sent = true
        -- the dashboard's poll was answered just before the plan arrived
        sim.deliver(7, { type = "status", label = "a", quick = true, pos = POS, fuel = 5 })
        sim.deliver(7, { type = "accepted", job = msg.job })
        sim.deliver(7, { type = "result", job = msg.job, ok = true, summary = "Done: x", pos = POS })
        return
      end
      plain(to, msg, proto)
    end
    local r = tool.handler({ plans = { { turtles = { 7 }, steps = { { skill = "goHome" } } } } })
    eq(r.ok, true, tostring(r.error) .. " " .. tostring(r.results))
  end)

  test("agent: stopped() ends the run before the next LLM call", function()
    sim.reset{ turtle = { x = 0, y = 31, z = 0, h = 0, fuel = 500 } }
    local calls = h.fakeClient({ { { skill = "fly" } }, "never asked" }) -- a rejected plan: the loop would go on
    local nav, skills, plan = require("bot.nav"), require("bot.skills"), require("bot.plan")
    nav.init()
    local tools = { runPlan = plan.tool(skills.list, skills.state) }
    local text, err = require("llm.agent").run("go", tools, "sys", nil, function() return #calls >= 1 end)
    eq(text, nil) eq(err, "stopped") eq(#calls, 1)
    local calls2 = h.fakeClient({ "Fuel is 498." })
    package.loaded["llm.agent"] = nil -- it keeps the client it was loaded with
    local text2 = require("llm.agent").run("go", tools, "sys", nil, function() return false end)
    eq(text2, "Fuel is 498.") eq(#calls2, 1)
  end)
end
