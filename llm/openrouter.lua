--[[ <Claude>
  Minimal OpenRouter (OpenAI-compatible) chat client for CC: Tweaked.
  chat(messages, tools) -> message, usage   |   nil, errorString
  Note: http.post is blocking and consumes unrelated events (e.g. rednet)
  while waiting. Fine for a sequential brain; revisit for parallel fleets.
]]
local config = require("llm.config")

local M = {}

local function readKey()
  local f = fs.open(config.keyPath, "r")
  if not f then error("API key not found at " .. config.keyPath, 0) end
  local key = f.readAll():gsub("%s+", "")
  f.close()
  return key
end

-- <Claude> Returns code, decodedJson, rawBody (or nil, nil, error on network failure).
local function post(payload)
  local headers = {
    ["Authorization"] = "Bearer " .. readKey(),
    ["Content-Type"]  = "application/json",
    ["X-Title"]       = config.appTitle,
  }
  local handle, err, failHandle = http.post(config.endpoint, textutils.serialiseJSON(payload), headers)
  handle = handle or failHandle
  if not handle then return nil, nil, err end
  local code, body = handle.getResponseCode(), handle.readAll()
  handle.close()
  if config.debugPath then
    local f = fs.open(config.debugPath, "w")
    if f then f.write(body or "") f.close() end
  end
  return code, textutils.unserialiseJSON(body), body
end

function M.chat(messages, tools)
  local payload = { model = config.model, messages = messages }
  if tools and #tools > 0 then
    payload.tools = tools
    -- <Claude> By default OpenRouter may route to a provider that silently
    -- ignores `tools`; only accept providers that implement tool calling.
    payload.provider = { require_parameters = true }
  end

  for attempt = 1, config.maxRetries do
    local code, data, raw = post(payload)
    if code == 200 and data and data.choices then
      return data.choices[1].message, data.usage
    end
    local retryable = code == nil or code == 429 or code >= 500
    if not retryable or attempt == config.maxRetries then
      return nil, ("HTTP %s: %s"):format(tostring(code), tostring(raw))
    end
    sleep(2 ^ attempt)
  end
end

return M
