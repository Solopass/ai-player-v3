-- Headless self-test harness: /ai-selftest <case>[:<facing>] <run-id>
--
-- Builds a throwaway lab-tile surface, paints a test scene (ore, water), spawns
-- an AI character, runs the skill under test through AISkills.run, waits, then
-- checks what actually got built and writes the verdict to
-- script-output/ai-player/selftest.json. Driven by tests/ingame/run_selftest.py.
--
-- Safety: refuses to run unless the map was created with SELFTEST_SEED (the
-- runner passes --map-gen-seed), so it can never touch a real save.

AISelftest = {}

local SEED = 424242
local OUT = "ai-player/selftest.json"
local FACINGS = {"north", "east", "south", "west"}
local STEP = {north = {0, -1}, east = {1, 0}, south = {0, 1}, west = {-1, 0}}

local function armed()
  local s = game.surfaces["nauvis"]
  -- The runner's map has the fixed seed and never a player; any real save has one.
  return s ~= nil and s.map_gen_settings.seed == SEED and #game.players == 0
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
  if st.late_tick and game.tick >= st.late_tick then
    local ok, err = pcall(run_late, st)
    if not ok then return finish({ok = false, case = st.case, run_id = st.run_id, detail = "late phase: " .. tostring(err)}) end
  end
  if st.check_tick and game.tick >= st.check_tick then conclude() end
end)

commands.add_command("ai-selftest", "Run an in-game self-test case (self-test maps only)", function(cmd)
  if cmd.player_index then
    local p = game.get_player(cmd.player_index)
    if not (p and p.admin) then return end
  end
  AISelftest.start(cmd.parameter)
end)

return AISelftest
