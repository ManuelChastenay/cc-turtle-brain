--[[ <Claude>
  Turtle-side settings. The LLM never sees these. Item and block lists are
  plain substrings of registry names ("coal" also matches charcoal and
  coal_block), except junk, which uses exact names: a substring like
  "andesite" would also throw away Create's andesite_alloy.
]]
return {
  statePath  = "/nav_state.json", -- position, heading and home; survives reboots
  fuelItems  = { "coal", "coke", "lava_bucket", "blaze_rod", "dried_kelp_block" },
  fuelMargin = 20,                -- fuel kept on top of what a job needs
  keepFuel   = 64,                -- fuel items kept when unloading (64 coal = 5120 fuel); none if fuel is unlimited
  junk       = {                  -- dropped on the ground, never stored ({} keeps everything); see bot/inv.lua
    "minecraft:cobblestone", "minecraft:cobblestone_stairs", "minecraft:cobblestone_slab", "minecraft:cobblestone_wall",
    "minecraft:mossy_cobblestone", "minecraft:mossy_cobblestone_stairs", "minecraft:mossy_cobblestone_slab",
    "minecraft:mossy_cobblestone_wall",
    "minecraft:cobbled_deepslate", "minecraft:dirt", "minecraft:gravel",
    "minecraft:andesite", "minecraft:diorite", "minecraft:granite", "minecraft:tuff", "minecraft:netherrack",
    "minecraft:raw_copper",
  },
  protect    = {                  -- never dug, even when in the way
    "computercraft:", "chest", "barrel", "shulker_box", "furnace", "_door", "glass", "_bed",
  },
  falling    = { "gravel", "sand", "concrete_powder" }, -- re-checked after digging
  turtleWaits = 20,               -- ~1 s retries when another turtle blocks the way
  maxSteps   = 20,                -- longest plan accepted from the LLM
}
