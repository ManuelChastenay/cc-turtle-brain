--[[ <Claude>
  Provider-agnostic tool-calling loop. Tools are injected, so the same loop
  drives a local turtle now and rednet-dispatched turtles later.
  tools = { name = { description = "...", parameters = <JSON schema table>,
                     handler = function(args) return resultTable end } }
]]
local client = require("llm.openrouter")
local config = require("llm.config")

local M = {}

local function toSchema(tools)
  local list = {}
  for name, t in pairs(tools) do
    list[#list + 1] = { type = "function", ["function"] = {
      name = name,
      description = t.description,
      parameters = t.parameters or { type = "object", properties = {} },
    } }
  end
  return list
end

-- <Claude> Handler errors are returned to the model instead of crashing the loop.
local function runTool(tools, call)
  local tool = tools[call["function"].name]
  if not tool then return { ok = false, error = "unknown tool" } end
  local args = textutils.unserialiseJSON(call["function"].arguments or "") or {}
  local ok, result = pcall(tool.handler, args)
  if not ok then return { ok = false, error = tostring(result) } end
  return result
end

-- <Claude> Returns finalText, stats  |  nil, errorString. onTool(name, result) is optional logging.
function M.run(goal, tools, systemPrompt, onTool)
  local messages = {
    { role = "system", content = systemPrompt },
    { role = "user",   content = goal },
  }
  local schema, stats = toSchema(tools), { turns = 0, tokensIn = 0, tokensOut = 0 }

  for turn = 1, config.maxTurns do
    local msg, usage = client.chat(messages, schema)
    if not msg then return nil, usage end
    stats.turns = turn
    if usage then
      stats.tokensIn  = stats.tokensIn  + (usage.prompt_tokens or 0)
      stats.tokensOut = stats.tokensOut + (usage.completion_tokens or 0)
    end

    messages[#messages + 1] = {
      role = "assistant",
      content = msg.content or textutils.json_null,
      tool_calls = msg.tool_calls,
    }
    if not msg.tool_calls or #msg.tool_calls == 0 then
      return msg.content or "", stats
    end

    for _, call in ipairs(msg.tool_calls) do
      local result = runTool(tools, call)
      if onTool then onTool(call["function"].name, result) end
      messages[#messages + 1] = {
        role = "tool", tool_call_id = call.id, content = textutils.serialiseJSON(result),
      }
    end
  end
  return nil, "max turns reached (" .. config.maxTurns .. ")"
end

return M
