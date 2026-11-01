-- Self-test cases for the reflexes (reflexes.lua), registered into selftest.lua's CASES.
--
-- `reflexes = true` hands the scene's character to the mod as THE AI
-- (storage.ai_player.character) and switches the reflexes on for the case; every other case
-- runs with them off so it stays deterministic. Armed self-test maps only (see selftest.lua).

local CASES = AISelftest.CASES
local give = AISelftest.helpers.give

local function biters(c, name, n, cx, cy)
  local out = {}
  for i = 1, n do
    local b = c.surface.create_entity{name = name, position = {cx + (i % 3), cy + math.floor(i / 3)}, force = "enemy"}
    if b then out[#out + 1] = b end
  end
  return out
end

local function alive_count(list)
  local n = 0
  for _, e in ipairs(list or {}) do if e.valid then n = n + 1 end end
  return n
end

local mags_of = AISelftest.rounds_of            -- rounds, not magazines: see selftest.lua

local function reflex_state() return storage.ai_player.reflex and storage.ai_player.reflex.state or "idle" end

-- Biters 15 tiles from the AI: they die, the magazines go down, the AI lives and the fight ends.
CASES.guard = {
  reflexes = true,
  delay = 1500,
  setup = function(c)
    c.ammo0 = mags_of(c.character)
    c.bs = biters(c, "small-biter", 6, 15, 0)
  end,
  run = function() return {} end,
  pulse = function(c) if reflex_state() == "fighting" then c.fought = true end end,
  check = function(c, add)
    add("the reflex went fighting", c.fought == true)
    add("every biter died", alive_count(c.bs) == 0, alive_count(c.bs) .. " left")
    add("rounds went down", mags_of(c.character) < c.ammo0, c.ammo0 .. " -> " .. mags_of(c.character))
    add("the AI lives", c.character.valid and c.character.health > 0)
    add("the fight ended (state idle)", reflex_state() == "idle", reflex_state())
  end,
}

-- A stand-in "player" 45 tiles off is attacked: the AI goes there and kills the biters.
CASES.protect = {
  reflexes = true,
  delay = 1500,
  setup = function(c)
    c.friend = c.surface.create_entity{name = "character", position = {45.5, 0.5}, force = c.force}
    storage.selftest.protectee = c.friend
    c.bs = biters(c, "small-biter", 3, 48, 2)
    c.max_x = 0
  end,
  run = function() return {} end,
  pulse = function(c)
    if c.character.valid then c.max_x = math.max(c.max_x, c.character.position.x) end
  end,
  check = function(c, add)
    add("the AI went to the stand-in", c.max_x > 20, c.max_x)
    add("every biter died", alive_count(c.bs) == 0, alive_count(c.bs) .. " left")
    add("the stand-in lives", c.friend.valid and c.friend.health > 0, c.friend.valid and c.friend.health or "dead")
    add("the AI lives", c.character.valid and c.character.health > 0)
  end,
}

-- Hurt (30%) and away from home with biters near: the AI ends up at home, alive.
CASES.retreat = {
  reflexes = true,
  delay = 1200,
  setup = function(c)
    c.character.teleport({30.5, 0.5})
    c.character.health = 75
    c.bs = biters(c, "small-biter", 4, 36, 0)
  end,
  run = function() return {} end,
  pulse = function(c)
    local p = c.character.valid and c.character.position
    if p and reflex_state() == "retreating" and math.abs(p.x) < 12 and math.abs(p.y) < 12 then c.went_home = true end
  end,
  check = function(c, add)
    add("it retreated to home", c.went_home == true)
    add("the AI lives", c.character.valid and c.character.health > 0)
  end,
}

-- A small nest 50 tiles off: left alone in defend mode, destroyed once the mode is hunt.
CASES.hunt = {
  reflexes = true,
  delay = 4200,
  setup = function(c)
    give(c.character, {["submachine-gun"] = 1, ["firearm-magazine"] = 100})
    c.nest = c.surface.create_entity{name = "biter-spawner", position = {50, 0}, force = "enemy"}
    storage.ai_player.combat_mode = "defend"
  end,
  run = function() return {} end,
  late = function(c)
    c.left_alone = c.nest.valid
    storage.ai_player.combat_mode = "hunt"
    return {}
  end,
  late_after = 1200,
  check = function(c, add)
    add("defend mode left the nest alone", c.left_alone == true)
    add("hunt mode destroyed the nest", not c.nest.valid)
    add("the AI lives", c.character.valid and c.character.health > 0)
    add("a nest was counted as cleared", (storage.ai_player.reflex.nests_cleared or 0) >= 1,
        storage.ai_player.reflex.nests_cleared)
  end,
}

-- No turn running: a starving furnace gets coal, a finished one is emptied, a turret reloaded.
CASES.reflex_tend = {
  reflexes = true,
  delay = 800,
  setup = function(c)
    give(c.character, {["firearm-magazine"] = 30, ["submachine-gun"] = 1})      -- (no gun to craft)
    c.furnace = c.surface.create_entity{name = "stone-furnace", position = {10, 10}, force = c.force}
    c.furnace.get_inventory(defines.inventory.crafter_input).insert{name = "iron-ore", count = 20}
    c.done = c.surface.create_entity{name = "stone-furnace", position = {14, 10}, force = c.force}
    c.done.get_inventory(defines.inventory.crafter_output).insert{name = "iron-plate", count = 9}
    c.turret = c.surface.create_entity{name = "gun-turret", position = {18, 10}, force = c.force}
    c.turret.insert{name = "firearm-magazine", count = 2}
    for _, e in ipairs({c.furnace, c.done, c.turret}) do AIRegistry.own(e) end
    c.plates0 = c.character.get_inventory(defines.inventory.character_main).get_item_count("iron-plate")
  end,
  run = function() return {} end,
  check = function(c, add)
    local inv = c.character.get_inventory(defines.inventory.character_main)
    add("no turn was running", storage.ai_player.turn == nil)
    add("the furnace got coal", c.furnace.get_fuel_inventory().get_item_count("coal") > 0
        or c.furnace.status == defines.entity_status.working)
    add("the finished furnace was emptied", c.done.get_inventory(defines.inventory.crafter_output).is_empty())
    add("its plates reached the AI", inv.get_item_count("iron-plate") >= c.plates0 + 9, inv.get_item_count("iron-plate"))
    add("the turret was reloaded to 10",
        c.turret.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine") >= 10)
  end,
}

-- An empty research queue on the AI's own force gets refilled.
CASES.reflex_research = {
  reflexes = true,
  delay = 700,
  setup = function(c)
    local f = game.create_force("ai-res-" .. game.tick)
    f.research_all_technologies()
    for _, e in ipairs(AISkills.RESEARCH_ORDER) do
      local t = f.technologies[e[1]]
      if t then t.researched = false end
    end
    local ch = c.surface.create_entity{name = "character", position = {0.5, 0.5}, force = f}
    AICharacter.give_starting_items(ch)
    c.character, c.res_force = ch, f
    c.queue0 = f.current_research
  end,
  run = function() return {} end,
  check = function(c, add)
    add("the queue started empty", c.queue0 == nil)
    add("a tech is being researched now", c.res_force.current_research ~= nil,
        c.res_force.current_research and c.res_force.current_research.name)
  end,
}

-- Medium biters camp the spawn and the AI is killed twice: each respawn waits longer than
-- the last and comes up away from the enemies, and the deaths stay few. (Left to itself the AI
-- flees the mediums; killing it by script is the repeatable way to test the respawn.)
CASES.death_backoff = {
  reflexes = true,
  delay = 9600,
  setup = function(c)
    c.mediums = biters(c, "medium-biter", 8, 3, 0)
    c.spawns = {}
  end,
  run = function() return {} end,
  pulse = function(c)
    local ch = storage.ai_player.character
    if not c.killed1 then c.killed1 = true; c.character.die(); return end
    if ch and ch.valid and ch ~= c.character and ch ~= c.last_new then
      c.last_new = ch
      local near = 60
      for _, e in ipairs(ch.surface.find_entities_filtered{position = ch.position, radius = 60, force = "enemy",
                                                          type = {"unit", "turret", "unit-spawner"}}) do
        near = math.min(near, math.sqrt((e.position.x - ch.position.x) ^ 2 + (e.position.y - ch.position.y) ^ 2))
      end
      local rf = storage.ai_player.reflex
      c.spawns[#c.spawns + 1] = {wait = game.tick - (rf.last_death_tick or game.tick), enemy_dist = near}
      if #c.spawns == 1 then ch.die() end
    end
  end,
  check = function(c, add)
    local rf = storage.ai_player.reflex or {}
    add("it died and respawned twice", #c.spawns >= 2, #c.spawns)
    add("the first respawn waited about 30 s", c.spawns[1] ~= nil and c.spawns[1].wait >= 1700, c.spawns[1] and c.spawns[1].wait)
    add("the second respawn waited about 60 s", c.spawns[2] ~= nil and c.spawns[2].wait >= 3500, c.spawns[2] and c.spawns[2].wait)
    add("the respawns were away from the enemies", c.spawns[1] ~= nil and c.spawns[1].enemy_dist >= 38
        and c.spawns[2] ~= nil and c.spawns[2].enemy_dist >= 38,
        c.spawns[1] and c.spawns[1].enemy_dist)
    add("no more than 3 deaths", (rf.deaths or 0) <= 3, rf.deaths)
  end,
}

-- Small biters keep coming (one more every half second): the fight is dropped at the cap and
-- the chat order given during it still goes out.
CASES.hold_cap = {
  reflexes = true,
  keep_fast = true,                    -- the decision that follows the fight must not be parked
  delay = 2400,
  setup = function(c)
    storage.selftest.fight_max = 600
    c.spawned = 0
  end,
  run = function() return {} end,
  pulse = function(c)
    local ap = storage.ai_player
    local ch = ap.character
    if not (ch and ch.valid) then return end
    if not c.ended then
      c.surface.create_entity{name = "small-biter", position = {14 + c.spawned % 3, c.spawned % 5}, force = "enemy"}
      c.spawned = c.spawned + 1
    end
    if reflex_state() == "fighting" and not c.fight_tick then c.fight_tick = game.tick end
    if c.fight_tick and not c.ordered then
      c.ordered = true
      AIBrain.request_decision(ch, "test order")
    end
    if c.fight_tick and not c.ended and not AIReflexes.in_combat() then c.ended = game.tick end
    for _, req in pairs(ap.pending_requests) do
      if req.user_message == "test order" then c.order_ran = true end
    end
  end,
  check = function(c, add)
    add("a fight began", c.fight_tick ~= nil)
    add("it ended within the cap", c.ended ~= nil and c.ended - c.fight_tick <= 900,
        c.ended and (c.ended - c.fight_tick) or "never")
    add("the chat order went out", c.order_ran == true)
    add("the AI lives", c.character.valid and c.character.health > 0)
  end,
}

-- A player 100 tiles away is attacked: too far to protect, the AI stays where it is.
CASES.far_player = {
  reflexes = true,
  delay = 900,
  setup = function(c)
    c.friend = c.surface.create_entity{name = "character", position = {100.5, 0.5}, force = c.force}
    storage.selftest.protectee = c.friend
    c.bs = biters(c, "small-biter", 4, 103, 2)
    c.max_x = 0
  end,
  run = function() return {} end,
  pulse = function(c)
    if c.character.valid then c.max_x = math.max(c.max_x, c.character.position.x) end
  end,
  check = function(c, add)
    add("the AI did not go", c.max_x < 20, c.max_x)
    add("the AI lives", c.character.valid and c.character.health > 0)
  end,
}

return CASES
