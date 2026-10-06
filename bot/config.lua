--[[ <Claude>
  Turtle-side settings. The LLM never sees these. Item and block lists are
  plain substrings of registry names ("coal" also matches charcoal and
  coal_block), except junk, which uses exact names: a substring like
  "andesite" would also throw away Create's andesite_alloy.
]]

-- <Claude> Dropped on the ground, never stored ({} keeps everything); see bot/inv.lua.
local junk = {
  "minecraft:cobblestone", "minecraft:cobblestone_stairs", "minecraft:cobblestone_slab", "minecraft:cobblestone_wall",
  "minecraft:mossy_cobblestone", "minecraft:mossy_cobblestone_stairs", "minecraft:mossy_cobblestone_slab",
  "minecraft:mossy_cobblestone_wall",
  "minecraft:cobbled_deepslate", "minecraft:dirt", "minecraft:gravel",
  "minecraft:andesite", "minecraft:diorite", "minecraft:granite", "minecraft:tuff", "minecraft:netherrack",
  "minecraft:calcite", "minecraft:smooth_basalt", "minecraft:smooth_stone", "minecraft:smooth_stone_slab",
  "minecraft:terracotta",
  "minecraft:raw_copper",
  "xycraft_world:kivi",
}
-- <Claude> Terracotta in every dye color, plain and glazed.
for _, color in ipairs({ "white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray",
                         "cyan", "purple", "blue", "brown", "green", "red", "black" }) do
  junk[#junk + 1] = "minecraft:" .. color .. "_terracotta"
  junk[#junk + 1] = "minecraft:" .. color .. "_glazed_terracotta"
end

return {
  statePath  = "/nav_state.json", -- position, heading and home; survives reboots
  fuelItems  = { "coal", "coke", "lava_bucket", "blaze_rod", "dried_kelp_block" },
  fuelMargin = 20,                -- fuel kept on top of what a job needs
  -- <Claude> true: a dig refuses to start without the fuel for all of it.
  -- false: it starts with what it has (enough to reach the shape), digs
  -- until the fuel left only gets it back to its start, stops there with
  -- "fuel ran low", and `retry` carries on once it has fuel again.
  fuelForWholeDig = false,
  keepFuel   = 64,                -- fuel items kept when unloading (64 coal = 5120 fuel); none if fuel is unlimited
  junk       = junk,
  protect    = {                  -- never dug, even when in the way
    "computercraft:", "chest", "barrel", "shulker_box", "furnace", "_door", "glass", "_bed",
  },
  falling    = { "gravel", "sand", "concrete_powder" }, -- re-checked after digging
  turtleWaits = 20,               -- ~1 s retries when another turtle blocks the way
  turtleRetries = 10,             -- then mining and travel pause and try again this many times (~5 min in all)
  maxSteps   = 20,                -- longest plan accepted from the LLM
}
