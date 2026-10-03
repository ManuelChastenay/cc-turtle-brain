--[[ <Claude>
  Installs/updates the brain files from GitHub. Usage: install
  Public repo: works as-is (raw.githubusercontent.com).
  Private repo: put a read-only fine-grained token in /.github_token;
  files are then fetched through the GitHub API (also avoids raw caching).
  Secrets (/.openrouter_key, /.github_token) are never part of the repo.
]]
local OWNER, REPO, BRANCH = "ManuelChastenay", "cc-turtle-brain", "main"
local TOKEN_PATH = "/.github_token"
local FILES = {
  "brain.lua", "fleet.lua", "worker.lua", -- install.lua updates itself first, see below
  "llm/config.lua", "llm/openrouter.lua", "llm/agent.lua",
  "bot/config.lua", "bot/nav.lua", "bot/inv.lua", "bot/mine.lua", "bot/skills.lua", "bot/plan.lua",
  "bot/net.lua", "bot/fleet.lua", "bot/job.lua",
}

local function readToken()
  if not fs.exists(TOKEN_PATH) then return nil end
  local f = fs.open(TOKEN_PATH, "r")
  local token = f.readAll():gsub("%s+", "")
  f.close()
  return token
end

local token = readToken()

local function fetch(path)
  if token then
    local url = ("https://api.github.com/repos/%s/%s/contents/%s?ref=%s"):format(OWNER, REPO, path, BRANCH)
    return http.get(url, {
      ["Authorization"] = "Bearer " .. token,
      ["Accept"]        = "application/vnd.github.raw",
      ["User-Agent"]    = "cc-installer",
    })
  end
  return http.get(("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(OWNER, REPO, BRANCH, path))
end

print(token and "Mode: private (GitHub API)" or "Mode: public (raw)")

-- <Claude> Update this installer first and hand over to the new copy, so
-- files added to FILES arrive in the same run. The flag stops a loop.
if ... ~= "--updated" then
  local res, err = fetch("install.lua")
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
    shell.run("/install.lua", "--updated")
    return
  end
end

for _, path in ipairs(FILES) do
  local res, err = fetch(path)
  if not res then error(path .. ": " .. tostring(err), 0) end
  local f = fs.open("/" .. path, "w")   -- creates parent folders if needed
  f.write(res.readAll())
  f.close(); res.close()
  print("ok  " .. path)
end
print("Done.")
