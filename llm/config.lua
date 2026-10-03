--[[ <Claude>
  LLM connection settings. The API key is never stored here: it is read
  from keyPath, so this file can be shared or versioned safely.
  Verify model slugs on https://openrouter.ai/models before use.
]]
return {
  endpoint   = "https://openrouter.ai/api/v1/chat/completions",
  model      = "deepseek/deepseek-v4-flash", -- or "anthropic/claude-haiku-4.5"
  keyPath    = "/.openrouter_key",
  maxTurns   = 4,                          -- LLM calls per goal: 1 plan + replans after failures
  maxRetries = 3,                          -- for 429 / 5xx / timeouts
  appTitle   = "CC Turtle Brain",          -- shown in your OpenRouter dashboard
  debugPath  = "/llm_last.json",           -- raw body of the last response (nil to disable)
}
