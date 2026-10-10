--[[ <Claude>
  A speaker turtle that follows a player around and plays music.
    Pocket computer (wireless): `follow` = the beacon. The player carries it;
      it broadcasts its GPS position twice a second.
    Turtle (speaker + wireless/ender modem): `follow [song ...]` follows the
      first beacon it hears, hovering HEIGHT blocks above it, and plays the
      songs in a loop at full volume. Songs are DFPWM files or URLs (convert
      with https://music.madefor.cc or `ffmpeg -i in.mp3 -ac 1 -ar 48000 out.dfpwm`).
  Never digs: it flies up and over what is in the way (greedy, no
  pathfinding: an overhang or a low ceiling can leave it waiting). Needs GPS.
]]
local PROTOCOL = "follow"
local HEIGHT, NEAR, VOLUME = 2, 3, 3 -- blocks above the beacon, blocks away that count as there, 0-3

local net = require("bot.net")
if not net.open() then error("follow needs a wireless or ender modem", 0) end

if pocket then
  print("Beacon on: the turtle follows you. Ctrl+T stops it.")
  while true do
    local x, y, z = gps.locate(2)
    if x then rednet.broadcast({ x = math.floor(x), y = math.floor(y), z = math.floor(z) }, PROTOCOL) end
    sleep(0.5)
  end
end
if not turtle then error("run follow on a turtle (the follower) or a pocket computer (the beacon)", 0) end

local nav = require("bot.nav")
local songs = { ... }
local speaker = peripheral.find("speaker")
if #songs > 0 and not speaker then error("no speaker: equip one on the side without the modem", 0) end

nav.init() -- GPS position and heading
print("Waiting for a beacon: run follow on a pocket computer.")

local beacon, target -- id of the beacon followed and where to go

local function listen()
  while true do
    local id, p = rednet.receive(PROTOCOL)
    if (beacon == nil or id == beacon) and type(p) == "table"
      and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" then
      if not beacon then print(("Following #%d"):format(id)) end
      beacon, target = id, { x = p.x, y = p.y + HEIGHT, z = p.z }
    end
  end
end

-- <Claude> One block along axis (sign 1 or -1) if free. Never digs.
local function move(axis, sign)
  if axis == "y" then return (sign > 0 and turtle.up or turtle.down)() end
  return nav.face(axis == "x" and (sign > 0 and 1 or 3) or (sign > 0 and 2 or 0)) and turtle.forward()
end

-- <Claude> Each tick: one step on the axis with the biggest gap that is free.
-- None free: up, and no going down until a sideways step works (stops it
-- bobbing up and down in front of a wall).
local function chase()
  local axes, climbing, hungry = { "x", "z", "y" }, false, false
  while true do
    local x, y, z
    if target then x, y, z = gps.locate(1) end
    local d = x and { x = target.x - x, y = target.y - y, z = target.z - z }
    if not d or math.abs(d.x) + math.abs(d.y) + math.abs(d.z) <= NEAR then
      sleep(0.5)
    elseif nav.fuel() < 1 and nav.refuelAll() == 0 then
      if not hungry then print("Out of fuel: put coal in it.") end
      hungry = true
      sleep(2)
    else
      hungry = false
      table.sort(axes, function(a, b) return math.abs(d[a]) > math.abs(d[b]) end)
      local moved = false
      for _, axis in ipairs(axes) do
        if d[axis] ~= 0 and not (axis == "y" and d.y < 0 and climbing) and move(axis, d[axis] > 0 and 1 or -1) then
          moved, climbing = true, climbing and axis == "y"
          break
        end
      end
      if not moved then
        if turtle.up() then climbing = true else sleep(0.5) end
      end
    end
  end
end

local function play(src)
  local h, err
  if src:match("^https?://") then h, err = http.get({ url = src, binary = true })
  else h, err = fs.open(shell.resolve(src), "rb") end
  if not h then printError(src .. ": " .. tostring(err or "not found")) sleep(5) return end
  local decode = require("cc.audio.dfpwm").make_decoder()
  while true do
    local chunk = h.read(16 * 1024)
    if not chunk then break end
    local buffer = decode(chunk)
    while not speaker.playAudio(buffer, VOLUME) do os.pullEvent("speaker_audio_empty") end
  end
  h.close()
end

local function music()
  while #songs > 0 do
    for _, song in ipairs(songs) do play(song) end
  end
end

parallel.waitForAll(listen, chase, music)
