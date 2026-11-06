-- Hotkey for the AI panel (scripts/gui.lua). Rebindable in Settings > Controls.
data:extend({
  {
    type = "custom-input",
    name = "ai-player-toggle-panel",
    key_sequence = "CONTROL + SHIFT + A",
    consuming = "none",
  },
})

-- AI Monitoring Station: An enterable, armored observation bunker
if data.raw["car"] and data.raw["car"]["car"] then
  local station = table.deepcopy(data.raw["car"]["car"])
  station.type = "car"
  station.name = "ai-monitoring-station"
  station.icon = "__base__/graphics/icons/car.png"
  station.minable = {mining_time = 0.5, result = "ai-monitoring-station"}
  station.max_health = 3000
  station.weight = 50000
  station.friction_force = 1.0
  station.braking_power = "2000kW"
  station.consumption = "0kW"
  station.energy_source = {
    type = "void"
  }
  station.inventory_size = 20
  station.guns = nil
  station.turret_animation = nil
  station.turret_rotation_speed = 0
  station.is_military_target = false

  local base_item = (data.raw["item-with-entity-data"] and data.raw["item-with-entity-data"]["car"])
                    or (data.raw["item"] and data.raw["item"]["car"])
  local item = table.deepcopy(base_item)
  item.name = "ai-monitoring-station"
  item.place_result = "ai-monitoring-station"
  item.icon = "__base__/graphics/icons/car.png"
  item.order = "b[personal-transport]-d[ai-monitoring-station]"
  item.stack_size = 5

  local recipe = {
    type = "recipe",
    name = "ai-monitoring-station",
    enabled = true,
    energy_required = 3,
    ingredients = {
      {type = "item", name = "iron-plate", amount = 10},
      {type = "item", name = "electronic-circuit", amount = 5},
      {type = "item", name = "stone-brick", amount = 10},
      {type = "item", name = "radar", amount = 1},
    },
    results = {
      {type = "item", name = "ai-monitoring-station", amount = 1}
    }
  }

  data:extend({station, item, recipe})
end
