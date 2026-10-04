--[[ <Claude>
  Tests for bot/ui.lua (dashboard drawing). Loaded by tests/tests.lua:
  dofile(SIM_DIR .. "ui_tests.lua")(test, eq, truthy)
]]
return function(test, eq, truthy)
  local ui = require("bot.ui")

  local function fleet(n)
    local list = {}
    for i = 1, n do
      list[i] = { id = i, label = "t" .. i, state = "idle", pos = { x = i, y = 64, z = -i }, fuel = 900 }
    end
    return list
  end

  local function sample()
    return {
      llm = "thinking", calls = 2, tokensIn = 3100, tokensOut = 410, goal = "mine a 10x10 hole",
      turtles = {
        { id = 3, label = "miner-1", state = "busy", pos = { x = 120, y = 64, z = -33 }, fuel = 1840,
          step = 2, steps = 4, text = "mineBox 118,40,-40" },
        { id = 4, label = "miner-2", state = "idle", pos = { x = 131, y = 64, z = -30 }, fuel = 40, text = "finished" },
        { id = 7, label = "hauler", state = "lost", pos = { x = 100, y = 65, z = -20 }, fuel = 960, silent = 75.4 },
      },
      log = { "12:00 first", "12:01 second", "12:02 third", "12:03 fourth" },
    }
  end

  local function find(lines, pattern)
    for y, line in ipairs(lines) do
      if line:find(pattern, 1, true) then return y, line end
    end
  end

  test("ui: every row is exactly w wide and there are exactly h rows, at any size", function()
    for _, w in ipairs({ 12, 20, 29, 39, 51 }) do
      for _, h in ipairs({ 1, 3, 5, 12, 19, 26 }) do
        for _, n in ipairs({ 0, 1, 3, 30 }) do
          local view = sample()
          view.turtles = n == 3 and view.turtles or fleet(n)
          local layout = ui.layout(view, w, h)
          local tag = ("%dx%d with %d turtles"):format(w, h, n)
          eq(#layout.rows, h, tag .. " rows")
          for y, text in ipairs(ui.text(layout)) do eq(#text, w, tag .. " row " .. y) end
        end
      end
    end
  end)

  test("ui: header, turtle rows and goal show the state", function()
    local lines = ui.text(ui.layout(sample(), 78, 19))
    truthy(lines[1]:find("3 turtles", 1, true), lines[1])
    truthy(lines[1]:find("LLM thinking", 1, true), lines[1])
    truthy(lines[1]:find("2 calls", 1, true), lines[1])
    truthy(lines[1]:find("3.1k/410 tok", 1, true), lines[1])
    local _, busy = find(lines, "miner-1")
    truthy(busy:find("BUSY", 1, true) and busy:find("120,64,-33", 1, true) and busy:find("1840", 1, true), busy)
    truthy(busy:find("2/4 mineBox 118,40,-40", 1, true), busy)
    local _, idle = find(lines, "miner-2")
    truthy(idle:find("idle", 1, true) and idle:find("finished", 1, true), idle)
    local _, lost = find(lines, "hauler")
    truthy(lost:find("LOST", 1, true) and lost:find("silent 75s", 1, true), lost)
    truthy(find(lines, "goal: mine a 10x10 hole"), "goal line")
  end)

  test("ui: the header sheds the title, then tokens, then calls as the screen narrows", function()
    local view = sample()
    local function head(w) return ui.text(ui.layout(view, w, 12))[1] end
    truthy(head(62):find("^TURTLE BRAIN  3 turtles"), head(62))
    truthy(head(50):find("^3 turtles  LLM thinking  2 calls  3.1k/410 tok"), head(50))
    truthy(head(40):find("^3 turtles  LLM thinking  2 calls ") and not head(40):find("tok"), head(40))
    truthy(head(24):find("^3 turtles  LLM thinking") and not head(24):find("calls"), head(24))
  end)

  test("ui: log shows the newest lines that fit, oldest dropped", function()
    local view = sample()
    view.goal = nil
    local lines = ui.text(ui.layout(view, 51, 12)) -- 12 rows: 4 fixed + 3 turtles + 5 for the log
    truthy(find(lines, "12:03 fourth") and find(lines, "12:00 first"), "all four fit")
    local tight = ui.text(ui.layout(view, 51, 10)) -- room for only the 3 turtles' min log of 0 .. 3
    truthy(find(tight, "12:03 fourth"), "newest kept")
    truthy(not find(tight, "12:00 first"), "oldest dropped")
  end)

  test("ui: narrow screens drop the position, then the name, then the stop buttons", function()
    local function look(w)
      local layout = ui.layout(sample(), w, 19)
      local lines = ui.text(layout)
      local stops = 0
      for _, b in ipairs(layout.buttons) do if b.action.type == "stop" then stops = stops + 1 end end
      return find(lines, "miner-1") ~= nil, find(lines, "120,64,-33") ~= nil, stops, lines
    end
    local name, pos, stops = look(78)
    truthy(name and pos and stops == 1, "78 wide: everything")
    name, pos, stops = look(62)
    truthy(name and pos and stops == 1, "62 wide: everything")
    name, pos, stops = look(51)
    truthy(name and not pos and stops == 1, "51 wide: name, no position")
    name, pos, stops = look(39)
    truthy(not name and not pos and stops == 1, "39 wide: neither, stop kept")
    local _, _, none, lines = look(29)
    eq(none, 0, "29 wide: no stop buttons")
    truthy(find(lines, "BUSY") and find(lines, "[STOP ALL]"), "29 wide: still readable")
  end)

  test("ui: low fuel is red, normal fuel is white", function()
    local layout = ui.layout(sample(), 51, 19)
    local fg
    for _, row in ipairs(layout.rows) do
      for _, c in ipairs(row) do
        if c.text:find("40", 1, true) and c.text:match("^%s*40%s*$") then fg = c.fg end
      end
    end
    eq(fg, "red", "fuel 40 < 100")
    local view = sample()
    view.lowFuel = 10
    local layout2 = ui.layout(view, 51, 19)
    for _, row in ipairs(layout2.rows) do
      for _, c in ipairs(row) do
        if c.text:match("^%s*40%s*$") then eq(c.fg, "white", "fuel 40 >= 10") end
      end
    end
  end)

  test("ui: buttons - stop all, home all, refuel all and a stop per busy turtle", function()
    local layout = ui.layout(sample(), 51, 19)
    local lines = ui.text(layout)
    eq(lines[19]:sub(1, 35), "[STOP ALL] [HOME ALL] [REFUEL ALL] ")
    eq(ui.hit(layout, 3, 19).type, "stopAll")
    eq(ui.hit(layout, 10, 19).type, "stopAll")
    eq(ui.hit(layout, 11, 19), nil, "gap between the buttons")
    eq(ui.hit(layout, 12, 19).type, "homeAll")
    eq(ui.hit(layout, 21, 19).type, "homeAll")
    eq(ui.hit(layout, 22, 19), nil)
    eq(ui.hit(layout, 23, 19).type, "refuelAll")
    eq(ui.hit(layout, 34, 19).type, "refuelAll")
    eq(ui.hit(layout, 35, 19), nil)
    local y = find(lines, "miner-1")
    local act = ui.hit(layout, 49, y)
    truthy(act and act.type == "stop" and act.id == 3, "stop button of #3")
    eq(ui.hit(layout, 20, y), nil, "elsewhere on the row")
    eq(ui.hit(layout, 49, find(lines, "miner-2")), nil, "no stop for an idle turtle")
    eq(ui.hit(layout, 49, find(lines, "hauler")), nil, "no stop for a lost turtle")
  end)

  test("ui: many turtles collapse into '+N more' and the button bar stays", function()
    local view = sample()
    view.turtles = fleet(30)
    local layout = ui.layout(view, 51, 12)
    local lines = ui.text(layout)
    truthy(find(lines, "more turtles"), "overflow row")
    eq(lines[12]:sub(1, 10), "[STOP ALL]")
    eq(ui.hit(layout, 2, 12).type, "stopAll")
    local y, text = find(lines, "+")
    truthy(text:find("+%d+ more turtles"), text)
  end)

  test("ui: a tiny screen keeps the button bar on the last row", function()
    local layout = ui.layout(sample(), 51, 3)
    eq(#layout.rows, 3)
    eq(ui.text(layout)[3]:sub(1, 10), "[STOP ALL]")
    eq(ui.hit(layout, 1, 3).type, "stopAll")
    for _, b in ipairs(layout.buttons) do truthy(b.y >= 1 and b.y <= 3, "button on screen") end
  end)

  test("ui: draw writes every cell once, colors only on a color screen", function()
    local function fakeTerm(color)
      local t, calls = { out = {}, colored = 0 }, 0
      t.getSize = function() return 40, 12 end
      t.isColor = function() return color end
      t.setCursorPos = function(x, y) t.x, t.y = x, y end
      t.write = function(s) t.out[t.y] = (t.out[t.y] or "") .. s end
      t.setTextColor = function() t.colored = t.colored + 1 end
      t.setBackgroundColor = function() t.colored = t.colored + 1 end
      return t
    end
    local saved = colors
    colors = { white = 1, black = 2, red = 4, lime = 8, yellow = 16, blue = 32, cyan = 64, gray = 128, lightGray = 256 }
    local ok, err = pcall(function()
      local plain, color = fakeTerm(false), fakeTerm(true)
      local layout = ui.draw(plain, sample())
      eq(plain.colored, 0, "no color calls on a gray screen")
      for y = 1, 12 do eq(#plain.out[y], 40, "row " .. y) end
      truthy(layout.buttons and #layout.buttons > 0, "draw returns the layout")
      ui.draw(color, sample())
      truthy(color.colored > 0, "color calls on a color screen")
      for y = 1, 12 do eq(color.out[y], plain.out[y], "same text row " .. y) end
    end)
    colors = saved
    if not ok then error(err, 0) end
  end)
end
