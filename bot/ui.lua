--[[ <Claude>
  Fleet dashboard drawing (monitor or terminal). Pure: it only turns a
  `view` snapshot into text, so it runs the same on a monitor, a window or a
  fake terminal in the tests.
    view = { title, llm = "idle"|"thinking", calls, tokensIn, tokensOut, goal,
             lowFuel,                                  -- fuel below this shows red
             turtles = { { id, label, state = "idle"|"busy"|"lost", pos = {x,y,z},
                           fuel, step, steps, text, silent } ... },  -- sorted by id
             log = { "line", ... } }                   -- oldest first
    layout = M.layout(view, w, h) -> { rows, buttons }
      rows: exactly h rows of chunks { text, fg, bg }, each row exactly w wide
      buttons: { { y, x1, x2, action } } with action { type = "stop", id } |
               { type = "stopAll" } | { type = "homeAll" }
    M.draw(term, view) draws it and returns the layout; M.hit(layout, x, y)
    answers a monitor_touch with the action under that cell (or nil).
]]
local M = {}

local STATE_COLOR = { busy = "yellow", idle = "lime", lost = "red" }

-- <Claude> Left-aligned text cut or padded to exactly n characters. Cuts end in ".."
-- (the CC font has no ellipsis).
local function pad(s, n)
  s = tostring(s)
  if n <= 0 then return "" end
  if #s > n then return n > 2 and s:sub(1, n - 2) .. ".." or s:sub(1, n) end
  return s .. (" "):rep(n - #s)
end

local function rpad(s, n)
  s = tostring(s)
  if #s > n then return s:sub(1, n) end
  return (" "):rep(n - #s) .. s
end

local function chunk(text, fg, bg) return { text = text, fg = fg or "white", bg = bg or "black" } end

local function tokens(n)
  n = n or 0
  if n >= 1000 then return ("%.1fk"):format(n / 1000) end
  return tostring(n)
end

local function posText(p)
  if type(p) ~= "table" then return "?" end
  return ("%s,%s,%s"):format(tostring(p.x), tostring(p.y), tostring(p.z))
end

-- <Claude> What the last column says: the step for a busy turtle, otherwise the
-- last outcome the registry kept, or how long it has been silent.
local function detail(t)
  if t.state == "lost" then return ("silent %ds"):format(math.floor(t.silent or 0)) end
  if t.state == "busy" then
    local n = t.step and t.steps and ("%d/%d "):format(t.step, t.steps) or ""
    return n .. (t.text or "")
  end
  return t.text or "-"
end

-- <Claude> Column widths for this screen width. id, state and fuel always show;
-- the stop button, name and position are added in that order while the step
-- column keeps enough room (8, 12 and 14 characters).
local function columns(w)
  local c = { id = 4, name = 0, state = 5, pos = 0, fuel = 5, stop = 0 }
  local left = w - 16
  if left - 6 >= 8 then c.stop, left = 6, left - 6 end
  if left - 10 >= 12 then c.name, left = 9, left - 10 end
  if left - 14 >= 14 then c.pos = 13 end
  return c
end

local function fixedWidth(c)
  local n = c.id + c.state + 1 + c.fuel + 1 + c.stop
  if c.name > 0 then n = n + c.name + 1 end
  if c.pos > 0 then n = n + c.pos + 1 end
  return n
end

local function turtleRow(t, c, w, y, buttons, lowFuel)
  local row = {}
  row[#row + 1] = chunk(pad("#" .. tostring(t.id), c.id))
  if c.name > 0 then row[#row + 1] = chunk(pad(t.label or "-", c.name + 1)) end
  row[#row + 1] = chunk(pad(t.state == "lost" and "LOST" or t.state == "busy" and "BUSY" or "idle", c.state + 1),
    STATE_COLOR[t.state] or "white")
  if c.pos > 0 then row[#row + 1] = chunk(pad(posText(t.pos), c.pos + 1), "lightGray") end
  local fuel = t.fuel
  row[#row + 1] = chunk(rpad(fuel == nil and "?" or fuel == "unlimited" and "inf" or tostring(fuel), c.fuel) .. " ",
    type(fuel) == "number" and fuel < lowFuel and "red" or "white")
  row[#row + 1] = chunk(pad(detail(t), w - fixedWidth(c)), t.state == "lost" and "red" or "white")
  if c.stop > 0 then
    local label = t.state == "busy" and "[stop]" or ""
    row[#row + 1] = chunk(pad(label, c.stop), "white", t.state == "busy" and "red" or "black")
    if label ~= "" then
      buttons[#buttons + 1] = { y = y, x1 = w - c.stop + 1, x2 = w, action = { type = "stop", id = t.id } }
    end
  end
  return row
end

-- <Claude> One full-width row from chunks: padded to w, cut if longer.
local function fill(row, w)
  local out, used = {}, 0
  for _, c in ipairs(row) do
    if used >= w then break end
    local text = c.text
    if used + #text > w then text = text:sub(1, w - used) end
    out[#out + 1] = chunk(text, c.fg, c.bg)
    used = used + #text
  end
  if used < w then out[#out + 1] = chunk((" "):rep(w - used)) end
  return out
end

function M.layout(view, w, h)
  local rows, buttons = {}, {}
  local turtles, log = view.turtles or {}, view.log or {}
  local c = columns(w)
  local lowFuel = view.lowFuel or 100

  -- <Claude> Header: the richest of these that fits the width (title only on wide screens).
  local title = view.title or "TURTLE BRAIN"
  local base = ("%d turtles  LLM %s"):format(#turtles, view.llm or "idle")
  local withCalls = base .. ("  %d calls"):format(view.calls or 0)
  local full = withCalls .. ("  %s/%s tok"):format(tokens(view.tokensIn), tokens(view.tokensOut))
  local header
  if #title + 2 + #full <= w then
    header = { chunk(title, "cyan"), chunk("  " .. full, "lightGray") }
  else
    for _, text in ipairs({ full, withCalls, base }) do
      if #text <= w then header = { chunk(text, "lightGray") } break end
    end
  end
  rows[#rows + 1] = fill(header or { chunk(base, "lightGray") }, w)

  local heads = { chunk(pad("id", c.id), "gray") }
  if c.name > 0 then heads[#heads + 1] = chunk(pad("name", c.name + 1), "gray") end
  heads[#heads + 1] = chunk(pad("state", c.state + 1), "gray")
  if c.pos > 0 then heads[#heads + 1] = chunk(pad("pos", c.pos + 1), "gray") end
  heads[#heads + 1] = chunk(rpad("fuel", c.fuel) .. " ", "gray")
  heads[#heads + 1] = chunk("step", "gray")
  rows[#rows + 1] = fill(heads, w)

  -- <Claude> Rows left after header, titles, separator and button bar. Turtles come
  -- first; the log gets what remains, but at least 3 lines when there is room.
  local goalRows = view.goal and 1 or 0
  local free = h - 4 - goalRows
  local logMin = free > 6 and 3 or 0
  local turtleRows = math.max(0, math.min(#turtles, free - logMin))
  local more = #turtles - turtleRows
  if more > 0 and turtleRows > 0 then turtleRows = turtleRows - 1 end
  more = #turtles - turtleRows
  for i = 1, turtleRows do
    rows[#rows + 1] = fill(turtleRow(turtles[i], c, w, #rows + 1, buttons, lowFuel), w)
  end
  if more > 0 and free > 0 then
    rows[#rows + 1] = fill({ chunk(("+%d more turtles"):format(more), "lightGray") }, w)
  end

  rows[#rows + 1] = fill({ chunk(("-"):rep(w), "gray") }, w)
  if view.goal then rows[#rows + 1] = fill({ chunk("goal: ", "gray"), chunk(view.goal, "white") }, w) end

  local logRows = h - 1 - #rows
  for i = math.max(1, #log - logRows + 1), #log do
    if logRows <= 0 then break end
    rows[#rows + 1] = fill({ chunk(log[i], "lightGray") }, w)
  end
  while #rows < h - 1 do rows[#rows + 1] = fill({}, w) end

  local y = #rows + 1
  local stopAll, homeAll = "[STOP ALL]", "[HOME ALL]"
  rows[#rows + 1] = fill({ chunk(stopAll, "white", "red"), chunk(" "), chunk(homeAll, "white", "blue") }, w)
  buttons[#buttons + 1] = { y = y, x1 = 1, x2 = #stopAll, action = { type = "stopAll" } }
  buttons[#buttons + 1] = { y = y, x1 = #stopAll + 2, x2 = #stopAll + 1 + #homeAll, action = { type = "homeAll" } }

  -- <Claude> Tiny screens: keep the bottom rows (the button bar) and move the buttons up with them.
  while #rows > h do
    table.remove(rows, 1)
    for i = #buttons, 1, -1 do
      buttons[i].y = buttons[i].y - 1
      if buttons[i].y < 1 then table.remove(buttons, i) end
    end
  end
  return { rows = rows, buttons = buttons }
end

function M.text(layout)
  local lines = {}
  for i, row in ipairs(layout.rows) do
    local parts = {}
    for _, c in ipairs(row) do parts[#parts + 1] = c.text end
    lines[i] = table.concat(parts)
  end
  return lines
end

function M.hit(layout, x, y)
  for _, b in ipairs(layout.buttons) do
    if b.y == y and x >= b.x1 and x <= b.x2 then return b.action end
  end
  return nil
end

-- <Claude> Draws on any term-like object (term, monitor, window). Every cell is
-- written, so nothing needs clearing first. Colors only where supported.
function M.draw(t, view)
  local w, h = t.getSize()
  local layout = M.layout(view, w, h)
  local color = colors and t.isColor and t.isColor()
  local fg, bg -- last colors set: peripheral calls are not free, so only change what changed
  for y, row in ipairs(layout.rows) do
    t.setCursorPos(1, y)
    for _, c in ipairs(row) do
      if color then
        if c.fg ~= fg then fg = c.fg t.setTextColor(colors[fg] or colors.white) end
        if c.bg ~= bg then bg = c.bg t.setBackgroundColor(colors[bg] or colors.black) end
      end
      t.write(c.text)
    end
  end
  return layout
end

return M
