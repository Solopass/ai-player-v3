-- Collects world state into a JSON-serialisable table.
-- The bridge (Python) is responsible for assembling the LLM prompt.
-- This module only gathers facts — it does not format prompts.

AIPerception = {}

-- Entity status enum → readable string
-- Checked against the Factorio 2.1 runtime API (crafter_input replaces the
-- 2.0 furnace_source / assembling_machine_input defines).
local STATUS_NAMES = {
  [defines.entity_status.working]                        = "working",
  [defines.entity_status.normal]                         = "normal",
  [defines.entity_status.no_power]                       = "no_power",
  [defines.entity_status.low_power]                      = "low_power",
  [defines.entity_status.not_plugged_in_electric_network]= "no_power",
  [defines.entity_status.no_fuel]                        = "no_fuel",
  [defines.entity_status.no_recipe]                      = "no_recipe",
  [defines.entity_status.no_ingredients]                 = "no_ingredients",
  [defines.entity_status.item_ingredient_shortage]       = "no_ingredients",
  [defines.entity_status.fluid_ingredient_shortage]      = "no_fluid_ingredient",
  [defines.entity_status.waiting_for_source_items]       = "no_ingredients",
  [defines.entity_status.full_output]                    = "output_full",
  [defines.entity_status.not_enough_space_in_output]     = "output_full",
  [defines.entity_status.waiting_for_space_in_destination] = "output_full",
  [defines.entity_status.full_burnt_result_output]       = "burnt_output_full",
  [defines.entity_status.no_input_fluid]                 = "no_input_fluid",
  [defines.entity_status.missing_required_fluid]         = "no_input_fluid",
  [defines.entity_status.low_input_fluid]                = "low_input_fluid",
  [defines.entity_status.disabled_by_control_behavior]   = "disabled",
  [defines.entity_status.disabled_by_script]             = "disabled",
  [defines.entity_status.disabled]                       = "disabled",
  [defines.entity_status.opened_by_circuit_network]      = "opened",
  [defines.entity_status.closed_by_circuit_network]      = "closed",
  [defines.entity_status.preparing_rocket_for_launch]    = "preparing_rocket",
  [defines.entity_status.waiting_to_launch_rocket]       = "waiting_to_launch",
  [defines.entity_status.launching_rocket]               = "launching_rocket",
  [defines.entity_status.no_modules_to_transmit]         = "no_modules",
  [defines.entity_status.recharging_after_power_outage]  = "recharging",
  [defines.entity_status.waiting_for_target_to_be_built] = "waiting_for_target",
  [defines.entity_status.waiting_for_train]              = "waiting_for_train",
  [defines.entity_status.no_ammo]                        = "no_ammo",
  [defines.entity_status.no_research_in_progress]        = "no_research",
  [defines.entity_status.missing_science_packs]          = "no_research",
  [defines.entity_status.charging]                       = "charging",
  [defines.entity_status.discharging]                    = "discharging",
  [defines.entity_status.fully_charged]                  = "fully_charged",
  [defines.entity_status.out_of_logistic_network]        = "no_logistic_network",
  [defines.entity_status.no_minable_resources]           = "depleted",
  [defines.entity_status.marked_for_deconstruction]      = "marked_for_deconstruction",
  [defines.entity_status.recipe_not_researched]          = "recipe_not_researched",
  [defines.entity_status.low_temperature]                = "low_temperature",
  [defines.entity_status.paused]                         = "paused",
}

local function status_string(entity)
  if not entity.status then return nil end
  return STATUS_NAMES[entity.status] or ("status_" .. tostring(entity.status))
end

-- Top-N items from an inventory by count.
-- Factorio 2.0: get_contents() returns array of {name, count, quality} tables,
-- not the Factorio 1.x dict {[name] = count}.
local function summarize_inventory(inv, limit)
  if not inv then return {} end
  local contents = inv.get_contents()
  if not contents then return {} end
  table.sort(contents, function(a, b) return a.count > b.count end)
  local result = {}
  for i = 1, math.min(limit or 10, #contents) do
    result[i] = {name = contents[i].name, count = contents[i].count}
  end
  return result
end

-- Fuel inventory for a burner entity
local function get_fuel_contents(entity)
  local ok, inv = pcall(function() return entity.get_fuel_inventory() end)
  if ok and inv then return summarize_inventory(inv, 3) end
  return nil
end

-- Input inventory of a furnace or assembler (2.1: crafter_input for both).
local function get_input_contents(entity)
  local define = defines.inventory.crafter_input
  local ok, inv = pcall(function() return entity.get_inventory(define) end)
  if ok and inv then return summarize_inventory(inv, 5) end
  return nil
end

-- Output inventory
local function get_output_contents(entity)
  local ok, inv = pcall(function() return entity.get_output_inventory() end)
  if ok and inv then return summarize_inventory(inv, 5) end
  return nil
end

-- Pipe/fluid connection points for fluid entities, so the model can route pipes
-- to the correct side. Each connection: fluid name (water/steam/…), flow
-- direction ("input"|"output"|"input-output"), and the connection position.
-- This is what tells the model which boiler side is water vs steam.
local FLUID_CONN_TYPES = {
  ["boiler"]            = true,
  ["generator"]         = true,  -- steam-engine
  ["offshore-pump"]     = true,
  ["pump"]              = true,
  ["assembling-machine"]= true,  -- fluid recipes later
}

local function round1(n) return math.floor(n * 10 + 0.5) / 10 end

-- Factorio 2.1 removed LuaEntity::fluidbox / LuaFluidBox; fluid storages are
-- indexed directly on the entity (1..fluids_count). Storages without a
-- fluidbox (fluid wagons, turret buffers) return nil prototype/connections.
local function get_fluid_connections(entity)
  local ok, count = pcall(function() return entity.fluids_count end)
  if not ok or not count or count == 0 then return nil end
  local conns = {}
  for i = 1, count do
    local fluid = nil
    local okf, filt = pcall(function()
      local proto = entity.get_fluid_box_prototype(i)
      -- merged crafting-machine fluidboxes return an array of prototypes
      if proto and proto.object_name == nil and proto[1] then proto = proto[1] end
      return proto and proto.filter
    end)
    if okf and filt then fluid = filt.name end
    local okc, cs = pcall(function() return entity.get_fluid_box_pipe_connections(i) end)
    if okc and cs then
      for _, c in ipairs(cs) do
        if c.position and c.flow_direction then
          conns[#conns + 1] = {
            fluid    = fluid,
            flow     = c.flow_direction,
            position = {x = round1(c.position.x), y = round1(c.position.y)},
          }
        end
      end
    end
  end
  if #conns == 0 then return nil end
  return conns
end

-- Slots available on this entity type (mirrors bridge prototypes.py)
local ENTITY_SLOTS = {
  ["stone-furnace"]        = {"fuel","input","output"},
  ["steel-furnace"]        = {"fuel","input","output"},
  ["electric-furnace"]     = {"input","output"},
  ["burner-mining-drill"]  = {"fuel"},
  ["electric-mining-drill"]= {},
  ["assembling-machine-1"] = {"input","output"},
  ["assembling-machine-2"] = {"input","output"},
  ["assembling-machine-3"] = {"input","output"},
  ["boiler"]               = {"fuel"},
  ["lab"]                  = {"lab"},
  ["gun-turret"]           = {"ammo"},
  ["wooden-chest"]         = {"chest"},
  ["iron-chest"]           = {"chest"},
  ["steel-chest"]          = {"chest"},
}

local function entity_slots(entity_name)
  return ENTITY_SLOTS[entity_name] or {}
end

-- Is this entity on an enemy force?
local function is_enemy(entity, player_force)
  return entity.force and entity.force.is_enemy(player_force)
end

-- Detect current game phase from RESEARCH milestones — science is the true
-- progress marker. One rung per science tier, highest first:
--   0 bootstrap (no red science) · 1 red/automation · 2 green/logistic
--   3 military · 4 blue/chemical · 5 production+utility · 6 rocket
local function detect_game_phase(force)
  local t = force.technologies
  local function done(n) return t[n] and t[n].researched end
  if done("space-science-pack") or done("rocket-silo")            then return 6 end
  if done("production-science-pack") or done("utility-science-pack") then return 5 end
  if done("chemical-science-pack")                                then return 4 end
  if done("military-science-pack")                               then return 3 end
  if done("logistic-science-pack")                              then return 2 end
  if done("automation") or done("automation-science-pack")     then return 1 end
  return 0
end

-- Power/grid health for `force` — so the AI knows whether power is already
-- sufficient instead of reflexively bootstrapping steam. no_power/low_power
-- counts come from the factory status scan; throughput from network stats
-- (pcall-guarded: a power read must never break perception).
local function compute_power(surface, force, by_status)
  local poles = surface.count_entities_filtered{type = "electric-pole", force = force}
  local power = {
    has_grid           = poles > 0,
    machines_no_power  = (by_status and by_status.no_power)  or 0,
    machines_low_power = (by_status and by_status.low_power) or 0,
  }
  pcall(function()
    local pole = surface.find_entities_filtered{type = "electric-pole", force = force, limit = 1}[1]
    if not pole then return end
    local stats = pole.electric_network_statistics
    local idx = defines.flow_precision_index.one_minute
    local prod, cons = 0, 0
    for name in pairs(stats.output_counts) do
      prod = prod + stats.get_flow_count{name = name, category = "output", precision_index = idx, count = false}
    end
    for name in pairs(stats.input_counts) do
      cons = cons + stats.get_flow_count{name = name, category = "input", precision_index = idx, count = false}
    end
    -- Electric network flow counts are joules per tick: x60 for watts.
    power.production_kw  = math.floor(prod * 60 / 1000)
    power.consumption_kw = math.floor(cons * 60 / 1000)
  end)
  return power
end

-- Production statistics — the canonical "is the factory growing" signal.
-- All-time totals + last-minute rates for a small whitelist of milestone
-- items, plus researched-tech count. Compact by design (only nonzero items)
-- so it stays cheap in the prompt; the bridge's metrics.jsonl also snapshots
-- it per turn for run evaluation (bridge/metrics.py, bridge/report.py).
local PRODUCTION_ITEMS = {
  "wood", "coal", "stone", "iron-ore", "copper-ore",
  "iron-plate", "copper-plate", "stone-brick", "steel-plate",
  "iron-gear-wheel", "copper-cable", "electronic-circuit",
  "automation-science-pack", "logistic-science-pack", "military-science-pack",
  "chemical-science-pack", "production-science-pack", "utility-science-pack",
  "space-science-pack",
  -- milestones for the bridge's goal ladder (bridge/goals.py)
  "plastic-bar", "sulfur", "advanced-circuit", "processing-unit", "engine-unit",
  "flying-robot-frame", "construction-robot", "low-density-structure", "rocket-fuel", "rocket-part",
}

-- Checked first for perception.craftable (capped at 25 names).
local CRAFT_PRIORITY = {
  "iron-gear-wheel", "copper-cable", "electronic-circuit", "automation-science-pack",
  "logistic-science-pack", "transport-belt", "inserter", "burner-inserter",
  "small-electric-pole", "pipe", "stone-furnace", "burner-mining-drill",
  "electric-mining-drill", "assembling-machine-1", "assembling-machine-2", "lab",
  "boiler", "steam-engine", "offshore-pump", "iron-chest", "underground-belt", "splitter",
}

-- Technologies the goal ladder checks; reported as research.done.
local KEY_TECHS = {
  -- steam-power, electronics and automation-science-pack unlock by trigger in 2.x
  "steam-power", "automation-science-pack",
  "automation", "logistics", "electronics", "logistic-science-pack", "steel-processing",
  "gun-turret", "stone-wall", "physical-projectile-damage-1", "weapon-shooting-speed-1",
  "automation-2", "engine", "electric-energy-distribution-1",
  "military", "military-science-pack", "fast-inserter", "advanced-material-processing",
  "oil-processing", "plastics", "advanced-circuit", "sulfur-processing",
  "chemical-science-pack", "battery", "advanced-oil-processing", "production-science-pack",
  "utility-science-pack", "robotics", "construction-robotics", "rocket-fuel", "low-density-structure", "rocket-control-unit",
  "rocket-silo", "space-science-pack",
}

local function compute_production(force, surface)
  local production = {items = {}}
  pcall(function()
    local stats = force.get_item_production_statistics(surface)
    local idx = defines.flow_precision_index.one_minute
    for _, name in ipairs(PRODUCTION_ITEMS) do
      local total = stats.get_input_count(name)
      if total and total > 0 then
        local per_min = stats.get_flow_count{
          name = name, category = "input", precision_index = idx, count = true,
        }
        production.items[name] = {total = total, per_min = math.floor(per_min + 0.5)}
      end
    end
  end)
  local researched = 0
  for _, t in pairs(force.technologies) do
    if t.researched then researched = researched + 1 end
  end
  production.techs_researched = researched
  production.rockets_launched = force.rockets_launched
  return production
end

-- -------------------------------------------------------------------------
-- Whole-base machine view (scale-aware). One force-wide scan yields:
--   * aggregate counts by_type and by_status (always cheap to read)
--   * attention: machines with a PROBLEM status, nearest-first, bounded
--   * machines: a full per-machine roster ONLY while the base is small
--     (<= FACTORY_DETAIL_THRESHOLD) — "individual machines at the start";
--     above the threshold we rely on aggregates + attention to keep the prompt
--     bounded as the base grows to hundreds of machines.
-- Also returns the categorised `needs` buckets the router uses for maintenance,
-- now computed factory-WIDE instead of from the local 25-entity sample.
-- (Later optimisation: maintain an event-driven registry to avoid this scan.)
-- -------------------------------------------------------------------------
local MACHINE_TYPES = {
  "assembling-machine", "furnace", "mining-drill", "lab", "boiler",
  "generator", "ammo-turret", "offshore-pump", "pump", "rocket-silo",
}

-- Statuses that mean "this machine needs action" (vs benign working/normal/etc.)
local PROBLEM_STATUS = {
  no_power = true, low_power = true, no_fuel = true, no_recipe = true,
  no_ingredients = true, no_fluid_ingredient = true, output_full = true,
  burnt_output_full = true, no_input_fluid = true, low_input_fluid = true,
  depleted = true, no_ammo = true, no_research = true,
  recipe_not_researched = true, low_temperature = true,
}

local FACTORY_DETAIL_THRESHOLD = 30  -- emit per-machine roster at/below this total
local ATTENTION_LIMIT = 20

local function gather_factory(surface, force, cpos)
  -- Read the maintained registry instead of rescanning the surface each tick
  -- (registry.lua; kept fresh by events + periodic reconcile). MACHINE_TYPES is
  -- retained as documentation of what counts as a machine — the registry tracks
  -- the same set.
  local machines = AIRegistry.machines()
  local by_type, by_status, attention = {}, {}, {}
  local miners, labs = {}, {count = 0, without_packs = 0}
  local assemblers, electric = {}, {}
  local needs = {burners_low_fuel = {}, machines_no_recipe = {},
                 machines_no_input = {}, outputs_full = {}}
  local total = 0

  for _, e in ipairs(machines) do
    if e.valid then
      total = total + 1
      by_type[e.name] = (by_type[e.name] or 0) + 1
      if e.type == "mining-drill" then
        local res = AISkills.drill_resource(e)
        if res then miners[res] = (miners[res] or 0) + 1 end
        if res and e.name == "electric-mining-drill" then electric[res] = (electric[res] or 0) + 1 end
      elseif e.type == "lab" then
        labs.count = labs.count + 1
        local li = e.get_inventory(defines.inventory.lab_input)
        if li and li.is_empty() then labs.without_packs = labs.without_packs + 1 end
      end
      local st = status_string(e)
      if e.type == "assembling-machine" and #assemblers < 12 then
        local r = e.get_recipe()
        assemblers[#assemblers + 1] = {recipe = r and r.name or nil, status = st, input_low = st == "no_ingredients"}
      end
      -- "Output full" is normal for boilers/engines with no power load and for
      -- drills feeding coal into another burner's full fuel slot; reporting
      -- those sends the model chasing a problem that isn't one.
      if st == "output_full" then
        local tgt = e.type == "mining-drill" and e.drop_target
        if e.type == "boiler" or e.type == "generator"
           or (tgt and tgt.type ~= "container" and tgt.type ~= "furnace") then
          st = "working"
        end
      end
      if st then by_status[st] = (by_status[st] or 0) + 1 end
      if st and PROBLEM_STATUS[st] then
        local epos = {x = math.floor(e.position.x), y = math.floor(e.position.y)}
        local dx, dy = e.position.x - cpos.x, e.position.y - cpos.y
        attention[#attention + 1] = {name = e.name, type = e.type, status = st,
          position = epos, distance = math.floor(math.sqrt(dx * dx + dy * dy))}
        if     st == "no_fuel"        then table.insert(needs.burners_low_fuel,  {name = e.name, position = epos})
        elseif st == "no_recipe"      then table.insert(needs.machines_no_recipe, {name = e.name, position = epos})
        elseif st == "no_ingredients" then table.insert(needs.machines_no_input,  {name = e.name, position = epos})
        elseif st == "output_full"    then
          local tgt = e.type == "mining-drill" and e.drop_target
          table.insert(needs.outputs_full, {name = e.name, position = epos,
            drop = e.type == "mining-drill" and (tgt and tgt.type or "ground") or nil})
        end
      end
    end
  end

  table.sort(attention, function(a, b) return a.distance < b.distance end)
  while #attention > ATTENTION_LIMIT do table.remove(attention) end

  local factory = {total = total, by_type = by_type, by_status = by_status, attention = attention,
                   miners_by_resource = miners, labs = labs, assemblers = assemblers,
                   electric_miners = electric}

  -- Small base: include the full per-machine roster (lightweight). Second pass
  -- only runs when total is small, so it's cheap.
  if total > 0 and total <= FACTORY_DETAIL_THRESHOLD then
    local roster = {}
    for _, e in ipairs(machines) do
      if e.valid then
        local entry = {name = e.name, type = e.type, status = status_string(e),
          position = {x = math.floor(e.position.x), y = math.floor(e.position.y)}}
        if e.type == "assembling-machine" or e.type == "furnace" then
          local r = e.get_recipe(); entry.recipe = r and r.name or nil
        end
        roster[#roster + 1] = entry
      end
    end
    factory.machines = roster
  end

  return factory, needs
end

-- -------------------------------------------------------------------------
-- Per-entity description — the standard perception entry for ONE entity.
-- Shared by the gather() nearby scan and external queries (AIQueries
-- inspect_entity), so an MCP client inspecting an entity sees EXACTLY what
-- the autonomous router sees.
-- -------------------------------------------------------------------------
function AIPerception.describe_entity(e, force)
  local entry = {
    name        = e.name,
    type        = e.type,
    position    = {x = math.floor(e.position.x), y = math.floor(e.position.y)},
    unit_number = e.unit_number,
    is_enemy    = is_enemy(e, force),
    slots       = entity_slots(e.name),
  }

  -- Status for machines
  if e.status then
    entry.status = status_string(e)
  end

  -- Recipe for crafting machines
  if e.type == "assembling-machine" or e.type == "furnace" then
    local recipe = e.get_recipe()
    entry.recipe = recipe and recipe.name or nil
    entry.fuel   = get_fuel_contents(e)
    entry.input  = get_input_contents(e)
    entry.output = get_output_contents(e)
  end

  -- Fuel for burner miners
  if e.type == "mining-drill" and e.burner then
    entry.fuel = get_fuel_contents(e)
    entry.drop_position = e.drop_position
  end

  -- Contents for containers
  if e.type == "container" or e.type == "logistic-container" then
    local chest_inv = e.get_inventory(defines.inventory.chest)
    entry.contents = summarize_inventory(chest_inv, 5)
  end

  -- Lab science pack contents
  if e.type == "lab" then
    local lab_inv = e.get_inventory(defines.inventory.lab_input)
    entry.contents = summarize_inventory(lab_inv, 5)
  end

  -- Turret ammo
  if e.type == "ammo-turret" then
    local ammo_inv = e.get_inventory(defines.inventory.turret_ammo)
    entry.contents = summarize_inventory(ammo_inv, 3)
  end

  -- Fluid connection points (pipe routing for the power chain & fluid recipes)
  if FLUID_CONN_TYPES[e.type] then
    entry.fluid_connections = get_fluid_connections(e)
  end

  return entry
end

-- -------------------------------------------------------------------------
-- Main perception gather
-- -------------------------------------------------------------------------

-- Nearest water and nearest patch of each resource well beyond vision, so the
-- AI knows where to walk at the start. Expanding rings, cached per surface and
-- rescanned only after the character moves LANDMARK_MOVE tiles or the cache is
-- LANDMARK_TTL ticks old (big searches are too slow to run every request).
local LANDMARK_RINGS = {48, 112, 224}
local LANDMARK_MOVE  = 32
local LANDMARK_TTL   = 60 * 60 * 5

local function closest(list, pos, get_pos)
  local best, best_d
  for _, it in ipairs(list) do
    local p = get_pos(it)
    local dx, dy = p.x - pos.x, p.y - pos.y
    local d = dx * dx + dy * dy
    if not best_d or d < best_d then best, best_d = p, d end
  end
  if not best then return nil end
  return {x = math.floor(best.x), y = math.floor(best.y), distance = math.floor(math.sqrt(best_d))}
end

local function scan_landmarks(surface, pos)
  local out = {resources = {}}
  for _, r in ipairs(LANDMARK_RINGS) do
    local tiles = surface.find_tiles_filtered{
      collision_mask = "water_tile",
      area  = {{pos.x - r, pos.y - r}, {pos.x + r, pos.y + r}},
      limit = 300,
    }
    out.water = closest(tiles, pos, function(t) return t.position end)
    if out.water then break end
  end
  local names = prototypes.get_entity_filtered{{filter = "type", type = "resource"}}
  for name in pairs(names) do
    for _, r in ipairs(LANDMARK_RINGS) do
      local ents = surface.find_entities_filtered{name = name, position = pos, radius = r, limit = 200}
      local c = closest(ents, pos, function(e) return e.position end)
      if c then
        c.name = name
        table.insert(out.resources, c)
        break
      end
    end
  end
  table.sort(out.resources, function(a, b) return a.distance < b.distance end)
  return out
end

function AIPerception.landmarks(surface, pos)
  local st = storage.ai_player
  st.landmarks = st.landmarks or {}
  local c = st.landmarks[surface.index]
  if c then
    local dx, dy = pos.x - c.x, pos.y - c.y
    if dx * dx + dy * dy < LANDMARK_MOVE * LANDMARK_MOVE and game.tick - c.tick < LANDMARK_TTL then
      return c.data
    end
  end
  local data = scan_landmarks(surface, pos)
  st.landmarks[surface.index] = {x = pos.x, y = pos.y, tick = game.tick, data = data}
  return data
end

local THREAT_RADIUS = 200

function AIPerception.gather(character)
  local surface = character.surface
  local pos = character.position
  local force = character.force
  local radius = settings.global["ai-player-vision-radius"].value

  local perception = {}

  -- Which planet/surface the AI is on (Space Age: nauvis, vulcanus, fulgora,
  -- gleba, aquilo, or a space platform). Home, factory and nearby_* are all
  -- for this surface only.
  perception.surface = {
    name   = surface.name,
    planet = surface.planet and surface.planet.name or nil,
    is_platform = surface.platform ~= nil,
  }

  -- Character state
  perception.character = {
    position  = {x = math.floor(pos.x), y = math.floor(pos.y)},
    health    = math.floor(character.health),
    health_pct= math.floor((character.health / (character.max_health or 250)) * 100),
    direction = character.direction,
    is_mining = character.mining_state and character.mining_state.mining or false,
    is_walking= character.walking_state and character.walking_state.walking or false,
  }

  -- Home/base anchor + how far the character has wandered from it.
  local home = AICharacter.get_home()
  if home then
    local dx, dy = pos.x - home.x, pos.y - home.y
    perception.home = {
      position = {x = home.x, y = home.y},
      distance = math.floor(math.sqrt(dx * dx + dy * dy)),
    }
  end

  -- Character inventory — show the FULL inventory (high limit). Truncating to
  -- the top-N by count hid low-count buildables (e.g. 4 burner-mining-drill),
  -- so the model thought it had 0 and never placed them.
  local char_inv = character.get_inventory(defines.inventory.character_main)
  perception.inventory = summarize_inventory(char_inv, 100)

  -- What can be crafted right now
  -- Useful early items first, then the rest in prototype order, so the 25-name
  -- cap doesn't hide the things the AI actually needs.
  local craftable, seen = {}, {}
  local function try(name)
    if #craftable >= 25 or seen[name] then return end
    seen[name] = true
    local recipe = force.recipes[name]
    if recipe and recipe.enabled and not recipe.hidden
       and character.get_craftable_count(name) > 0 then
      craftable[#craftable + 1] = name
    end
  end
  for _, name in ipairs(CRAFT_PRIORITY) do try(name) end
  for name in pairs(force.recipes) do
    if #craftable >= 25 then break end
    try(name)
  end
  perception.craftable = craftable

  -- Nearby entities (up to 25). Fill NEAREST-FIRST (not raw find order) so the
  -- 25-cap keeps the closest entities — the ones relevant to where the character
  -- is acting — instead of an arbitrary slice that belts/poles could crowd out.
  local raw_entities = surface.find_entities_filtered{
    position = pos,
    radius = radius
  }
  table.sort(raw_entities, function(a, b)
    local dax, day = a.position.x - pos.x, a.position.y - pos.y
    local dbx, dby = b.position.x - pos.x, b.position.y - pos.y
    return (dax * dax + day * day) < (dbx * dbx + dby * dby)
  end)

  local nearby = {}
  for _, e in ipairs(raw_entities) do
    if e.valid and e ~= character then
      table.insert(nearby, AIPerception.describe_entity(e, force))
      if #nearby >= 25 then break end
    end
  end
  perception.nearby_entities = nearby

  -- Nearby resources grouped by type
  local raw_resources = surface.find_entities_filtered{
    type = "resource",
    position = pos,
    radius = radius
  }
  local resource_groups = {}
  for _, r in ipairs(raw_resources) do
    if r.valid then
      local name = r.name
      if not resource_groups[name] then
        resource_groups[name] = {name=name, patch_count=0, total_amount=0, nearest=nil, nearest_dist=math.huge}
      end
      local g = resource_groups[name]
      g.patch_count = g.patch_count + 1
      g.total_amount = g.total_amount + (r.amount or 0)
      local dx = r.position.x - pos.x
      local dy = r.position.y - pos.y
      local dist = math.sqrt(dx*dx + dy*dy)
      if dist < g.nearest_dist then
        g.nearest_dist = dist
        g.nearest = {x = math.floor(r.position.x), y = math.floor(r.position.y)}
        g.nearest_distance = math.floor(dist)
      end
    end
  end
  local resources = {}
  for _, g in pairs(resource_groups) do
    g.nearest_dist = nil  -- remove internal field before serialising
    table.insert(resources, g)
  end
  perception.nearby_resources = resources

  -- Enemies
  local enemy_entities = surface.find_entities_filtered{
    position = pos,
    radius = radius,
    force = "enemy"
  }
  local enemies = {}
  for _, e in ipairs(enemy_entities) do
    if e.valid then
      local dx = e.position.x - pos.x
      local dy = e.position.y - pos.y
      table.insert(enemies, {
        name     = e.name,
        type     = e.type,
        position = {x = math.floor(e.position.x), y = math.floor(e.position.y)},
        distance = math.floor(math.sqrt(dx*dx + dy*dy)),
      })
      if #enemies >= 10 then break end
    end
  end
  table.sort(enemies, function(a,b) return a.distance < b.distance end)
  perception.enemies = enemies

  -- Threat to the base: the nearest enemy nest or worm within THREAT_RADIUS of home, and
  -- the latest attack on something the AI owns (control.lua on_entity_damaged).
  local home = AICharacter.get_home(surface) or pos
  -- the 200-tile search is cached for 10 s
  local cache = storage.ai_player and storage.ai_player.threat_cache
  local nest, nd
  if cache and cache.surface == surface.index and game.tick - cache.tick < 600 then
    nest, nd = cache.nest, cache.nd
  else
    for _, e in ipairs(surface.find_entities_filtered{position = home, radius = THREAT_RADIUS, force = "enemy",
                                                      type = {"unit-spawner", "turret"}}) do
      local d = math.sqrt((e.position.x - home.x) ^ 2 + (e.position.y - home.y) ^ 2)
      if not nd or d < nd then nest, nd = {name = e.name, position = {x = e.position.x, y = e.position.y}}, d end
    end
    if storage.ai_player then
      storage.ai_player.threat_cache = {surface = surface.index, tick = game.tick, nest = nest, nd = nd}
    end
  end
  local atk = storage.ai_player and storage.ai_player.last_attack
  perception.threat = {
    nearest = nest and {name = nest.name, x = math.floor(nest.position.x), y = math.floor(nest.position.y),
                        distance = math.floor(nd)} or nil,
    attack = atk and game.tick - atk.tick < 3600
      and {name = atk.name, x = atk.x, y = atk.y, seconds_ago = math.floor((game.tick - atk.tick) / 60)} or nil,
  }

  -- Nearby water tiles (for offshore pump placement). The "water_tile"
  -- collision layer covers every planet's water, unlike a list of tile names.
  local px, py = math.floor(pos.x), math.floor(pos.y)
  local water_tiles = surface.find_tiles_filtered{
    collision_mask = "water_tile",
    area   = {{px - 15, py - 15}, {px + 15, py + 15}},
    limit  = 5,
  }
  local water = {}
  for _, t in ipairs(water_tiles) do
    table.insert(water, {x = math.floor(t.position.x), y = math.floor(t.position.y)})
  end
  perception.nearby_water = water
  perception.landmarks = AIPerception.landmarks(surface, pos)

  -- Environment
  perception.environment = {
    surface       = surface.name,
    ticks_played  = game.tick,
    daytime       = surface.daytime,
    peaceful_mode = surface.peaceful_mode,
    pollution     = surface.get_pollution(pos),
  }

  -- Game phase (0–5)
  perception.game_phase = detect_game_phase(force)

  -- Research state — nothing progresses unless a tech is queued (use the
  -- research skill). current = nil means NO research is queued.
  local cur = force.current_research
  perception.research = {
    current  = cur and cur.name or nil,
    progress = cur and force.research_progress or 0,
  }
  -- Techs unlocked by DOING something (2.x early game: craft a lab, mine coal...)
  -- rather than by research. Only those whose prerequisites are done.
  local triggers = {}
  for _, t in pairs(force.technologies) do
    if #triggers >= 5 then break end
    if t.enabled and not t.researched then
      local info = AISkills.trigger_info(t)
      if info and info.type ~= "scripted" and info.type ~= "create-space-platform"
         and info.type ~= "send-item-to-orbit" then
        local ready = true
        for _, pre in pairs(t.prerequisites) do
          if not pre.researched then ready = false; break end
        end
        if ready then triggers[#triggers + 1] = info end
      end
    end
  end
  perception.research.triggers = triggers
  -- The queue order the reflexes use when nothing is being researched (the planner reads it).
  local order = {}
  for _, e in ipairs(AISkills.RESEARCH_ORDER) do order[#order + 1] = {tech = e[1], green = e[2]} end
  perception.research.order = order
  -- What the reflexes are doing (fighting / retreating cancels the turn with reason "combat").
  perception.reflex = AIReflexes.status()

  -- Whole-base machine view (scale-aware) + factory-wide maintenance needs.
  -- factory.summary scales to hundreds of machines (aggregate counts +
  -- nearest-first exceptions); factory.machines is the per-machine roster while
  -- the base is small. needs is the same data bucketed for skill routing.
  local factory, needs = gather_factory(surface, force, pos)
  perception.factory = factory
  perception.needs = needs
  perception.power = compute_power(surface, force, factory.by_status)
  perception.production = compute_production(force, surface)

  local done = {}
  for _, n in ipairs(KEY_TECHS) do
    local t = force.technologies[n]
    if t and t.researched then done[#done + 1] = n end
  end
  perception.research.done = done

  -- Blueprints the AI placed on this surface (newest last), and what the
  -- library holds, so the bridge's goal ladder can tell what's already down.
  local placed = {}
  for _, b in ipairs(storage.ai_player.placed_blueprints or {}) do
    if b.surface == surface.name then
      placed[#placed + 1] = {name = b.name, position = b.position}
    end
  end
  while #placed > 15 do table.remove(placed, 1) end
  perception.placed_blueprints = placed

  local conns = {}
  for _, c in ipairs(storage.ai_player.connected_belts or {}) do
    conns[#conns + 1] = {from = c.from, to = c.to}
  end
  perception.connected_belts = conns

  local pipes = {}
  for _, c in ipairs(storage.ai_player.connected_pipes or {}) do
    pipes[#pipes + 1] = {from = c.from, to = c.to}
  end
  perception.connected_pipes = pipes
  -- blueprint_library: blueprints whose every building is unlocked for this
  -- force. blueprint_locked: the rest, with up to 3 items still locked (the
  -- bridge turns those into research hints and keeps both out of the raw
  -- game-state JSON in the prompt).
  local names, locked = {}, {}
  for name, e in pairs(storage.ai_player.blueprints or {}) do
    local missing = {}
    for _, item in ipairs((e.meta and e.meta.items) or {}) do
      local r = force.recipes[item]
      if r and not r.enabled then
        missing[#missing + 1] = item
        if #missing >= 3 then break end
      end
    end
    if #missing == 0 then names[#names + 1] = name else locked[name] = missing end
  end
  table.sort(names)
  perception.blueprint_library = names
  perception.blueprint_locked = locked

  -- Human-placed entity-ghosts = explicit build intent (build_ghosts skill).
  -- Search the ENTIRE surface: ghosts can be far from the character (e.g. an oil
  -- outpost the human blueprinted 200+ tiles away). build_ghosts teleports there.
  local ghost_entities = surface.find_entities_filtered{type = "entity-ghost"}
  local ghost_list = {}
  for _, g in ipairs(ghost_entities) do
    if g.valid and #ghost_list < 25 then
      local proto = prototypes.entity[g.ghost_name]
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
        and proto.items_to_place_this[1].name
      table.insert(ghost_list, {
        ghost_name = g.ghost_name,
        position   = {x = math.floor(g.position.x), y = math.floor(g.position.y)},
        have_item  = (item and char_inv and char_inv.get_item_count(item) > 0) or false,
      })
    end
  end
  perception.ghosts = {count = #ghost_entities, list = ghost_list}

  -- Human-marked deconstruction = explicit "remove this" intent (deconstruct
  -- skill). Second-highest priority after ghosts. Mirrors the ghost block.
  local decon_entities = surface.find_entities_filtered{to_be_deconstructed = true}
  local decon_list = {}
  for _, m in ipairs(decon_entities) do
    if m.valid and #decon_list < 25 then
      table.insert(decon_list, {
        name     = m.name,
        position = {x = math.floor(m.position.x), y = math.floor(m.position.y)},
        minable  = m.minable,
      })
    end
  end
  perception.deconstruction = {count = #decon_entities, list = decon_list}

  return perception
end

-- -------------------------------------------------------------------------
-- Compact situation snapshot for external (MCP/harness) callers. Reuses the
-- SAME registry-backed machine view the autonomous router sees (gather_factory),
-- but skips the heavy nearby-entity/resource/water scans — a harness wants the
-- factory picture + maintenance needs to decide its next skill, not the full
-- 25-entity local detail. JSON-serialisable.
-- -------------------------------------------------------------------------
function AIPerception.factory_state(character)
  local surface = character.surface
  local pos     = character.position
  local force   = character.force

  local factory, needs = gather_factory(surface, force, pos)

  -- The router consumes the per-machine `needs` lists; a harness only needs the
  -- counts to gauge how much maintenance is pending (it can act via fuel_all etc).
  local needs_counts = {}
  for bucket, list in pairs(needs) do needs_counts[bucket] = #list end

  local home = AICharacter.get_home()
  local home_distance = nil
  if home then
    local dx, dy = pos.x - home.x, pos.y - home.y
    home_distance = math.floor(math.sqrt(dx * dx + dy * dy))
  end

  local cur = force.current_research
  local char_inv = character.get_inventory(defines.inventory.character_main)

  return {
    tick       = game.tick,
    game_phase = detect_game_phase(force),
    coop       = (storage.ai_player and storage.ai_player.force_name) == "player",
    autonomy   = (storage.ai_player and storage.ai_player.autonomy_enabled) ~= false,
    power      = compute_power(surface, force, factory.by_status),
    character  = {
      position      = {x = math.floor(pos.x), y = math.floor(pos.y)},
      health_pct    = math.floor((character.health / (character.max_health or 250)) * 100),
      home_distance = home_distance,
    },
    inventory  = summarize_inventory(char_inv, 100),
    research   = {
      current  = cur and cur.name or nil,
      progress = cur and round1(force.research_progress * 100) or 0,
    },
    factory    = factory,        -- total, by_type, by_status, attention[, machines roster if small]
    production = compute_production(force, surface),
    needs      = needs_counts,   -- bucket -> count of machines needing that action
    ghosts          = surface.count_entities_filtered{type = "entity-ghost"},
    deconstruction  = surface.count_entities_filtered{to_be_deconstructed = true},
  }
end

return AIPerception
