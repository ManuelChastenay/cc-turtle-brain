--[[ <Claude>
  Shapes in world coordinates, for digging and building: a ball, a cylinder
  (a circle over a range of levels) or a box, optionally cut to a range of
  levels. Pure math, no turtle API, so the brain can load it too.
  Round shapes follow the 75-block circle chart the user works from: a block
  is in when its distance to the center is at most (d - 1) / 2, which gives
  one-block bumps at the ends of odd diameters. Computed in half blocks
  (doubled coordinates, all integers) so even diameters, centered between
  blocks, work too.
  s = { kind = "ball"|"cylinder"|"box", x1, x2, y1, y2, z1, z2 (bounds),
        cx, cy, cz, limit (round kinds: doubled center, doubled radius squared),
        top, bottom (optional cut: only levels bottom..top) }
]]
local M = {}

-- <Claude> floor(sqrt(n)) for an integer n >= 0, exact.
local function isqrt(n)
  local m = math.floor(math.sqrt(n))
  while m * m > n do m = m - 1 end
  while (m + 1) * (m + 1) <= n do m = m + 1 end
  return m
end

-- <Claude> Lowest block of a diameter d centered on block c (an even one reaches 1 further up).
local function low(c, d) return c - math.floor((d - 1) / 2) end

function M.ball(x, y, z, d)
  local s = { kind = "ball", x1 = low(x, d), y1 = low(y, d), z1 = low(z, d) }
  s.x2, s.y2, s.z2 = s.x1 + d - 1, s.y1 + d - 1, s.z1 + d - 1
  s.cx, s.cy, s.cz = s.x1 + s.x2, s.y1 + s.y2, s.z1 + s.z2
  s.limit = (d - 1) * (d - 1) + (d % 2 == 0 and 2 or 0) -- even: the 2x2 blocks at each pole are in
  return s
end

function M.cylinder(x, z, d, y1, y2)
  local s = { kind = "cylinder", x1 = low(x, d), z1 = low(z, d), y1 = math.min(y1, y2), y2 = math.max(y1, y2) }
  s.x2, s.z2 = s.x1 + d - 1, s.z1 + d - 1
  s.cx, s.cz = s.x1 + s.x2, s.z1 + s.z2
  s.limit = (d - 1) * (d - 1) + (d % 2 == 0 and 1 or 0)
  return s
end

function M.box(x1, y1, z1, x2, y2, z2)
  return { kind = "box", x1 = math.min(x1, x2), x2 = math.max(x1, x2), y1 = math.min(y1, y2),
           y2 = math.max(y1, y2), z1 = math.min(z1, z2), z2 = math.max(z1, z2) }
end

-- <Claude> Keeps only levels bottom..top (either may be nil). Returns s, or
-- nil when no level is left.
function M.cut(s, top, bottom)
  s.top, s.bottom = top, bottom
  if M.lowest(s) > M.highest(s) then return nil end
  return s
end

-- <Claude> Lowest and highest level with blocks, cut included.
function M.lowest(s) return math.max(s.y1, s.bottom or s.y1) end
function M.highest(s) return math.min(s.y2, s.top or s.y2) end

-- <Claude> uncut = true ignores the cut (bot/build.lua: a cut is open, not a lid).
local function level(s, y, uncut)
  if y < s.y1 or y > s.y2 then return false end
  if uncut then return true end
  return y >= M.lowest(s) and y <= M.highest(s)
end

function M.inside(s, x, y, z)
  if x < s.x1 or x > s.x2 or z < s.z1 or z > s.z2 or not level(s, y) then return false end
  if s.kind == "box" then return true end
  local u, w = 2 * x - s.cx, 2 * z - s.cz
  local q = u * u + w * w
  if s.kind == "ball" then
    local v = 2 * y - s.cy
    q = q + v * v
  end
  return q <= s.limit
end

-- <Claude> The run of blocks of level y along one horizontal axis: give x
-- for the z range (z nil), or z for the x range (x nil). Returns first,
-- last, or nil when empty. Round kinds are convex, so it is one run.
function M.line(s, y, x, z, uncut)
  if not level(s, y, uncut) then return nil end
  local fixed, lo1, hi1, c1, lo2, hi2, c2
  if z == nil then
    fixed, lo1, hi1, c1, lo2, hi2, c2 = x, s.x1, s.x2, s.cx, s.z1, s.z2, s.cz
  else
    fixed, lo1, hi1, c1, lo2, hi2, c2 = z, s.z1, s.z2, s.cz, s.x1, s.x2, s.cx
  end
  if fixed < lo1 or fixed > hi1 then return nil end
  if s.kind == "box" then return lo2, hi2 end
  local u = 2 * fixed - c1
  local rest = s.limit - u * u
  if s.kind == "ball" then
    local v = 2 * y - s.cy
    rest = rest - v * v
  end
  if rest < 0 then return nil end
  local m = isqrt(rest)
  local a, b = math.max(lo2, math.ceil((c2 - m) / 2)), math.min(hi2, math.floor((c2 + m) / 2))
  if a > b then return nil end
  return a, b
end

-- <Claude> The blocks of a line (as M.line) to build with fill: all of it
-- ("solid"); those with a side out of the shape ("hollow"), or with one of
-- the 4 horizontal sides out ("walls": open at the top and bottom). A cut is
-- open: its levels do not count as outside. Returns a list of { first, last }.
function M.ranges(s, fill, y, x, z)
  local lo, hi = M.line(s, y, x, z)
  if not lo then return {} end
  if fill == "solid" then return { { lo, hi } } end
  local clo, chi, none = lo + 1, hi - 1, false -- the core: blocks with every counted side in
  local function keep(a, b)
    if not a then none = true return end
    clo, chi = math.max(clo, a), math.min(chi, b)
  end
  if z == nil then
    keep(M.line(s, y, x - 1, nil)) keep(M.line(s, y, x + 1, nil))
  else
    keep(M.line(s, y, nil, z - 1)) keep(M.line(s, y, nil, z + 1))
  end
  if fill == "hollow" then
    keep(M.line(s, y - 1, x, z, true)) keep(M.line(s, y + 1, x, z, true))
  end
  if none or clo > chi then return { { lo, hi } } end
  local out = {}
  if clo > lo then out[#out + 1] = { lo, clo - 1 } end
  if chi < hi then out[#out + 1] = { chi + 1, hi } end
  return out
end

-- <Claude> Blocks per column along axis ("x" or "z"), lowest first, counting
-- only the other axis between from and to (nil = all): for even shares.
function M.counts(s, fill, axis, from, to)
  local counts = {}
  local c1, c2 = s[axis .. "1"], s[axis .. "2"]
  for c = c1, c2 do
    local n = 0
    for y = M.lowest(s), M.highest(s) do
      local list = axis == "x" and M.ranges(s, fill, y, c, nil) or M.ranges(s, fill, y, nil, c)
      for _, r in ipairs(list) do
        local a, b = math.max(r[1], from or r[1]), math.min(r[2], to or r[2])
        if b >= a then n = n + b - a + 1 end
      end
    end
    counts[c - c1 + 1] = n
  end
  return counts
end

-- <Claude> The axes of build tiles (bot/build.lua): u = the longer
-- horizontal side (shares are runs of its columns), v = the other one (cut
-- in halves for hollow and walls). The brain's split uses the same.
function M.axes(s)
  if s.x2 - s.x1 >= s.z2 - s.z1 then return "x", "z" end
  return "z", "x"
end

-- <Claude> How many of parts shares go to the low half of v (the rest to the high half).
function M.lowHalf(parts) return math.ceil(parts / 2) end

-- <Claude> Share `part` of `parts` of a row of columns with these block
-- counts: a run of columns with about 1/parts of the blocks (short columns
-- make wider shares). Returns the first and last column (offsets from 0),
-- or nil when there are more parts than columns and this one gets none.
-- Every turtle computes the same split, so each column goes to one share.
function M.share(counts, part, parts)
  local n = #counts
  parts = math.min(parts, n)
  if part > parts then return nil end
  local total = 0
  for i = 1, n do total = total + counts[i] end
  local from, sum = 1, 0
  for k = 1, parts do
    local to = from
    sum = sum + counts[to]
    if k == parts then to = n end
    while to < n - (parts - k) and sum + counts[to + 1] / 2 <= total * k / parts do
      to = to + 1
      sum = sum + counts[to]
    end
    if k == part then return from - 1, to - 1 end
    from = to + 1
  end
end

return M
