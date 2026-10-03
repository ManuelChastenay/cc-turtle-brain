--[[ <Claude>
  Turtle-side settings. The LLM never sees these. Item and block lists are
  plain substrings of registry names ("coal" also matches charcoal and
  coal_block).
]]
return {
  statePath  = "/nav_state.json", -- position, heading and home; survives reboots
  fuelItems  = { "coal", "coke", "lava_bucket", "blaze_rod" },
  fuelMargin = 20,                -- fuel kept on top of what a job needs
  protect    = {                  -- never dug, even when in the way
    "computercraft:", "chest", "barrel", "shulker_box", "furnace", "_door", "glass", "_bed",
  },
  falling    = { "gravel", "sand", "concrete_powder" }, -- re-checked after digging
  maxSteps   = 20,                -- longest plan accepted from the LLM
}
