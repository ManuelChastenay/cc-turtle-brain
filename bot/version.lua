--[[ <Claude>
  The installed version, as install.lua saves it in /.version:
  { n, sha, date, message } (date and message only when install looked the
  commit up). n counts the commits on main up to that one: higher is newer.
]]
local M = { PATH = "/.version" }

function M.read()
  local f = fs.open(M.PATH, "r")
  if not f then return nil end
  local v = textutils.unserialiseJSON(f.readAll())
  f.close()
  return type(v) == "table" and type(v.sha) == "string" and v or nil
end

-- <Claude> "v8 d2ffe09" (install.lua prints the same), or "version unknown":
-- installed before versions existed, or GitHub's API did not answer.
function M.text(v)
  if type(v) ~= "table" or type(v.sha) ~= "string" then return "version unknown" end
  return ("v%s %s"):format(tostring(v.n or "?"), v.sha:sub(1, 7))
end

return M
