--[[ <Claude>
  Provider-agnostic tool-calling loop. Tools are injected, so the same loop
  drives a local turtle now and rednet-dispatched turtles later.
  tools = { name = { description = "...", parameters = <JSON schema table>,
                     handler = function(args) return resultTable end,
                     final = true } }  -- optional, see below
  Calls in one turn run in order; after a failed call the rest are skipped.
  A successful call to a `final` tool ends the run right away (its
  result.summary is the reply), saving the LLM round trip that would only
  say "done".
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

-- <Claude> Handler errors are returned to the model instead of crashing the
-- loop, except Ctrl+T, which must still stop the program.
local function runTool(tools, call)
  local tool = tools[call["function"].name]
  if not tool then return { ok = false, error = "unknown tool" } end
  local args = textutils.unserialiseJSON(call["function"].arguments or "") or {}
  local ok, result = pcall(tool.handler, args)
  if not ok then
    if result == "Terminated" then error(result, 0) end
    return { ok = false, error = tostring(result) }
  end
  if type(result) ~= "table" then return { ok = false, error = "tool returned no result" } end
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
      -- <Claude> Reasoning models need their reasoning sent back between tool calls.
      reasoning_details = msg.reasoning_details,
    }
    if not msg.tool_calls or #msg.tool_calls == 0 then
      if (msg.content or "") == "" then
        return nil, "empty reply (no text, no tool call); raw response in " .. tostring(config.debugPath)
      end
      return msg.content, stats
    end

    -- <Claude> Every call still gets a tool message, as the API requires.
    local failed, final = false, nil
    for _, call in ipairs(msg.tool_calls) do
      local name = call["function"].name
      local result = failed and { ok = false, error = "skipped: an earlier call failed" } or runTool(tools, call)
      if onTool then onTool(name, result) end
      messages[#messages + 1] = {
        role = "tool", tool_call_id = call.id, content = textutils.serialiseJSON(result),
      }
      if result.ok == false then
        failed = true
      elseif tools[name] and tools[name].final then
        final = result
      end
    end
    if final and not failed then
      return final.summary or textutils.serialiseJSON(final), stats
    end
  end
  return nil, "max turns reached (" .. config.maxTurns .. ")"
end

return M
