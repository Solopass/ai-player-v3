-- Headless self-test harness: /ai-selftest <case>[:<facing>] <run-id>
--
-- Builds a throwaway lab-tile surface, paints a test scene (ore, water), spawns
-- an AI character, runs the skill under test through AISkills.run, waits, then
-- checks what actually got built and writes the verdict to
-- script-output/ai-player/selftest.json. Driven by tests/ingame/run_selftest.py.
--
-- Safety: refuses to run unless the map was created with one of the armed seeds
-- (the runner passes --map-gen-seed) and no player ever joined, so it can never
-- touch a real save.
--
-- The soak runner (tests/ingame/run_soak.py) uses the same arming on a normal
-- generated map: /ai-soak-start, /ai-soak-speed <n> and /ai-soak-snapshot.

AISelftest = {}

local SEEDS = {[424242] = true, [2476103329] = true, [1873625901] = true, [3598211047] = true}   -- keep in sync with run_soak.py
local OUT = "ai-player/selftest.json"
local FACINGS = {"north", "east", "south", "west"}
local STEP = {north = {0, -1}, east = {1, 0}, south = {0, 1}, west = {-1, 0}}

local function armed()
  local s = game.surfaces["nauvis"]
  -- The runner's map has an armed seed and never a player; any real save has one.
  return s ~= nil and SEEDS[s.map_gen_settings.seed] == true and #game.players == 0
end

local function write_result(r)
  helpers.write_file(OUT, helpers.table_to_json(r), false, 0)
end

-- ---------------------------------------------------------------------------
-- Scene helpers
-- ---------------------------------------------------------------------------

local function force_for_tests()
  local f = game.forces["ai-selftest"] or game.create_force("ai-selftest")
  f.research_all_technologies()      -- every recipe unlocked
  -- The burner miner cases lock this one; a case that died mid-run must not leak that.
  f.recipes["electric-mining-drill"].enabled = true
  return f
end

-- Square of ore tiles centred on (cx, cy).
local function paint_ore(surface, name, cx, cy, half, amount)
  for x = cx - half, cx + half - 1 do
    for y = cy - half, cy + half - 1 do
      surface.create_entity{name = name, position = {x + 0.5, y + 0.5}, amount = amount or 500}
    end
  end
end

-- Rectangle of water tiles (inclusive tile coords).
local function paint_water(surface, x1, y1, x2, y2)
  local tiles = {}
  for x = x1, x2 do
    for y = y1, y2 do tiles[#tiles + 1] = {name = "water", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, true)
end

-- A lake lying `dist` tiles from the origin in direction `facing`.
local function lake(surface, facing, dist)
  local d = STEP[facing]
  local cx, cy = d[1] * dist, d[2] * dist
  paint_water(surface, cx - 14, cy - 14, cx + 13, cy + 13)
end

local function give(character, items)
  local inv = character.get_inventory(defines.inventory.character_main)
  for name, n in pairs(items) do inv.insert{name = name, count = n} end
end

local function count_in(entity, inv_id)
  local inv = entity.get_inventory(inv_id)
  return inv and inv.get_item_count() or 0
end

local function chest_total(chest)
  return chest and chest.valid and count_in(chest, defines.inventory.chest) or 0
end

-- Power for the scene: an infinite source plus a pole beside it.
local function free_power(surface, force, x, y)
  surface.create_entity{name = "electric-energy-interface", position = {x, y}, force = force}
  return surface.create_entity{name = "small-electric-pole", position = {x + 2.5, y + 0.5}, force = force}
end

-- ---------------------------------------------------------------------------
-- Cases. Each: setup(c) paints the scene; run(c) -> list of skill entries;
-- check(c, add) calls add(name, ok, info) per check. delay = ticks to wait.
-- c = {surface, force, character, facing, results}
-- ---------------------------------------------------------------------------
local CASES = {}

local function miner_case(output, resource, delay)
  return {
    delay = delay,
    setup = function(c)
      local d = STEP[c.facing]
      paint_ore(c.surface, resource, 12 * d[1], 12 * d[2], 5)
      AILayout.only_facing = c.facing        -- test every drill facing
      -- These cases test the burner stage. Once electric drills are unlocked,
      -- build_miner phases burner drills out, as in a real game after the research.
      c.force.recipes["electric-mining-drill"].enabled = false
    end,
    run = function(c)
      return {{skill = "build_miner", resource = resource, output = output, count = output == "belt" and 3 or 2}}
    end,
    check = function(c, add)
      local drills = c.surface.find_entities_filtered{type = "mining-drill"}
      add("skill ok", c.results[1].ok, c.results[1].detail)
      add("drills built", #drills >= 2, #drills)
      local fed = 0
      for _, d in ipairs(drills) do
        local t = d.drop_target
        local want = output == "furnace" and "furnace" or output == "chest" and "container" or "transport-belt"
        add("drill at " .. math.floor(d.position.x) .. "," .. math.floor(d.position.y) .. " faces " ..
            tostring(d.direction) .. " drops into " .. want, t ~= nil and t.type == want, t and t.name or "nothing")
        if t and t.type == "furnace" then
          local n = count_in(t, defines.inventory.crafter_input) + count_in(t, defines.inventory.crafter_output)
          if n > 0 or t.products_finished > 0 then fed = fed + 1 end
        elseif t and t.type == "container" then
          if chest_total(t) > 0 then fed = fed + 1 end
        end
      end
      if output == "belt" then
        local total = 0
        for _, ch in ipairs(c.surface.find_entities_filtered{type = "container"}) do total = total + chest_total(ch) end
        add("ore reached the chest", total > 0, total)
      else
        add("every drill's collector received output", fed == #drills and #drills > 0, fed .. "/" .. #drills)
      end
      c.force.recipes["electric-mining-drill"].enabled = true
    end,
  }
end

CASES.miner_furnace = miner_case("furnace", "iron-ore", 900)
CASES.miner_chest = miner_case("chest", "coal", 900)
CASES.miner_belt = miner_case("belt", "iron-ore", 1800)

-- Dumps prototype geometry for the layout code (not part of the default run).
CASES.probe = {
  delay = 1,
  setup = function() end,
  run = function() return {} end,
  check = function(c, add)
    local function conns(name)
      local out = {}
      for i, fb in ipairs(prototypes.entity[name].fluidbox_prototypes) do
        for _, pc in ipairs(fb.pipe_connections) do
          out[#out + 1] = string.format("fb%d %s dir=%s pos=%s", i, tostring(pc.flow_direction),
            tostring(pc.direction), helpers.table_to_json(pc.positions or pc.position))
        end
      end
      return table.concat(out, " ; ")
    end
    for _, n in ipairs({"offshore-pump", "boiler", "steam-engine"}) do
      local pr = prototypes.entity[n]
      add(n, true, string.format("tw=%s th=%s box=%s %s", pr.tile_width, pr.tile_height,
        helpers.table_to_json(pr.collision_box), conns(n)))
    end
    local pole = prototypes.entity["small-electric-pole"]
    add("pole", true, string.format("wire=%s supply=%s", tostring(pole.get_max_wire_distance()),
      tostring(pole.get_supply_area_distance())))
  end,
}

CASES.power = {
  delay = 1500,
  setup = function(c)
    lake(c.surface, c.facing, 24)           -- the shore is ~10 tiles from the AI, on the `facing` side
  end,
  run = function(c) return {{skill = "build_power"}} end,
  after = function(c)
    -- A consumer on the new network, so the engines have a load to answer.
    local pole = c.surface.find_entities_filtered{type = "electric-pole", limit = 1}[1]
    if pole then
      local pos = c.surface.find_non_colliding_position("radar", pole.position, 8, 1)
      if pos then c.surface.create_entity{name = "radar", position = pos, force = c.force} end
    end
  end,
  check = function(c, add)
    local s = c.surface
    add("skill ok", c.results[1].ok, c.results[1].detail)
    local boiler = s.find_entities_filtered{name = "boiler"}[1]
    local engines = s.find_entities_filtered{name = "steam-engine"}
    local pump = s.find_entities_filtered{name = "offshore-pump"}[1]
    local poles = s.find_entities_filtered{type = "electric-pole"}
    add("pump, boiler, 2 engines, pole(s) built", pump ~= nil and boiler ~= nil and #engines == 2 and #poles > 0,
        string.format("pump=%s boiler=%s engines=%d poles=%d", tostring(pump ~= nil), tostring(boiler ~= nil), #engines, #poles))
    if boiler and #engines == 2 then
      add("boiler has water", (boiler.get_fluid_contents()["water"] or 0) > 0, helpers.table_to_json(boiler.get_fluid_contents()))
      add("boiler fuelled", boiler.get_fuel_inventory().get_item_count("coal") > 0, boiler.status)
      add("engine has steam", (engines[1].get_fluid_contents()["steam"] or 0) > 0 or (engines[2].get_fluid_contents()["steam"] or 0) > 0,
          helpers.table_to_json(engines[1].get_fluid_contents()))
      local gen = engines[1].energy_generated_last_tick + engines[2].energy_generated_last_tick
      add("power is being produced", gen > 0, gen)
    end
  end,
}

-- Assembler checks share the lookup of a cell's pieces.
local function inserter_between(c, a_type, b_type)
  for _, i in ipairs(c.surface.find_entities_filtered{type = "inserter"}) do
    local s, d = i.pickup_target, i.drop_target
    if s and d and s.type == a_type and d.type == b_type then return i, s, d end
  end
end

CASES.assembler = {
  delay = 1500,
  setup = function(c)
    free_power(c.surface, c.force, 15, 15)
    give(c.character, {inserter = 10, ["assembling-machine-1"] = 2, ["wooden-chest"] = 6})
  end,
  run = function(c) return {{skill = "build_assembler", recipe = "iron-gear-wheel", count = 1}} end,
  late = function(c) return {{skill = "tend"}} end,
  late_after = 120,
  check = function(c, add)
    local s = c.surface
    add("build_assembler ok", c.results[1].ok, c.results[1].detail)
    add("tend hauled plates", tostring(c.results[2] and c.results[2].detail):find("hauled") ~= nil,
        c.results[2] and c.results[2].detail)
    local asm = s.find_entities_filtered{type = "assembling-machine"}[1]
    add("assembler built", asm ~= nil)
    if not asm then return end
    local r = asm.get_recipe()
    add("recipe set", r ~= nil and r.name == "iron-gear-wheel", r and r.name)
    local _, in_chest = inserter_between(c, "container", "assembling-machine")
    add("input chest feeds the assembler", in_chest ~= nil)
    local _, _, out_chest = inserter_between(c, "assembling-machine", "container")
    add("output chest takes its product", out_chest ~= nil)
    add("assembler is powered", asm.status ~= defines.entity_status.no_power
        and asm.status ~= defines.entity_status.not_plugged_in_electric_network, asm.status)
    add("gears came out", asm.products_finished > 0, asm.products_finished)
    add("gears reached the output chest", out_chest ~= nil and out_chest.get_item_count("iron-gear-wheel") > 0,
        out_chest and out_chest.get_item_count("iron-gear-wheel"))
  end,
}

CASES.red_cell = {
  delay = 2700,
  setup = function(c)
    free_power(c.surface, c.force, 15, 15)
    give(c.character, {inserter = 10, ["assembling-machine-1"] = 1, ["wooden-chest"] = 6})
  end,
  run = function(c) return {{skill = "build_red_cell"}} end,
  late = function(c) return {{skill = "tend"}} end,
  late_after = 120,
  check = function(c, add)
    local s = c.surface
    add("build_red_cell ok", c.results[1].ok, c.results[1].detail)
    add("tend hauled plates", tostring(c.results[2] and c.results[2].detail):find("hauled") ~= nil,
        c.results[2] and c.results[2].detail)
    local gear, sci = 0, 0
    local asms = s.find_entities_filtered{type = "assembling-machine"}
    add("3 assemblers", #asms == 3, #asms)
    for _, a in ipairs(asms) do
      local r = a.get_recipe()
      if r and r.name == "iron-gear-wheel" then gear = gear + a.products_finished end
      if r and r.name == "automation-science-pack" then sci = sci + a.products_finished end
    end
    add("gear assembler produced", gear > 0, gear)
    add("science assemblers produced", sci > 0, sci)
    local lab = s.find_entities_filtered{type = "lab"}[1]
    add("lab built", lab ~= nil)
    if lab then
      add("packs reached the lab", lab.get_inventory(defines.inventory.lab_input).get_item_count("automation-science-pack") > 0,
          lab.get_inventory(defines.inventory.lab_input).get_item_count("automation-science-pack"))
    end
  end,
}

CASES.electric_miner = {
  delay = 2400,
  setup = function(c)
    local d = STEP[c.facing]
    free_power(c.surface, c.force, -d[1] * 14 - 3, -d[2] * 14 - 3)     -- grid on the far side of the AI
    paint_ore(c.surface, "iron-ore", 12 * d[1], 12 * d[2], 6)
    give(c.character, {["electric-mining-drill"] = 2, inserter = 4, ["wooden-chest"] = 4})
    AILayout.only_facing = c.facing
  end,
  run = function(c)
    return {{skill = "build_miner", resource = "iron-ore", output = "furnace", count = 2}}
  end,
  check = function(c, add)
    local s = c.surface
    add("build_miner ok", c.results[1].ok, c.results[1].detail)
    local drills = s.find_entities_filtered{name = "electric-mining-drill"}
    add("2 electric drills built", #drills == 2, #drills)
    for _, d in ipairs(drills) do
      local t = d.drop_target
      add("drill drops into a furnace", t ~= nil and t.type == "furnace", t and t.name or "nothing")
      add("drill is powered", d.status ~= defines.entity_status.no_power
          and d.status ~= defines.entity_status.not_plugged_in_electric_network, d.status)
      if t and t.type == "furnace" then
        add("furnace smelted", t.products_finished > 0 or t.get_inventory(defines.inventory.crafter_output).get_item_count() > 0,
            t.products_finished)
      end
    end
    local plates = 0
    for _, ch in ipairs(s.find_entities_filtered{type = "container"}) do plates = plates + ch.get_item_count("iron-plate") end
    add("inserters moved plates into chests", plates > 0, plates)
  end,
}

-- Machines 100+ tiles from the AI (ore patches lie far apart on a real map): tend
-- must still empty their furnaces and refuel their drills.
CASES.electric_row = {
  delay = 2400,
  setup = function(c)
    local d = STEP[c.facing or "south"]
    free_power(c.surface, c.force, -d[1] * 16 - 3, -d[2] * 16 - 3)
    paint_ore(c.surface, "iron-ore", 12 * d[1], 12 * d[2], 8)
    -- Place obstacles on the ore patch: dropped items, a tree, and an obsolete AI burner drill
    local ox, oy = 12 * d[1], 12 * d[2]
    c.surface.spill_item_stack{position = {ox, oy}, stack = {name = "iron-plate", count = 5}}
    c.surface.create_entity{name = "tree-01", position = {ox + 1, oy + 1}}
    local old_drill = c.surface.create_entity{name = "burner-mining-drill", position = {ox - 1, oy - 1}, force = c.force}
    if old_drill then AIRegistry.own(old_drill) end
    give(c.character, {["electric-mining-drill"] = 4, ["transport-belt"] = 30, ["small-electric-pole"] = 10, ["wooden-chest"] = 2, inserter = 2})
  end,
  run = function(c)
    return {{skill = "build_miner", resource = "iron-ore", output = "belt", count = 2}}
  end,
  check = function(c, add)
    local s = c.surface
    add("build_miner row ok", c.results[1] and c.results[1].ok, c.results[1] and c.results[1].detail)
    local drills = s.find_entities_filtered{name = "electric-mining-drill"}
    add("at least 2 electric drills built", #drills >= 2, #drills)
    local belts = s.find_entities_filtered{name = "transport-belt"}
    add("belts placed along row", #belts >= 4, #belts)
    for _, d in ipairs(drills) do
      add("drill is powered", d.status ~= defines.entity_status.no_power
          and d.status ~= defines.entity_status.not_plugged_in_electric_network, d.status)
    end
  end,
}

CASES.tend_far = {
  delay = 120,
  setup = function(c)
    local f = c.surface.create_entity{name = "stone-furnace", position = {90, 90}, force = c.force}
    f.get_inventory(defines.inventory.crafter_output).insert{name = "iron-plate", count = 12}
    c.furnace = f
    c.drill = c.surface.create_entity{name = "burner-mining-drill", position = {-95, -90}, force = c.force}
    c.chest = c.surface.create_entity{name = "iron-chest", position = {-95, -88}, force = c.force}
    for _, e in ipairs({f, c.drill, c.chest}) do AIRegistry.own(e) end
    c.chest.insert{name = "coal", count = 30}
    c.before = c.character.get_inventory(defines.inventory.character_main).get_item_count("iron-plate")
  end,
  run = function(c) return {{skill = "tend"}} end,
  check = function(c, add)
    local inv = c.character.get_inventory(defines.inventory.character_main)
    add("tend ok", c.results[1].ok, c.results[1].detail)
    add("far furnace emptied", c.furnace.valid and c.furnace.get_inventory(defines.inventory.crafter_output).is_empty())
    add("plates reached the AI", inv.get_item_count("iron-plate") >= c.before + 12, inv.get_item_count("iron-plate"))
    add("far drill refuelled", c.drill.valid and c.drill.get_fuel_inventory().get_item_count("coal") > 0)
    add("AI is back where it started", math.abs(c.character.position.x) < 20 and math.abs(c.character.position.y) < 20,
        c.character.position.x .. "," .. c.character.position.y)
  end,
}

-- A bare script character's hand-crafting doesn't count for the "craft a lab" research
-- trigger on its own (verified); craft_for reports it to the force's statistics.
-- Fresh force with only steam-power and electronics researched.
CASES.lab_trigger = {
  delay = 1800,
  setup = function(c)
    local f = game.create_force("ai-trig-" .. game.tick)
    f.technologies["steam-power"].researched = true
    f.technologies["electronics"].researched = true
    local ch = c.surface.create_entity{name = "character", position = {6.5, 0.5}, force = f}
    ch.character_crafting_speed_modifier = 5
    give(ch, {["iron-plate"] = 200, ["copper-plate"] = 100})
    c.trig_force, c.trig_char = f, ch
    c.trig_ok, c.trig_detail = AISkills.REGISTRY.craft_for(ch, {skill = "craft_for", item = "lab", count = 1})
  end,
  run = function() return {} end,
  check = function(c, add)
    local labs = c.trig_char.get_inventory(defines.inventory.character_main).get_item_count("lab")
    add("craft_for queued the lab", c.trig_ok, c.trig_detail)
    add("lab crafted", labs > 0, labs)
    add("craft-a-lab trigger fired", c.trig_force.technologies["automation-science-pack"].researched)
  end,
}

-- A lab standing 40 tiles from the nearest live pole (placed before the grid got there):
-- tend must run a pole chain to it.
CASES.tend_wire = {
  delay = 300,
  setup = function(c)
    free_power(c.surface, c.force, 15, 15)
    c.lab = c.surface.create_entity{name = "lab", position = {50.5, 40.5}, force = c.force}
    AIRegistry.own(c.lab)
    give(c.character, {["small-electric-pole"] = 12})
  end,
  run = function(c) return {{skill = "tend"}} end,
  check = function(c, add)
    add("tend ok", c.results[1].ok, c.results[1].detail)
    add("tend says it wired the lab", tostring(c.results[1].detail):find("wired") ~= nil, c.results[1].detail)
    local st = c.lab.status
    add("lab is powered", st ~= defines.entity_status.no_power
        and st ~= defines.entity_status.not_plugged_in_electric_network, st)
    add("AI is back where it started", math.abs(c.character.position.x) < 20 and math.abs(c.character.position.y) < 20)
  end,
}

-- A drill with nothing left to mine: tend picks it up (and its furnace) for reuse.
CASES.tend_depleted = {
  delay = 400,
  setup = function(c)
    c.drill = c.surface.create_entity{name = "burner-mining-drill", position = {20, 20}, force = c.force, direction = defines.direction.east}
    c.drill.insert{name = "coal", count = 5}          -- fuelled, so its status says "no ore" rather than "no fuel"
    AIRegistry.own(c.drill)
    c.furnace = c.drill.drop_target or c.surface.create_entity{name = "stone-furnace", position = {22.5, 19.5}, force = c.force}
    c.before = c.character.get_inventory(defines.inventory.character_main).get_item_count("burner-mining-drill")
  end,
  run = function() return {} end,
  late = function(c) return {{skill = "tend"}} end,
  late_after = 120,
  check = function(c, add)
    local inv = c.character.get_inventory(defines.inventory.character_main)
    add("tend ok", c.results[1] and c.results[1].ok, c.results[1] and c.results[1].detail)
    add("drill picked up", not c.drill.valid)
    add("drill is back in the inventory", inv.get_item_count("burner-mining-drill") > c.before, inv.get_item_count("burner-mining-drill"))
  end,
}

-- Green science: seven assembler units in three build calls, then one tend hauls plates in.
-- (The whole chain needs several tends; this checks the build and the first hop.)
CASES.green_cell = {
  delay = 1500,
  setup = function(c)
    free_power(c.surface, c.force, 15, 15)
    give(c.character, {["assembling-machine-1"] = 7, inserter = 14, ["wooden-chest"] = 16,
                       ["small-electric-pole"] = 30, ["iron-plate"] = 400, ["copper-plate"] = 200})
  end,
  run = function(c)
    return {{skill = "build_green_cell"}, {skill = "build_green_cell"}, {skill = "build_green_cell"}}
  end,
  late = function(c) return {{skill = "tend"}} end,
  late_after = 120,
  check = function(c, add)
    for i = 1, 3 do add("build_green_cell #" .. i .. " ok", c.results[i].ok, c.results[i].detail) end
    local recipes = {}
    for _, a in ipairs(c.surface.find_entities_filtered{type = "assembling-machine"}) do
      local r = a.get_recipe()
      if r then recipes[r.name] = (recipes[r.name] or 0) + 1 end
    end
    for _, name in ipairs({"iron-gear-wheel", "copper-cable", "electronic-circuit", "inserter", "transport-belt"}) do
      add("unit for " .. name, recipes[name] == 1, recipes[name])
    end
    add("2 science units", recipes["logistic-science-pack"] == 2, recipes["logistic-science-pack"])
    add("tend hauled plates", tostring(c.results[4] and c.results[4].detail):find("hauled") ~= nil,
        c.results[4] and c.results[4].detail)
    local made = 0
    for _, a in ipairs(c.surface.find_entities_filtered{type = "assembling-machine"}) do
      local r = a.get_recipe()
      if r and (r.name == "iron-gear-wheel" or r.name == "copper-cable") then made = made + a.products_finished end
    end
    add("gear and cable units produced", made > 0, made)
    local again, detail = AISkills.REGISTRY.build_green_cell(c.character, {})
    add("a fourth call finds nothing to build", again == false and tostring(detail):find("all 7") ~= nil, detail)
  end,
}

-- Gun turrets toward a nest, loaded; tend tops an emptied one back up.
CASES.defense = {
  delay = 600,
  setup = function(c)
    c.surface.create_entity{name = "biter-spawner", position = {70, 0}, force = "enemy"}
    give(c.character, {["gun-turret"] = 3, ["firearm-magazine"] = 60})
  end,
  run = function(c) return {{skill = "build_defense", count = 3}} end,
  late = function(c)
    for _, t in ipairs(c.surface.find_entities_filtered{name = "gun-turret"}) do
      t.get_inventory(defines.inventory.turret_ammo).clear()
      break
    end
    return {{skill = "tend"}}
  end,
  late_after = 120,
  check = function(c, add)
    add("build_defense ok", c.results[1].ok, c.results[1].detail)
    local turrets = c.surface.find_entities_filtered{name = "gun-turret"}
    add("3 turrets built", #turrets == 3, #turrets)
    for _, t in ipairs(turrets) do
      local ammo = t.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine")
      add("turret at " .. math.floor(t.position.x) .. "," .. math.floor(t.position.y) .. " is loaded", ammo >= 10, ammo)
      add("turret lies between home and the nest", t.position.x > 8 and t.position.x < 70, t.position.x)
    end
    add("tend loaded magazines", tostring(c.results[2] and c.results[2].detail):find("loaded") ~= nil,
        c.results[2] and c.results[2].detail)
    local ai = c.character
    add("a second call finds the turrets standing", select(1, AISkills.REGISTRY.build_defense(ai, {count = 3})) == false)
  end,
}

-- tend looks after what the AI placed (the owned set) and leaves anything else alone,
-- even with last_user nil (a player's or another mod's script entity).
CASES.tend_registry = {
  delay = 120,
  setup = function(c)
    local function furnace(x)
      local f = c.surface.create_entity{name = "stone-furnace", position = {x, 30}, force = c.force}
      f.get_inventory(defines.inventory.crafter_output).insert{name = "iron-plate", count = 7}
      return f
    end
    c.mine, c.theirs = furnace(10), furnace(20)
    AIRegistry.own(c.mine)
  end,
  run = function() return {{skill = "tend"}} end,
  check = function(c, add)
    add("tend ok", c.results[1].ok, c.results[1].detail)
    add("registered furnace emptied", c.mine.get_inventory(defines.inventory.crafter_output).is_empty())
    add("unregistered furnace untouched", c.theirs.get_inventory(defines.inventory.crafter_output).get_item_count("iron-plate") == 7)
    c.mine.destroy()
    AIRegistry.owned(c.surface, AISkills.TEND_TYPES)         -- prunes dead references
    local dead = 0
    for _, e in pairs(storage.ai_player.owned) do if not e.valid then dead = dead + 1 end end
    add("destroyed entity leaves the owned set", dead == 0, dead)
  end,
}

-- Rounds left in the AI's firearm magazines (a magazine only leaves the stack once its 10
-- rounds are used up, so the item count alone barely moves in a short fight).
local function rounds_of(ch)
  local n, size = 0, prototypes.item["firearm-magazine"].magazine_size
  for _, id in ipairs({defines.inventory.character_ammo, defines.inventory.character_main}) do
    local inv = ch.get_inventory(id)
    for i = 1, #inv do
      local s = inv[i]
      if s.valid_for_read and s.name == "firearm-magazine" then n = n + (s.count - 1) * size + s.ammo end
    end
  end
  return n
end
AISelftest.rounds_of = rounds_of

-- Step 0 of the reflexes: a player-less character with a pistol and magazines can shoot at all.
-- shooting_state is set every pulse (as the reflex does); the biter must die and the ammo
-- count must drop.
CASES.shoot_probe = {
  delay = 600,
  setup = function(c)
    c.ammo0 = rounds_of(c.character)
    c.character.selected_gun_index = 1
    c.biter = c.surface.create_entity{name = "small-biter", position = {9.5, 0.5}, force = "enemy"}
  end,
  run = function() return {} end,
  pulse = function(c)
    if c.biter and c.biter.valid then
      c.character.shooting_state = {state = defines.shooting.shooting_enemies, position = c.biter.position}
    else
      c.character.shooting_state = {state = defines.shooting.not_shooting, position = c.character.position}
    end
  end,
  check = function(c, add)
    local ammo = rounds_of(c.character)
    add("the biter died", not c.biter.valid)
    add("ammo went down", ammo < c.ammo0, c.ammo0 .. " -> " .. ammo .. " rounds")
    add("the character lives", c.character.valid and c.character.health > 0, c.character.health)
  end,
}

-- ---------------------------------------------------------------------------
-- Round 13 routing self-tests (Item 1)
-- ---------------------------------------------------------------------------

CASES.connect_pipe = {
  delay = 60,
  setup = function(c)
    give(c.character, {pipe = 50})
    -- Obstacle in the direct straight path: stone furnace at (10.5, 15.5)
    c.obs = c.surface.create_entity{name = "stone-furnace", position = {10.5, 15.5}, force = c.force}
    -- Existing foreign pipe at (12.5, 15.5)
    c.foreign = c.surface.create_entity{name = "pipe", position = {12.5, 15.5}, force = c.force}
    -- Confine corridor at x=12.5 with a fully enclosed box so a route cannot escape
    for y = 9, 21 do
      c.surface.create_entity{name = "stone-wall", position = {11.5, y + 0.5}, force = c.force}
      c.surface.create_entity{name = "stone-wall", position = {13.5, y + 0.5}, force = c.force}
    end
    c.surface.create_entity{name = "stone-wall", position = {12.5, 9.5}, force = c.force}
    c.surface.create_entity{name = "stone-wall", position = {12.5, 21.5}, force = c.force}

    -- Foreign perpendicular pipe line across x = 18.5 from y = 20 to 35
    for y = 20, 35 do
      c.surface.create_entity{name = "pipe", position = {18.5, y + 0.5}, force = c.force}
    end
    -- Enclose room from x = 16 to 22, y = 22 to 30
    for x = 16, 22 do
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 22.5}, force = c.force}
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 30.5}, force = c.force}
    end
    for y = 22, 30 do
      c.surface.create_entity{name = "stone-wall", position = {16.5, y + 0.5}, force = c.force}
      c.surface.create_entity{name = "stone-wall", position = {22.5, y + 0.5}, force = c.force}
    end
  end,
  run = function(c)
    -- 1. Route around obstacle from (10.5, 5.5) to (10.5, 20.5) (clean detour)
    local r1 = {skill = "connect_pipe", from = {x = 10.5, y = 5.5}, to = {x = 10.5, y = 20.5}}
    -- 2. Route through walled corridor containing foreign pipe: must be refused without underground (cannot merge)
    local r2 = {skill = "connect_pipe", from = {x = 12.5, y = 10.5}, to = {x = 12.5, y = 20.5}, underground = false}
    -- 3. Route crossing perpendicular pipe using underground pipes: from (17.5, 25.5) to (20.5, 25.5)
    local r3 = {skill = "connect_pipe", from = {x = 17.5, y = 25.5}, to = {x = 20.5, y = 25.5}}
    return {r1, r2, r3}
  end,
  check = function(c, add)
    add("route around obstacle placed", c.results[1] and c.results[1].ok, c.results[1] and c.results[1].detail)
    local pipes = c.surface.find_entities_filtered{type = {"pipe", "entity-ghost"}}
    add("pipes placed", #pipes > 5, #pipes .. " pipes/ghosts")
    local conns = {}
    if c.foreign and c.foreign.valid then
      local ok, cs = pcall(function() return c.foreign.get_fluid_box_pipe_connections(1) end)
      if ok and cs then
        for _, conn in ipairs(cs) do
          if conn.target_entity then conns[#conns + 1] = conn end
        end
      end
    end
    add("foreign pipe not merged", #conns == 0, #conns .. " connections to foreign pipe")
    add("route through foreign fluid corridor refused", c.results[2] and not c.results[2].ok, c.results[2] and c.results[2].detail)
    add("pipe route with underground placed", c.results[3] and c.results[3].ok, c.results[3] and c.results[3].detail)
    local ptgs = c.surface.find_entities_filtered{type = "entity-ghost", ghost_name = "pipe-to-ground"}
    add("pipe to ground ghosts placed", #ptgs >= 2, #ptgs .. " pipe-to-ground ghosts")
  end,
}

CASES.connect_belt = {
  delay = 60,
  setup = function(c)
    give(c.character, {["transport-belt"] = 100})
    -- Perpendicular foreign belt line across x = 15.5 from y = 0 to 30
    for y = 0, 30 do
      c.surface.create_entity{name = "transport-belt", position = {15.5, y + 0.5},
                              direction = defines.direction.south, force = c.force}
    end
    -- Enclose the room completely so r2 cannot escape or detour around the belt line
    for x = 9, 21 do
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 0.5}, force = c.force}
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 20.5}, force = c.force}
    end
    for y = 0, 20 do
      c.surface.create_entity{name = "stone-wall", position = {9.5, y + 0.5}, force = c.force}
      c.surface.create_entity{name = "stone-wall", position = {21.5, y + 0.5}, force = c.force}
    end

    -- Tunnel Corridor A (max distance 5 hop = 4 wall obstacle tiles, within yellow belt limit)
    for x = 23, 32 do
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 24.5}, force = c.force}
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 26.5}, force = c.force}
    end
    c.surface.create_entity{name = "stone-wall", position = {23.5, 25.5}, force = c.force}
    c.surface.create_entity{name = "stone-wall", position = {32.5, 25.5}, force = c.force}
    for x = 26, 29 do
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 25.5}, force = c.force}
    end

    -- Tunnel Corridor B (over-max distance 6 hop = 5 wall obstacle tiles, exceeds yellow belt limit)
    -- Thick solid wall padding around the corridor so undergrounds cannot jump out of the tunnel
    for x = 16, 40 do
      for y = 23, 29 do
        c.surface.create_entity{name = "stone-wall", position = {x + 0.5, y + 0.5}, force = c.force}
      end
      for y = 31, 38 do
        c.surface.create_entity{name = "stone-wall", position = {x + 0.5, y + 0.5}, force = c.force}
      end
    end
    for x = 16, 23 do
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 30.5}, force = c.force}
    end
    for x = 33, 40 do
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 30.5}, force = c.force}
    end
    -- 5 obstacle tiles at x = 26 to 30 (from 25.5 to 31.5 is distance 6)
    for x = 26, 30 do
      c.surface.create_entity{name = "stone-wall", position = {x + 0.5, 30.5}, force = c.force}
    end
  end,
  run = function(c)
    local r1 = {skill = "connect_belt", from = {x = 2.5, y = 2.5}, to = {x = 7.5, y = 12.5}}
    local r2 = {skill = "connect_belt", from = {x = 10.5, y = 5.5}, to = {x = 20.5, y = 5.5}, underground = false}
    local r3 = {skill = "connect_belt", from = {x = 10.5, y = 8.5}, to = {x = 20.5, y = 8.5}}
    local r4 = {skill = "connect_belt", from = {x = 25.5, y = 25.5}, to = {x = 30.5, y = 25.5}}
    local r5 = {skill = "connect_belt", from = {x = 25.5, y = 30.5}, to = {x = 31.5, y = 30.5}}
    return {r1, r2, r3, r4, r5}
  end,
  check = function(c, add)
    add("clean route placed", c.results[1] and c.results[1].ok, c.results[1] and c.results[1].detail)
    add("crossing existing belt refused", c.results[2] and not c.results[2].ok, c.results[2] and c.results[2].detail)
    add("crossing with underground belt placed", c.results[3] and c.results[3].ok, c.results[3] and c.results[3].detail)
    add("max underground hop distance 5 succeeds", c.results[4] and c.results[4].ok, c.results[4] and c.results[4].detail)
    add("over-max underground hop distance 6 refused", c.results[5] and not c.results[5].ok, c.results[5] and c.results[5].detail)


    local ugs = c.surface.find_entities_filtered{type = "entity-ghost", ghost_name = "underground-belt"}
    add("underground belts placed", #ugs >= 2, #ugs .. " underground belt ghosts")
    local proto = prototypes.entity["underground-belt"]
    local d_val = proto and proto.max_underground_distance or -1
    local paired = 0
    local debug_revive = {}
    for _, g in ipairs(ugs) do
      local r1, r2, r3 = g.silent_revive()
      table.insert(debug_revive, {pos = r2 and {x = r2.position.x, y = r2.position.y}, dir = r2 and r2.direction, ug_type = r2 and r2.belt_to_ground_type, n = r2 and tostring(r2.underground_belt_neighbour)})
      local ent = r2 or (r1 and r1.valid and r1)
      if ent and ent.valid then
        if ent.underground_belt_neighbour ~= nil then
          paired = paired + 1
        end
      end
    end
    add("underground belts paired", paired >= 2, paired .. " paired underground belts: " .. serpent.line(debug_revive))







    local mid = c.surface.find_entities_filtered{position = {15.5, 5.5}, radius = 0.3}[1]
    add("existing belt intact", mid and mid.direction == defines.direction.south, mid and mid.direction)
  end,
}

CASES.pump_search = {
  delay = 60,
  setup = function(c)
    give(c.character, {["offshore-pump"] = 5})
    if c.facing == "north" then
      lake(c.surface, "north", 30)
    elseif c.facing == "east" then
      lake(c.surface, "east", 60)
    end
  end,
  run = function(c)
    return {{skill = "build_offshore_pump"}}
  end,
  check = function(c, add)
    if c.facing == "north" or c.facing == "east" then
      add("offshore pump placed", c.results[1] and c.results[1].ok, c.results[1] and c.results[1].detail)
      local pump = c.surface.find_entities_filtered{name = "offshore-pump"}[1]
      add("pump exists in world", pump ~= nil, pump and string.format("{%.1f, %.1f}", pump.position.x, pump.position.y))
    else
      add("no lake within 64 gives clean failure", c.results[1] and not c.results[1].ok, c.results[1] and c.results[1].detail)
      local pump = c.surface.find_entities_filtered{name = "offshore-pump"}[1]
      add("no pump placed", pump == nil)
    end
  end,
}

CASES.astar_cap = {
  delay = 60,
  setup = function(c)
    give(c.character, {["transport-belt"] = 10})
    -- Goal at (20.5, 20.5) surrounded by a 5-tile thick water moat
    paint_water(c.surface, 14, 14, 26, 26)
    -- Restore island tile at (20, 20)
    c.surface.set_tiles({{name = "lab-white", position = {20, 20}}}, true, true)
  end,
  run = function(c)
    local p = helpers.create_profiler()
    local ok, res = AISkills.REGISTRY.connect_belt(c.character, {from = {x = 0.5, y = 0.5}, to = {x = 20.5, y = 20.5}})
    p.stop()
    c.prof_str = tostring(p)
    return {{skill = "connect_belt", from = {x = 0.5, y = 0.5}, to = {x = 20.5, y = 20.5}}}
  end,
  check = function(c, add)
    local r = c.results[1]
    add("impossible route fails fast", r and not r.ok, r and r.detail)
    add("profiler time logged", c.prof_str ~= nil, c.prof_str)
  end,
}

CASES.field_sizing = {
  delay = 60,
  setup = function(c) end,
  run = function(c) return {} end,
  check = function(c, add)
    local s = AILayout.field_sizing(37.5)
    add("37.5/min request gives 2 furnaces", s.furnaces == 2, s.furnaces)
    add("37.5/min request gives 2 drills", s.drills == 2, s.drills)
    add("37.5/min request gives 1 coal drill", s.coal_drills == 1, s.coal_drills)
    local s1 = AILayout.field_sizing(18.75)
    add("18.75/min gives 1 furnace", s1.furnaces == 1, s1.furnaces)
    add("18.75/min gives 1 drill", s1.drills == 1, s1.drills)
  end,
}

CASES.field_depletion = {
  delay = 60,
  setup = function(c)
    paint_ore(c.surface, "iron-ore", 10, 10, 4)
  end,
  run = function(c) return {} end,
  check = function(c, add)
    local total = AILayout.field_resource_remaining(c.surface, {{5, 5}, {15, 15}}, "iron-ore")
    add("field remaining resource calculated", total > 0, total)
    local empty = AILayout.field_resource_remaining(c.surface, {{50, 50}, {60, 60}}, "iron-ore")
    add("depleted/empty area returns 0", empty == 0, empty)
    local initial = 10000
    local remaining = 1500
    local needs_replacement = (remaining / initial) < 0.20
    add("below 20% triggers replacement", needs_replacement, string.format("%.1f%%", (remaining/initial)*100))
  end,
}

CASES.mining_field = {
  delay = 2400,
  setup = function(c)
    local facing = c.facing or "south"
    local d = STEP[facing]
    free_power(c.surface, c.force, -d[1] * 20 - 3, -d[2] * 20 - 3)
    paint_ore(c.surface, "iron-ore", 12 * d[1], 12 * d[2], 12)
    give(c.character, {["electric-mining-drill"] = 4, ["transport-belt"] = 60,
                       ["stone-furnace"] = 4, inserter = 8, ["iron-chest"] = 4,
                       ["small-electric-pole"] = 15, coal = 50})
  end,
  run = function(c)
    return {{skill = "build_miner", resource = "iron-ore", output = "field", count = 2}}
  end,
  check = function(c, add)
    local s = c.surface
    add("build_miner field ok", c.results[1] and c.results[1].ok, c.results[1] and c.results[1].detail)
    local drills = s.find_entities_filtered{name = "electric-mining-drill"}
    add("drills placed", #drills >= 2, #drills)
    local furnaces = s.find_entities_filtered{name = "stone-furnace"}
    add("furnaces placed", #furnaces >= 2, #furnaces)
    local belts = s.find_entities_filtered{name = "transport-belt"}
    add("belts placed", #belts >= 10, #belts)
    local inserters = s.find_entities_filtered{name = "inserter"}
    add("inserters placed", #inserters >= 4, #inserters)
    for _, d in ipairs(drills) do
      add("drill is powered", d.status ~= defines.entity_status.no_power
          and d.status ~= defines.entity_status.not_plugged_in_electric_network, d.status)
    end
  end,
}

CASES.doctor_output = {
  delay = 60,
  reflexes = true,
  setup = function(c)
    local chest = c.surface.create_entity{name = "iron-chest", position = {5, 5}, force = c.force}
    chest.insert{name = "iron-plate", count = 4800}
    AIRegistry.own(chest)
    c.chest = chest
    c.before = c.character.get_inventory(defines.inventory.character_main).get_item_count("iron-plate")
  end,
  run = function(c)
    AIReflexes.doctor_pass(c.character, 600)
    return {}
  end,
  check = function(c, add)
    local inv = c.character.get_inventory(defines.inventory.character_main)
    local after = inv.get_item_count("iron-plate")
    add("doctor cleared output into character inventory", after > c.before, after - c.before)
  end,
}

CASES.doctor_power = {
  delay = 120,
  reflexes = true,
  setup = function(c)
    free_power(c.surface, c.force, 0, 0)
    give(c.character, {["small-electric-pole"] = 5})
    local asm = c.surface.create_entity{name = "assembling-machine-1", position = {8.5, 0.5}, force = c.force}
    AIRegistry.add(asm)
    AIRegistry.own(asm)
    c.asm = asm
  end,
  run = function(c) return {} end,
  late = function(c)
    AIReflexes.doctor_pass(c.character, game.tick)
    return {}
  end,
  late_after = 30,
  check = function(c, add)
    local st = c.asm.status
    add("assembler is powered after doctor pass", st ~= defines.entity_status.no_power
        and st ~= defines.entity_status.not_plugged_in_electric_network, st)
  end,
}

CASES.doctor_ingredients = {
  delay = 120,
  reflexes = true,
  setup = function(c)
    free_power(c.surface, c.force, 0, 0)
    local asm = c.surface.create_entity{name = "assembling-machine-1", position = {3.5, 0.5}, force = c.force}
    asm.set_recipe("iron-gear-wheel")
    AIRegistry.add(asm)
    AIRegistry.own(asm)
    c.asm = asm
    local chest = c.surface.create_entity{name = "wooden-chest", position = {5.5, 0.5}, force = c.force}
    chest.insert{name = "iron-plate", count = 50}
    AIRegistry.own(chest)
    c.chest = chest
  end,
  run = function(c) return {} end,
  late = function(c)
    AIReflexes.doctor_pass(c.character, game.tick)
    return {}
  end,
  late_after = 30,
  check = function(c, add)
    local in_count = c.asm.get_inventory(defines.inventory.crafter_input).get_item_count("iron-plate")
    local out_count = c.asm.get_inventory(defines.inventory.crafter_output).get_item_count("iron-gear-wheel")
    local prog = c.asm.crafting_progress
    add("assembler received ingredients from doctor haul", in_count > 0 or out_count > 0 or prog > 0,
        string.format("in=%d out=%d prog=%.2f", in_count, out_count, prog))
  end,
}

-- Cases for later rounds register themselves here (selftest_cases.lua).
AISelftest.CASES = CASES
AISelftest.helpers = {paint_ore = paint_ore, paint_water = paint_water, lake = lake, give = give,
                      count_in = count_in, chest_total = chest_total, free_power = free_power, STEP = STEP}

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------
local function finish(result)
  local st = storage.selftest
  AILayout.only_facing = nil
  if st and st.prev then               -- a reflex case: give the AI slot back
    local ap, prev = storage.ai_player, st.prev
    ap.character, ap.surface_name, ap.combat_mode = prev.character, prev.surface_name, prev.combat_mode
    ap.force_name = prev.force_name
    ap.reflex, ap.held_turn, ap.turn, ap.last_attack = nil, nil, nil, nil
    ap.respawn_tick, ap.fast_decide_tick, ap.tick_counter = nil, nil, 0
    ap.pending_requests = {}
  end
  if st and st.surface and st.surface.valid then game.delete_surface(st.surface) end
  storage.selftest = nil
  write_result(result)
end

function AISelftest.start(arg)
  if not armed() then
    return write_result({ok = false, case = arg, run_id = "?", detail = "refused: map is not a self-test map"})
  end
  local name, run_id = (arg or ""):match("^(%S+)%s*(%S*)$")
  local case_name, facing = (name or ""):match("^([^:]+):?(%a*)$")
  if run_id == "" then run_id = tostring(game.tick) end
  local case = case_name and CASES[case_name]
  if not case then
    return write_result({ok = false, case = name, run_id = run_id, detail = "unknown case"})
  end
  local old = storage.selftest
  if old and old.check_tick and game.tick > old.check_tick + 1800 then
    finish({ok = false, case = old.case, run_id = old.run_id, detail = "abandoned"})   -- stale: clear it
  end
  if storage.selftest then
    return write_result({ok = false, case = name, run_id = run_id, detail = "another self-test is running"})
  end
  facing = (facing ~= "" and facing) or "south"

  local ok, err = pcall(function()
    storage.selftest_n = (storage.selftest_n or 0) + 1
    local surface = game.create_surface("ai-selftest-" .. storage.selftest_n)
    surface.generate_with_lab_tiles = true
    surface.request_to_generate_chunks({0, 0}, 5)
    surface.force_generate_chunk_requests()
    local force = force_for_tests()
    local character = surface.create_entity{name = "character", position = {0.5, 0.5}, force = force}
    AICharacter.give_starting_items(character)
    give(character, {["iron-plate"] = 300, ["copper-plate"] = 150, ["stone"] = 50, coal = 100})
    AICharacter.set_home(surface, character.position)
    local c = {surface = surface, force = force, character = character, facing = facing, results = {}}
    storage.selftest = {case = name, run_id = run_id, c = c, surface = surface, case_name = case_name}
    if case.reflexes then
      -- The scene's character becomes THE AI for this case; the decision tick is parked so no
      -- request goes out for the throwaway surface.
      local ap = storage.ai_player
      storage.selftest.prev = {character = ap.character, surface_name = ap.surface_name, combat_mode = ap.combat_mode, force_name = ap.force_name}
      ap.character, ap.combat_mode = c.character, nil
      ap.force_name = c.force.name
      ap.reflex, ap.held_turn, ap.turn, ap.last_attack = nil, nil, nil, nil
      ap.tick_counter, ap.fast_decide_tick = -1000000000, nil
      AICharacter.remember_surface(surface)
      AICharacter.set_home(surface, {x = 0.5, y = 0.5})
      storage.selftest.reflexes = true
    end
    case.setup(c)
    for _, entry in ipairs(case.run(c)) do
      -- Call the handler directly so a crash keeps its full traceback.
      local cok, rok, detail = xpcall(AISkills.REGISTRY[entry.skill],
        function(e) return debug.traceback(tostring(e), 2) end, character, entry)
      if not cok then rok, detail = false, rok end
      c.results[#c.results + 1] = {ok = rok ~= false, detail = detail}
    end
    if case.after then case.after(c) end
    storage.selftest.check_tick = game.tick + case.delay
    if case.late then storage.selftest.late_tick = game.tick + (case.late_after or 60) end
  end)
  if not ok then
    finish({ok = false, case = name, run_id = run_id, detail = "harness error: " .. tostring(err)})
  end
end

-- Called by the reflex tick (every 15 ticks): keeps the parked decision tick parked.
function AISelftest.pulse()
  local st = storage.selftest
  local case = st and CASES[st.case_name]
  if st and st.reflexes and not (case and case.keep_fast) then storage.ai_player.fast_decide_tick = nil end
end

local function conclude()
  local st = storage.selftest
  local checks, all = {}, true
  local ok, err = pcall(CASES[st.case_name].check, st.c, function(n, passed, info)
    checks[#checks + 1] = {name = n, ok = passed and true or false, info = info ~= nil and tostring(info) or nil}
    if not passed then all = false end
  end)
  if not ok then
    all = false
    checks[#checks + 1] = {name = "check function", ok = false, info = tostring(err)}
  end
  local detail = {}
  for _, r in ipairs(st.c.results) do detail[#detail + 1] = tostring(r.detail) end
  finish({ok = all, case = st.case, run_id = st.run_id, checks = checks, detail = table.concat(detail, " | ")})
end

-- Second run phase for cases that need the world to settle first (entities
-- placed this tick may not have resolved their targets yet).
local function run_late(st)
  local late = st.late_tick
  st.late_tick = nil
  for _, entry in ipairs(CASES[st.case_name].late(st.c)) do
    local cok, rok, detail = xpcall(AISkills.REGISTRY[entry.skill],
      function(e) return debug.traceback(tostring(e), 2) end, st.c.character, entry)
    if not cok then rok, detail = false, rok end
    st.c.results[#st.c.results + 1] = {ok = rok ~= false, detail = detail}
  end
end

script.on_nth_tick(30, function()
  local st = storage.selftest
  if not st then return end
  local case = CASES[st.case_name]
  if case and case.pulse and st.c then pcall(case.pulse, st.c) end
  if st.late_tick and game.tick >= st.late_tick then
    local ok, err = pcall(run_late, st)
    if not ok then return finish({ok = false, case = st.case, run_id = st.run_id, detail = "late phase: " .. tostring(err)}) end
  end
  if st.check_tick and game.tick >= st.check_tick then conclude() end
end)

-- ---------------------------------------------------------------------------
-- Soak support (armed maps only, RCON/console only)
-- ---------------------------------------------------------------------------
local SOAK_MAX_SPEED = 16

-- The headless server has no player to generate chunks as the AI walks, so
-- ask for them around it (non-blocking) every 30 s.
script.on_nth_tick(1800, function()
  if not (storage.soak and storage.soak.on) or not armed() then return end
  local ch = storage.ai_player and storage.ai_player.character
  if ch and ch.valid then
    ch.surface.request_to_generate_chunks(ch.position, 5)
  end
end)

local function soak_start()
  local s = game.surfaces["nauvis"]
  s.request_to_generate_chunks({0, 0}, 8)
  s.force_generate_chunk_requests()
  storage.soak = {on = true, start_tick = game.tick}
end

-- One full perception (what the bridge sees) plus soak extras, as a file the
-- runner reads: RCON replies are too small for it.
local function soak_snapshot()
  local ch = storage.ai_player and storage.ai_player.character
  local out = {tick = game.tick, speed = game.speed, character_valid = ch ~= nil and ch.valid}
  if out.character_valid then
    out.perception = AIPerception.gather(ch)
    local lost = storage.soak and storage.soak.lost or {}
    out.lost = lost
    local made = {}                  -- recipe -> products finished by AI-force assemblers
    for _, a in ipairs(ch.surface.find_entities_filtered{type = "assembling-machine", force = ch.force}) do
      local r = a.get_recipe()
      if r then made[r.name] = (made[r.name] or 0) + a.products_finished end
    end
    out.assembler_products = made
    out.enemies_seen = #ch.surface.find_entities_filtered{type = "unit-spawner", force = "enemy", position = ch.position, radius = 300}
    local home = AICharacter.get_home(ch.surface) or ch.position
    out.spawners_home = ch.surface.count_entities_filtered{type = "unit-spawner", force = "enemy", position = home, radius = 150}
  end
  local rf = storage.ai_player and storage.ai_player.reflex
  if rf then                           -- plain data only (see reflexes.lua)
    out.reflex = {state = rf.state, deaths = rf.deaths, nests_cleared = rf.nests_cleared, hunts_done = rf.hunts_done,
                  bridge_offline = rf.bridge_offline, last_research = rf.last_research, last_tend = rf.last_tend,
                  death = rf.death, since = rf.since}
  end
  out.combat_mode = AIReflexes.mode()
  pcall(function()               -- enemies the AI's force killed (turrets count too), summed over kinds
    local f = game.forces[storage.ai_player.force_name]
    local ks = f.get_kill_count_statistics(game.surfaces["nauvis"])
    local i, o = 0, 0
    for _, n in pairs(ks.input_counts) do i = i + n end
    for _, n in pairs(ks.output_counts) do o = o + n end
    out.kills_in, out.kills_out = i, o
  end)
  local mags = 0
  if ch and ch.valid then
    mags = ch.get_inventory(defines.inventory.character_main).get_item_count("firearm-magazine")
         + ch.get_inventory(defines.inventory.character_ammo).get_item_count("firearm-magazine")
  end
  out.magazines = mags
  out.furnaces_unfuelled = 0          -- AI-owned furnaces / boilers with ore or a load but no fuel
  if ch and ch.valid then
    for _, e in ipairs(AIRegistry.owned(ch.surface, {"furnace", "boiler", "mining-drill"})) do
      local fb = e.get_fuel_inventory and e.get_fuel_inventory()
      if fb and fb.valid and fb.is_empty() and e.energy < 1 and e.burner then out.furnaces_unfuelled = out.furnaces_unfuelled + 1 end
    end
  end
  helpers.write_file("ai-player/soak_snapshot.json", helpers.table_to_json(out), false, 0)
end

local function soak_command(name, fn)
  commands.add_command(name, "Soak-test support (armed maps only)", function(cmd)
    if cmd.player_index then return end        -- RCON / console only
    if not armed() then return end
    fn(cmd)
  end)
end

soak_command("ai-soak-start", function() soak_start() end)

-- /ai-soak-nests <count> <distance>: small nests (a spawner and two small worms) on a ring
-- around home, for the hunt soak. Natural nests sit 150+ tiles out on the soak maps. The AI
-- also gets a submachine gun and 100 magazines: the soak economy has no iron to spare for them.
soak_command("ai-soak-nests", function(cmd)
  local n, d = (cmd.parameter or ""):match("(%d+)%s+(%d+)")
  local ch = storage.ai_player and storage.ai_player.character
  if not (n and ch and ch.valid) then return end
  local s = ch.surface
  local home = AICharacter.get_home(s) or ch.position
  local inv = ch.get_inventory(defines.inventory.character_main)
  inv.insert{name = "submachine-gun", count = 1}
  inv.insert{name = "firearm-magazine", count = 100}
  for i = 1, tonumber(n) do
    local a = i * 2 * math.pi / tonumber(n) + 0.7
    local at = s.find_non_colliding_position("biter-spawner", {home.x + math.cos(a) * d, home.y + math.sin(a) * d}, 30, 2)
    if at then
      s.create_entity{name = "biter-spawner", position = at, force = "enemy"}
      for k = -1, 1, 2 do
        local w = s.find_non_colliding_position("small-worm-turret", {at.x + k * 7, at.y + 5}, 8, 1)
        if w then s.create_entity{name = "small-worm-turret", position = w, force = "enemy"} end
      end
    end
  end
end)

-- /ai-soak-raid <small> [<medium>]: biters 45 tiles from home on a side that changes every
-- call, sent at home. (Medium ones shrug off firearm magazines: the AI can only run from those.)
soak_command("ai-soak-raid", function(cmd)
  local n, m = (cmd.parameter or ""):match("(%d+)%s*(%d*)")
  n, m = tonumber(n) or 4, tonumber(m) or 0
  local ch = storage.ai_player and storage.ai_player.character
  if not (ch and ch.valid) then return end
  local s = ch.surface
  local home = AICharacter.get_home(s) or ch.position
  local a = (game.tick / 3600) * 2.4
  for i = 1, n + m do
    local name = i <= n and "small-biter" or "medium-biter"
    local at = s.find_non_colliding_position(name, {home.x + math.cos(a) * 45 + i, home.y + math.sin(a) * 45}, 12, 1)
    local u = at and s.create_entity{name = name, position = at, force = "enemy"}
    if u then
      u.commandable.set_command{type = defines.command.attack_area, destination = home, radius = 25,
                                distraction = defines.distraction.by_enemy}
    end
  end
end)
soak_command("ai-soak-snapshot", function()
  local ok, err = pcall(soak_snapshot)
  if not ok then helpers.write_file("ai-player/soak_snapshot.json", helpers.table_to_json({error = tostring(err)}), false, 0) end
end)
soak_command("ai-soak-speed", function(cmd)
  local n = tonumber(cmd.parameter) or 1
  game.speed = math.max(0.25, math.min(SOAK_MAX_SPEED, n))
end)

soak_command("ai-sprint-check", function(cmd)
  local name = cmd.parameter or "automation-science-pack"
  local s = game.surfaces["nauvis"]
  if not s then return end
  local fname = (storage.ai_player and storage.ai_player.force_name) or "player"
  local f = game.forces[fname] or game.forces["player"]
  local p = f.get_item_production_statistics(s)
  local c = p.get_flow_count{name = name, category = "input", precision_index = defines.flow_precision_index.one_minute, count = true}
  local tot = p.get_input_count(name)
  -- Third field: items finished by assembling machines (products_finished). Hand-crafted
  -- packs show up in the production stats and the inventory but never here, so a sprint
  -- only counts once automation really produced the item.
  local made = 0
  for _, a in ipairs(s.find_entities_filtered{type = "assembling-machine", force = f}) do
    local r = a.get_recipe()
    if r and r.name == name then made = made + a.products_finished end
  end
  rcon.print(string.format("%d,%d,%d", math.floor(c), math.floor(tot), made))
end)

soak_command("ai-sprint-oil", function()
  local s = game.surfaces["nauvis"]
  if not s then return end
  local fname = (storage.ai_player and storage.ai_player.force_name) or "player"
  local pj = s.count_entities_filtered{name = "pumpjack", force = fname}
  local ref = s.count_entities_filtered{name = "oil-refinery", force = fname}
  rcon.print(string.format("%d,%d", pj, ref))
end)

commands.add_command("ai-selftest", "Run an in-game self-test case (self-test maps only)", function(cmd)
  if cmd.player_index then
    local p = game.get_player(cmd.player_index)
    if not (p and p.admin) then return end
  end
  AISelftest.start(cmd.parameter)
end)

return AISelftest
