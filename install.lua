--[[ <Claude>
  Installs/updates the brain files from GitHub.
    install            the newest commit on main
    install force      the same, downloaded again even if already installed
    install <sha> [n]  that commit (`fleet update` sends the turtles the computer's)
  The version is printed and saved in /.version: { n, sha, date, message }
  (date and message only when the commit was looked up). n counts the
  commits on main up to that one, so a higher n is newer: "v8 d2ffe09".
  Every file comes from that one commit: a push in the middle of an update
  cannot mix old and new files, and raw.githubusercontent.com's ~5 minute
  cache of the branch does not matter.
  Looking up the newest commit is one GitHub API call (60 an hour per
  server IP without a token). If it fails, files come from the branch and
  the version is unknown.
  Public repo: works as-is. Private repo: put a read-only fine-grained token
  in /.github_token; files then come through the GitHub API.
  Secrets (/.openrouter_key, /.github_token) are never part of the repo.
]]
local OWNER, REPO, BRANCH = "ManuelChastenay", "cc-turtle-brain", "main"
local TOKEN_PATH, VERSION_PATH = "/.github_token", "/.version"
local FILES = {
  "brain.lua", "fleet.lua", "worker.lua", -- install.lua updates itself first, see below
  "llm/config.lua", "llm/openrouter.lua", "llm/agent.lua",
  "bot/config.lua", "bot/nav.lua", "bot/inv.lua", "bot/mine.lua", "bot/skills.lua", "bot/plan.lua",
  "bot/net.lua", "bot/fleet.lua", "bot/job.lua", "bot/ui.lua", "bot/registry.lua", "bot/dash.lua",
  "bot/version.lua",
}

-- <Claude> --updated: this is the new copy, started by the old one (stops a loop).
local args = { ... }
local updated = args[1] == "--updated"
if updated then table.remove(args, 1) end
local force, pin, pinN = false, nil, nil
for _, a in ipairs(args) do
  if a == "force" then force = true
  elseif #a >= 7 and a:match("^%x+$") then pin = a:lower()
  elseif tonumber(a) then pinN = tonumber(a)
  else error("usage: install [force]   or   install <commit sha> [n]", 0) end
end

local function readJSON(path)
  local f = fs.open(path, "r")
  if not f then return nil end
  local data = textutils.unserialiseJSON(f.readAll())
  f.close()
  return type(data) == "table" and data or nil
end

local function readToken()
  if not fs.exists(TOKEN_PATH) then return nil end
  local f = fs.open(TOKEN_PATH, "r")
  local token = f.readAll():gsub("%s+", "")
  f.close()
  return token
end

local token = readToken()

-- <Claude> path at ref (a commit sha, or the branch when the version is unknown).
local function fetch(path, ref)
  if token then
    local url = ("https://api.github.com/repos/%s/%s/contents/%s?ref=%s"):format(OWNER, REPO, path, ref)
    return http.get(url, {
      ["Authorization"] = "Bearer " .. token,
      ["Accept"]        = "application/vnd.github.raw",
      ["User-Agent"]    = "cc-installer",
    })
  end
  return http.get(("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(OWNER, REPO, ref, path))
end

-- <Claude> The newest commit on the branch: { n, sha, date, message }, or nil.
-- With one commit per page, the last page in the Link header is the number
-- of commits (no Link header: there is only one).
local function newest()
  local headers = { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = "cc-installer" }
  if token then headers["Authorization"] = "Bearer " .. token end
  local res = http.get(("https://api.github.com/repos/%s/%s/commits?sha=%s&per_page=1"):format(OWNER, REPO, BRANCH), headers)
  if not res then return nil end
  local list = textutils.unserialiseJSON(res.readAll())
  local n = 1
  for name, value in pairs(res.getResponseHeaders()) do
    if name:lower() == "link" then n = tonumber(value:match('page=(%d+)>; rel="last"')) or n end
  end
  res.close()
  local c = type(list) == "table" and list[1]
  if type(c) ~= "table" or type(c.sha) ~= "string" then return nil end
  local commit = type(c.commit) == "table" and c.commit or {}
  local date = type(commit.committer) == "table" and type(commit.committer.date) == "string" and commit.committer.date or nil
  return { n = n, sha = c.sha, date = date and date:gsub("T", " "):sub(1, 16) .. " UTC",
           message = type(commit.message) == "string" and commit.message:match("^[^\n]*") or nil }
end

-- <Claude> Same format as bot/version.lua: "v8 d2ffe09".
local function text(v)
  if not v then return "version unknown" end
  return ("v%s %s"):format(tostring(v.n or "?"), v.sha:sub(1, 7))
end

print(token and "Mode: private (GitHub API)" or "Mode: public (raw)")

local target = pin and { n = pinN, sha = pin } or newest()
if target then
  print(("Version %s%s"):format(text(target), target.date and (" (" .. target.date:sub(1, 10) .. ")") or ""))
  if target.message and target.message ~= "" then print("  " .. target.message) end
else
  print("GitHub's API did not answer (offline, or 60 calls an hour used up):")
  print("installing the latest files of " .. BRANCH .. ", version unknown")
end
local ref = target and target.sha or BRANCH

local installed = readJSON(VERSION_PATH)
if installed and type(installed.sha) ~= "string" then installed = nil end
if target and installed and installed.sha:sub(1, #target.sha) == target.sha and not force then
  print(("Already up to date (%s). `install force` downloads it again."):format(text(installed)))
  return
end

-- <Claude> Update this installer first and hand over to the new copy, so
-- files added to FILES arrive in the same run. It gets the same arguments
-- (a pinned commit stays pinned; otherwise it looks the newest one up again).
if not updated then
  local res, err = fetch("install.lua", ref)
  if not res then error("install.lua: " .. tostring(err), 0) end
  local latest = res.readAll()
  res.close()
  local f = fs.open("/install.lua", "r")
  local current = f and f.readAll()
  if f then f.close() end
  if latest ~= current then
    f = fs.open("/install.lua", "w")
    f.write(latest)
    f.close()
    print("Installer updated, restarting it")
    -- <Claude> Fail too if the new copy failed (worker.lua's update checks it).
    -- An empty message: the new copy already printed why.
    if not shell.run("/install.lua", "--updated", table.unpack(args)) then error("", 0) end
    return
  end
end

for _, path in ipairs(FILES) do
  local res, err = fetch(path, ref)
  if not res then error(path .. ": " .. tostring(err), 0) end
  local f = fs.open("/" .. path, "w")   -- creates parent folders if needed
  f.write(res.readAll())
  f.close(); res.close()
  print("ok  " .. path)
end

-- <Claude> Saved only once every file is in: a cut-off install is not "up to date".
if target then
  local f = fs.open(VERSION_PATH, "w")
  f.write(textutils.serialiseJSON(target))
  f.close()
else
  fs.delete(VERSION_PATH)
end
print(("Done: %s installed%s."):format(text(target), installed and (" (was " .. text(installed) .. ")") or ""))
