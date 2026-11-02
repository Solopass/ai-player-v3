-- Reflexes: the AI keeps itself and the base alive without the bridge.
--
-- Three layers play together: reflexes (this file, always on, every 15 ticks, no bridge
-- needed), the autopilot planner (bridge, builds things) and the LLM (strategy, chat
-- orders). Priority: survive > fight > keep the base running.
--
--   guard   shoot enemies near the AI, near every connected player ("protect the human") and
--           near anything the AI owns that was just attacked; gun and ammo kept in the slots,
--           magazines crafted when low, raw fish eaten when hurt; retreat home when badly hurt
--   hunt    opt-in (setting ai-player-combat-mode or chat "ai: hunt"): clear nests near home
--   tend    light upkeep of the owned machines (fuel, outputs, turret ammo), no teleports
--   science queue the next tech when nothing is being researched
--
-- While fighting or retreating the reflex owns the character: the running turn is cancelled
-- ("combat"), new decision requests are not sent and a turn that arrives is held until the
-- fight is over (AIReflexes.in_combat() is checked in brain.lua / skills.lua).
--
-- All state is in storage.ai_player.reflex (plain data, never entity references).
-- NB: script.on_nth_tick(n) replaces any other handler for the same n. In use elsewhere:
-- 60 in gui.lua, 30 and 1800 in selftest.lua.

AIReflexes = {}

local PERIOD = 15                  -- ticks between passes
local CALM_TICKS = 300             -- 5 s without enemies before turns resume
local SCAN = 22                    -- gun range + 4: how far around a centre enemies are looked for
local RETREAT_HP, HEAL_HP, RESUME_HP = 0.35, 0.60, 0.80
local RANGE = {pistol = 15, ["submachine-gun"] = 18}
local GUNS = {"submachine-gun", "pistol"}                  -- best first
local AMMO = {"piercing-rounds-magazine", "firearm-magazine"}
local MAG_LOW, MAG_HUNT = 20, 100
local HUNT_RADIUS, HUNT_STAGE, HUNT_NEST_SCAN = 120, 20, 40
local HUNT_MAX_TICKS, HUNT_COOLDOWN, SKIP_TICKS = 10800, 1800, 36000
local HUNT_IRON_RESERVE = 100      -- iron kept for building while crafting hunt ammo
local TEND_EVERY, TEND_CAP = 300, 30
local SHARED_RESEARCH_WAIT = 7200  -- 2 min of an empty queue before touching the player's force
local OFFLINE_TICKS = 3600         -- no bridge reply for 60 s
local FISH_HEAL = 80
local FIGHT_MAX, QUIET_TICKS = 9000, 1800   -- any fight that drags on (2.5 min) is dropped for 30 s
local ORDER_WAIT = 1800                        -- a chat order waits at most 30 s for a fight to end
local PROTECT_RADIUS, ATTACK_RADIUS, HOP_MAX = 64, 100, 30   -- who is protected; longest combat hop
local DEATH_DELAYS, DEATH_RESET, SAFE_TICKS = {1800, 3600, 7200, 18000}, 18000, 3600

-- (self-tests shorten the caps)
local function fight_max() return storage.selftest and storage.selftest.fight_max or FIGHT_MAX end
local function order_wait() return storage.selftest and storage.selftest.order_wait or ORDER_WAIT end

local function setting(name)
  local s = settings.global[name]
  return s and s.value
end

local function R()
  local ap = storage.ai_player
  local r = ap.reflex
  if not r then
    r = {state = "idle", since = game.tick, deaths = 0, nests_cleared = 0, hunts_done = 0,
         skip = {}, nest_deaths = {}}
    ap.reflex = r
  end
  return r
end

local function dist(a, b)
  return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

local function skip_key(x, y) return math.floor(x) .. "," .. math.floor(y) end

local function hp_ratio(ch)
  return ch.health / (ch.max_health or 250)
end

local function main_inv(ch) return ch.get_inventory(defines.inventory.character_main) end

local function set_state(r, state, target)
  if r.state ~= state then
    if r.state == "idle" then r.engaged_since = game.tick elseif state == "idle" then r.engaged_since = nil end
    r.state, r.since = state, game.tick
    AIDebug.event("reflex", {name = state, detail = target})
  end
  r.target = target
end

-- True while the reflexes own the character (checked by brain.lua and skills.lua).
function AIReflexes.in_combat()
  local r = storage.ai_player and storage.ai_player.reflex
  return r ~= nil and (r.state == "fighting" or r.state == "retreating")
end

function AIReflexes.mode()
  local ap = storage.ai_player
  return (ap and ap.combat_mode) or setting("ai-player-combat-mode") or "defend"
end

function AIReflexes.set_mode(mode)
  storage.ai_player.combat_mode = mode
  if mode ~= "hunt" then R().hunt = nil end
  game.print("[AI] Combat mode: " .. mode .. (mode == "hunt" and " — will clear nests near home when armed" or
    " — defends itself, you and the base"), {r = 0.5, g = 0.9, b = 1})
end

-- True once the bridge has gone quiet (shown on the panel): a request has sat unanswered for
-- a minute. (A slow model answers in seconds; a dead or stuck bridge never does.)
function AIReflexes.bridge_offline()
  local ap = storage.ai_player
  if not ap then return false end
  for _, req in pairs(ap.pending_requests or {}) do
    if game.tick - req.timestamp > OFFLINE_TICKS then return true end
  end
  return false
end

-- Compact status for perception and the panel.
function AIReflexes.status()
  local ap = storage.ai_player
  local r = ap and ap.reflex
  local on = setting("ai-player-reflexes") ~= false
  if not r then return {state = "idle", mode = AIReflexes.mode(), enabled = on} end
  local state = r.state
  if state == "idle" and r.last_tend and game.tick - r.last_tend.tick < 120 then state = "tending" end
  return {state = state, target = r.target, seconds = math.floor((game.tick - (r.since or game.tick)) / 60),
          mode = AIReflexes.mode(), enabled = on, deaths = r.deaths, nests_cleared = r.nests_cleared,
          bridge_offline = r.bridge_offline or false}
end

-- -------------------------------------------------------------------------
-- Gear: gun, ammo, magazines, healing
-- -------------------------------------------------------------------------

local function count_ammo(ch)
  local main, ammo = main_inv(ch), ch.get_inventory(defines.inventory.character_ammo)
  local n = 0
  for _, name in ipairs(AMMO) do n = n + main.get_item_count(name) + (ammo and ammo.get_item_count(name) or 0) end
  return n
end

-- Put `item` in slot 1 of `slot_inv` (the old stack goes back to the main inventory), and top
-- an ammo stack up from the main inventory.
local function fill_slot(slot_inv, main, item, top_up)
  local s = slot_inv[1]
  if not (s.valid_for_read and s.name == item) then
    if s.valid_for_read then
      if not main.can_insert(s) then return end
      main.insert(s); s.clear()
    end
    local n = math.min(main.get_item_count(item), top_up and prototypes.item[item].stack_size or 1)
    if n > 0 then s.set_stack{name = item, count = n}; main.remove{name = item, count = n} end
  elseif top_up then
    local add = math.min(main.get_item_count(item), prototypes.item[item].stack_size - s.count)
    if add > 0 then s.count = s.count + add; main.remove{name = item, count = add} end
  end
end

-- Best gun and ammo in slot 1; returns the gun's range, or nil when it can't shoot.
local function arm(ch)
  local main = main_inv(ch)
  local guns, ammo = ch.get_inventory(defines.inventory.character_guns), ch.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then return nil end
  for _, g in ipairs(GUNS) do
    if main.get_item_count(g) > 0 or (guns[1].valid_for_read and guns[1].name == g) then
      fill_slot(guns, main, g, false)
      break
    end
  end
  for _, a in ipairs(AMMO) do
    if main.get_item_count(a) > 0 or ammo.get_item_count(a) > 0 then
      fill_slot(ammo, main, a, true)
      break
    end
  end
  ch.selected_gun_index = 1
  if not (guns[1].valid_for_read and ammo[1].valid_for_read) then return nil end
  return RANGE[guns[1].name] or 15
end

-- Craft magazines (and the submachine gun) when short, only between turns.
local function restock(ch, r, hunting)
  local ap = storage.ai_player
  if ap.turn or ch.crafting_queue_size > 0 then return end
  local main = main_inv(ch)
  local have = count_ammo(ch)
  local goal = hunting and MAG_HUNT or MAG_LOW
  local red_recipe = ch.force.recipes["piercing-rounds-magazine"]
  if have < goal and red_recipe and red_recipe.enabled then
    local craftable = ch.get_craftable_count(red_recipe)
    if craftable > 0 then
      local n = math.min(10, goal - have, craftable)
      if n >= 1 then ch.begin_crafting{recipe = "piercing-rounds-magazine", count = n, silent = true}; return end
    end
  end
  local recipe = ch.force.recipes["firearm-magazine"]
  if have < goal and recipe and recipe.enabled then
    local reserve = have < MAG_LOW and 0 or HUNT_IRON_RESERVE
    local n = math.min(10, goal - have, math.floor((main.get_item_count("iron-plate") - reserve) / 4))
    if n >= 1 then ch.begin_crafting{recipe = "firearm-magazine", count = n, silent = true} end
    return
  end
  local smg = ch.force.recipes["submachine-gun"]
  if smg and smg.enabled and main.get_item_count("submachine-gun") == 0
     and ch.get_inventory(defines.inventory.character_guns).get_item_count("submachine-gun") == 0
     and ch.get_craftable_count(smg) > 0 then
    ch.begin_crafting{recipe = smg, count = 1, silent = true}
  end
end

local function heal(ch, r, tick, hp)
  if hp >= HEAL_HP or tick < (r.heal_after or 0) then return end
  local main = main_inv(ch)
  if main.get_item_count("raw-fish") > 0 then
    main.remove{name = "raw-fish", count = 1}
    ch.health = math.min(ch.max_health or 250, ch.health + FISH_HEAL)
    r.heal_after = tick + 60
  end
end

-- -------------------------------------------------------------------------
-- Scanning and picking a target
-- -------------------------------------------------------------------------

-- Centres to look around: the AI, every connected player on its surface, a spot the AI's
-- things were just attacked at, and (while hunting) the nest.
local function centers_of(ch, r, tick)
  local surface = ch.surface
  local out = {{pos = ch.position, radius = SCAN}}
  local home = AICharacter.get_home(surface) or ch.position
  -- only what is within `limit` of the AI or home is worth leaving for
  local function near(pos, limit) return dist(pos, ch.position) <= limit or dist(pos, home) <= limit end
  for _, p in pairs(game.connected_players) do
    local pc = p.character
    if pc and pc.valid and pc ~= ch and pc.surface == surface and near(pc.position, PROTECT_RADIUS) then
      out[#out + 1] = {pos = pc.position, radius = SCAN}
    end
  end
  local stand_in = storage.selftest and storage.selftest.protectee      -- self-test hook
  if stand_in and stand_in.valid and stand_in.surface == surface and near(stand_in.position, PROTECT_RADIUS) then
    out[#out + 1] = {pos = stand_in.position, radius = SCAN}
  end
  local atk = storage.ai_player.last_attack
  if atk and tick - atk.tick <= 600 and (atk.surface == nil or atk.surface == surface.index)
     and near({x = atk.x, y = atk.y}, ATTACK_RADIUS) then
    out[#out + 1] = {pos = {x = atk.x, y = atk.y}, radius = SCAN}
  end
  if r.hunt and r.hunt.staged then
    out[#out + 1] = {pos = {x = r.hunt.x, y = r.hunt.y}, radius = HUNT_NEST_SCAN, spawners = true}
  end
  return out
end

-- Enemies around the centres: units, worms, spawners, each {e, d (distance to the AI)}.
local function scan(ch, centers, r, tick)
  local seen, units, worms, spawners = {}, {}, {}, {}
  local here = ch.position
  for ci, c in ipairs(centers) do
    local types = c.spawners and {"unit", "turret", "unit-spawner"} or {"unit", "turret"}
    for _, e in ipairs(ch.surface.find_entities_filtered{position = c.pos, radius = c.radius, force = "enemy", type = types}) do
      local key = e.unit_number or (e.name .. e.position.x .. "," .. e.position.y)
      -- a worm or spawner that already outlasted a fight is left alone for a while
      local skipped = e.type ~= "unit" and (r.skip[skip_key(e.position.x, e.position.y)] or 0) > tick
      if e.valid and seen[key] and ci > 1 then seen[key].other = true end      -- also near someone to protect
      if e.valid and not seen[key] and not skipped then
        local item = {e = e, d = dist(here, e.position), other = ci > 1}
        seen[key] = item
        if e.type == "unit" then units[#units + 1] = item
        elseif e.type == "turret" then worms[#worms + 1] = item
        else spawners[#spawners + 1] = item end
      end
    end
  end
  local function by_d(a, b) return a.d < b.d end
  table.sort(units, by_d); table.sort(worms, by_d); table.sort(spawners, by_d)
  return units, worms, spawners
end

-- Nearest unit first, then worms (the small ones anywhere, bigger ones only when they are
-- already in range), then spawners (hunt only: they are only scanned for then).
local function choose(units, worms, spawners, range)
  if units[1] then return units[1] end
  for _, w in ipairs(worms) do
    if w.d <= range or w.e.name == "small-worm-turret" or w.e.name == "small-worm" then return w end
  end
  return spawners[1]
end

local function crowd(units, pos)
  local n = 0
  for _, u in ipairs(units) do if dist(u.e.position, pos) <= 20 then n = n + 1 end end
  return n
end

local function teleport_near(ch, pos)
  local spot = ch.surface.find_non_colliding_position("character", pos, 6, 0.5)
  if spot then ch.teleport(spot) end
  return spot ~= nil
end

-- Step to ~12 tiles from the target, on the side the AI came from.
local function approach(ch, target, range)
  local tp, here = target.position, ch.position
  local dx, dy = here.x - tp.x, here.y - tp.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then dx, dy, len = 1, 0, 1 end
  local keep = math.min(12, range - 3)
  local to = {x = tp.x + dx / len * keep, y = tp.y + dy / len * keep}
  local hop = dist(here, to)
  if hop > HOP_MAX then                  -- no long jumps: hop part of the way, the next pass goes on
    to = {x = here.x + (to.x - here.x) / hop * HOP_MAX, y = here.y + (to.y - here.y) / hop * HOP_MAX}
  end
  return teleport_near(ch, to)
end

-- Medium and bigger biters/spitters shrug off plain firearm magazines (1 damage a round): the
-- AI doesn't walk into those, it only fights what comes to it.
local function outgunned(ch, e)
  if e.type ~= "unit" or not (e.name:find("^medium%-") or e.name:find("^big%-") or e.name:find("^behemoth%-")) then
    return false
  end
  local slot = ch.get_inventory(defines.inventory.character_ammo)[1]
  return not (slot.valid_for_read and slot.name == "piercing-rounds-magazine")
end

-- Beside a loaded turret near home, else home, else the nearest ring spot around home: the
-- first one with no enemy within 25 tiles.
local function retreat_spot(ch)
  local surface = ch.surface
  local home = AICharacter.get_home(surface) or ch.position
  local best, bd = nil, 1e12
  for _, t in ipairs(AIRegistry.owned(surface, {"ammo-turret"})) do
    local ai = t.get_inventory(defines.inventory.turret_ammo)
    local d = dist(t.position, home)
    if ai and not ai.is_empty() and d < 60 and d < bd then best, bd = t, d end
  end
  local cands = {}
  if best then cands[1] = {x = best.position.x + 2, y = best.position.y + 2} end
  cands[#cands + 1] = home
  for rad = 30, 90, 30 do
    for k = 0, 7 do
      local a = k * math.pi / 4
      cands[#cands + 1] = {x = home.x + math.cos(a) * rad, y = home.y + math.sin(a) * rad}
    end
  end
  for _, c in ipairs(cands) do
    if AICharacter.calm_at(surface, c, 25) then return c end
  end
  return home
end

-- -------------------------------------------------------------------------
-- Fight
-- -------------------------------------------------------------------------

local function stop_shooting(ch)
  ch.shooting_state = {state = defines.shooting.not_shooting, position = ch.position}
end

local function start_fight(ch, r, label)
  if r.state == "idle" then
    r.origin = {x = ch.position.x, y = ch.position.y}
    AISkills.cancel_turn("combat")
  end
  if r.state ~= "retreating" then set_state(r, "fighting", label) else r.target = label end
end

-- Calm again: go back to where the fight began, then let the turns resume.
local function end_fight(ch, r, tick)
  stop_shooting(ch)
  if r.origin and dist(ch.position, r.origin) > 2 then teleport_near(ch, r.origin) end
  r.origin = nil
  if r.hunt then r.hunt.staged = false end         -- the next stage comes from home again
  set_state(r, "idle", nil)
  storage.ai_player.fast_decide_tick = tick + 60
end

local function label_of(t)
  return string.format("%s@%d,%d", t.e.name, math.floor(t.e.position.x), math.floor(t.e.position.y))
end

-- Drop the fight: turns, chat orders and decisions get through for a while. `permanent`:
-- the fight itself was the problem, so the nest being hunted and the worm/spawner being shot
-- (the unkillable fixed target) are skipped for 10 minutes.
local function give_up(ch, r, tick, t, permanent)
  if permanent then
    if r.hunt then r.skip[r.hunt.key] = tick + SKIP_TICKS end
    if t and t.e.valid and t.e.type ~= "unit" then r.skip[skip_key(t.e.position.x, t.e.position.y)] = tick + SKIP_TICKS end
    r.hunt, r.hunt_next = nil, tick + HUNT_COOLDOWN
  end
  r.quiet_until = tick + QUIET_TICKS
  AIDebug.event("reflex", {name = "gave up", detail = r.target})
  end_fight(ch, r, tick)
end

-- One guard pass. Returns true while the reflexes hold the character.
local function fight(ch, r, tick, hp)
  local units, worms, spawners = scan(ch, centers_of(ch, r, tick), r, tick)
  local t = choose(units, worms, spawners, 15)

  -- No fight may hold the character for ever (a spawner that keeps making units, a target out
  -- of reach), and a player's chat order never waits more than ORDER_WAIT for it.
  if r.state ~= "idle" then
    local mem = storage.ai_player.memory
    if mem.pending_order_tick and tick - mem.pending_order_tick >= order_wait() then
      give_up(ch, r, tick, t, false)
      game.print("[AI] Dropping the fight to do what you asked", {r = 0.5, g = 0.9, b = 1})
      AIBrain.request_decision(ch, nil)
      return false
    end
    if (r.engaged_since and tick - r.engaged_since > fight_max())
       or (r.hunt and tick - r.hunt.started > HUNT_MAX_TICKS) then
      give_up(ch, r, tick, t, true)
      return false
    end
  end
  if t and tick < (r.quiet_until or 0) and t.d > 8 then t = nil end

  if not t then
    if r.hunt and r.hunt.staged then              -- nothing of the nest is left
      local h = r.hunt
      r.hunts_done = r.hunts_done + 1
      if ch.surface.count_entities_filtered{position = {x = h.x, y = h.y}, radius = HUNT_NEST_SCAN, force = "enemy",
                                         type = "unit-spawner", limit = 1} == 0 then
        r.nests_cleared = r.nests_cleared + 1
        AIDebug.event("reflex", {name = "nest cleared", detail = h.key})
      end
      r.hunt, r.hunt_next = nil, tick + HUNT_COOLDOWN
    end
    if r.state ~= "idle" then
      stop_shooting(ch)
      if tick - (r.last_enemy or 0) >= CALM_TICKS and (r.state ~= "retreating" or hp >= RESUME_HP) then
        end_fight(ch, r, tick)
      end
    end
    return r.state ~= "idle"
  end

  r.last_enemy = tick
  local range = arm(ch)
  -- Survive first: badly hurt, nothing to shoot with, or a biter plain ammo can't hurt close
  -- by -> go to a calm spot (once; again every 1.5 s for the unhurtable ones, which are fast).
  local flee = false
  for _, u in ipairs(units) do
    if u.d <= SCAN then
      if outgunned(ch, u.e) then flee = true; break end
    else
      break                                  -- sorted by distance
    end
  end
  if (t.d <= SCAN or flee) and (hp < RETREAT_HP or not range or flee)
     and (r.state ~= "retreating" or (flee and tick - (r.last_flee or -999) >= 90)) then
    if r.state == "idle" then r.origin = {x = ch.position.x, y = ch.position.y}; AISkills.cancel_turn("combat") end
    if r.hunt then r.hunt.staged = false end
    stop_shooting(ch)
    teleport_near(ch, retreat_spot(ch))
    r.last_flee = tick
    set_state(r, "retreating", not range and "out of ammo" or (hp < RETREAT_HP and "low health" or "outgunned"))
    return true
  end
  start_fight(ch, r, label_of(t))
  if not range then return true end
  if r.state == "retreating" and hp >= RESUME_HP and not flee then set_state(r, "fighting", label_of(t)) end

  -- Out of reach: units come to us; worms, spawners and far-off defended spots are visited,
  -- unless the AI is hurt, just respawned (retreat-only for a minute) or the crowd there is big.
  if t.d > range - 1 and r.state == "fighting" and tick - (r.last_move or -999) >= 30
     and tick >= (r.safe_until or 0)
     and (t.e.type ~= "unit" or t.d > SCAN or t.other) and hp >= HEAL_HP and crowd(units, t.e.position) <= 12
     and not outgunned(ch, t.e) then
    if approach(ch, t.e, range) then r.last_move = tick end
  end
  ch.shooting_state = {state = defines.shooting.shooting_enemies, position = t.e.position}
  return true
end

-- -------------------------------------------------------------------------
-- Hunt
-- -------------------------------------------------------------------------

-- Nearest spawner to home within HUNT_RADIUS that is not skipped and not guarded by a worm
-- bigger than small (those outrange the SMG).
local function pick_nest(ch, r, tick)
  local surface = ch.surface
  local home = AICharacter.get_home(surface) or ch.position
  local best, bd
  for _, s in ipairs(surface.find_entities_filtered{position = home, radius = HUNT_RADIUS, force = "enemy", type = "unit-spawner"}) do
    local key = skip_key(s.position.x, s.position.y)
    local d = dist(home, s.position)
    if (r.skip[key] or 0) <= tick and (not bd or d < bd) then
      local big = false
      for _, w in ipairs(surface.find_entities_filtered{position = s.position, radius = HUNT_NEST_SCAN, force = "enemy", type = "turret"}) do
        if w.name ~= "small-worm-turret" and w.name ~= "small-worm" then big = true; break end
      end
      if big then r.skip[key] = tick + SKIP_TICKS else best, bd = s, d end
    end
  end
  return best
end

-- Called while idle. Starts or resumes a hunt when everything allows it; returns true if the
-- AI was sent out (the fight pass then takes over).
local function hunt_step(ch, r, tick, hp)
  if AIReflexes.mode() ~= "hunt" or storage.ai_player.autonomy_enabled == false then
    r.hunt = nil
    return false
  end
  if hp < RESUME_HP or tick < (r.safe_until or 0) or tick < (r.quiet_until or 0) then return false end
  local h = r.hunt
  if h and tick - h.started > HUNT_MAX_TICKS then
    r.skip[h.key] = tick + SKIP_TICKS
    r.hunt = nil
    return false
  end
  if not h then
    if tick < (r.hunt_next or 0) then return false end
    r.hunt_next = tick + 120
    local guns = ch.get_inventory(defines.inventory.character_guns)
    local main = main_inv(ch)
    local smg = main.get_item_count("submachine-gun") + guns.get_item_count("submachine-gun") > 0
    -- the submachine gun itself (restock crafts one once military is researched), not a pistol
    if count_ammo(ch) < MAG_HUNT or not smg then return false end
    local nest = pick_nest(ch, r, tick)
    if not nest then return false end
    h = {x = nest.position.x, y = nest.position.y, key = skip_key(nest.position.x, nest.position.y), started = tick}
    r.hunt = h
  end
  if not h.staged then                       -- stage 20 tiles out, on the side of home
    local home = AICharacter.get_home(ch.surface) or ch.position
    local dx, dy = home.x - h.x, home.y - h.y
    local len = math.max(1, math.sqrt(dx * dx + dy * dy))
    r.origin = {x = ch.position.x, y = ch.position.y}
    AISkills.cancel_turn("combat")
    if teleport_near(ch, {x = h.x + dx / len * HUNT_STAGE, y = h.y + dy / len * HUNT_STAGE}) then
      h.staged = true
      set_state(r, "fighting", "nest " .. h.key)
      r.last_enemy = tick
      return true
    end
    r.skip[h.key] = tick + SKIP_TICKS
    r.hunt = nil
  end
  return false
end

-- -------------------------------------------------------------------------
-- Maintenance: light tend, research
-- -------------------------------------------------------------------------

local function light_tend(ch, r, tick)
  local surface = ch.surface
  if storage.ai_player.owned == nil then AIRegistry.rebuild_owned(AISkills.TEND_TYPES) end
  local own = AIRegistry.owned(surface, AISkills.TEND_TYPES)
  local n = #own
  if n == 0 then return end
  local slice, start = {}, (r.tend_cursor or 0) % n
  for i = 0, math.min(n, TEND_CAP) - 1 do slice[#slice + 1] = own[(start + i) % n + 1] end
  r.tend_cursor = start + TEND_CAP
  local inv, got = main_inv(ch), {}
  AISkills.collect_outputs(inv, slice, got)
  local fueled = AISkills.refuel(inv, slice)
  local ammo = AISkills.top_up_turrets(ch, inv, slice, false)
  local took = 0
  for _, c in pairs(got) do took = took + c end
  if fueled + ammo + took > 0 then
    r.last_tend = {tick = tick, fueled = fueled, ammo = ammo, took = took}
  end
end

local function auto_research(ch, r, tick)
  if setting("ai-player-auto-research") == false then return end
  local force = ch.force
  if force.current_research then r.research_idle_since = nil; return end
  r.research_idle_since = r.research_idle_since or tick
  -- On the players' own force the choice is theirs: wait for 2 minutes of an empty queue.
  if force.name == "player" and tick - r.research_idle_since < SHARED_RESEARCH_WAIT then return end
  local green = false
  pcall(function()
    green = force.get_item_production_statistics(ch.surface).get_input_count("logistic-science-pack") > 0
  end)
  local name = AISkills.queue_next_research(force, green)
  if name then
    if force.name == "player" then game.print("[AI] Nothing was being researched: queued " .. name, {r = 0.5, g = 0.9, b = 1}) end
    r.last_research = name
    r.research_idle_since = nil
    AIDebug.event("reflex", {name = "research", detail = name})
  end
end

-- -------------------------------------------------------------------------
-- Tick
-- -------------------------------------------------------------------------

-- A turn that arrived (or was held) during a fight starts once it is over.
local function release_held(ch)
  local ap = storage.ai_player
  local held = ap.held_turn
  if not held then return end
  if ap.turn then return end                 -- it starts when the running turn is done, never dropped
  ap.held_turn = nil
  AISkills.queue_turn(ch, held.entries, held.source_id)
  if ap.turn then ap.turn.autopilot = held.autopilot end
end

local DOCTOR_EVERY = 600
local DOCTOR_CAP = 20

function AIReflexes.doctor_pass(ch, tick)
  local ap = storage.ai_player
  if not ap then return end
  ap.doctor = ap.doctor or {tracked = {}, history = {}}
  local doc = ap.doctor
  local surface = ch.surface
  local inv = main_inv(ch)
  local machines = AIRegistry.machines()
  local fixed = 0

  local recent_hist = {}
  for _, h in ipairs(doc.history or {}) do
    if tick - h.tick < 36000 then recent_hist[#recent_hist + 1] = h end
  end
  doc.history = recent_hist

  for _, e in ipairs(AIRegistry.owned(surface, {"container"})) do
    if fixed >= DOCTOR_CAP then break end
    if e.valid then
      local cinv = e.get_inventory(defines.inventory.chest)
      if cinv and not cinv.is_empty() and cinv.get_item_count() >= 2000 then
        local contents = cinv.get_contents()
        for _, item in ipairs(contents) do
          local inserted = inv.insert{name = item.name, count = math.min(item.count, 200), quality = item.quality}
          if inserted > 0 then
            cinv.remove{name = item.name, count = inserted, quality = item.quality}
            table.insert(doc.history, {action = "cleared_output", unit_number = e.unit_number or 0, tick = tick, name = e.name})
            fixed = fixed + 1
            break
          end
        end
      end
    end
  end

  for _, e in ipairs(machines) do
    if fixed >= DOCTOR_CAP then break end
    if e.valid then
      local uid = e.unit_number
      local st = e.status
      local st_name = nil
      if st == defines.entity_status.full_output
         or st == defines.entity_status.not_enough_space_in_output
         or st == defines.entity_status.waiting_for_space_in_destination then
        st_name = "full_output"
      elseif st == defines.entity_status.no_fuel then
        st_name = "no_fuel"
      elseif st == defines.entity_status.no_power or st == defines.entity_status.low_power
         or st == defines.entity_status.not_plugged_in_electric_network then
        st_name = "no_power"
      elseif st == defines.entity_status.waiting_for_source_items
         or st == defines.entity_status.item_ingredient_shortage then
        st_name = "no_ingredients"
      elseif st == defines.entity_status.no_recipe then
        st_name = "no_recipe"
      end

      if st == defines.entity_status.working or st == defines.entity_status.normal or not st_name then
        if uid and doc.tracked[uid] then doc.tracked[uid] = nil end
      elseif uid then
        if not doc.tracked[uid] or doc.tracked[uid].status ~= st_name then
          doc.tracked[uid] = {status = st_name, since = tick, name = e.name, type = e.type}
        end

        if st_name == "full_output" or (e.type == "container" and e.get_inventory(defines.inventory.chest) and not e.get_inventory(defines.inventory.chest).is_empty()) then
          local out_inv = (e.type == "container") and e.get_inventory(defines.inventory.chest) or e.get_output_inventory()
          if out_inv and not out_inv.is_empty() then
            local contents = out_inv.get_contents()
            for _, item in ipairs(contents) do
              local inserted = inv.insert{name = item.name, count = item.count, quality = item.quality}
              if inserted > 0 then
                out_inv.remove{name = item.name, count = inserted, quality = item.quality}
                table.insert(doc.history, {action = "cleared_output", unit_number = uid, tick = tick, name = e.name})
                fixed = fixed + 1
                break
              end
            end
          end
        elseif st_name == "no_fuel" then
          local fueled = AISkills.refuel(inv, {e})
          if fueled > 0 then
            table.insert(doc.history, {action = "refueled", unit_number = uid, tick = tick, name = e.name})
            fixed = fixed + 1
          end
        elseif st_name == "no_power" then
          local pole_plan = AILayout.find_consumer_poles(ch, e)
          if pole_plan and pole_plan.place and #pole_plan.place <= 2 then
            local placed_any = false
            for _, p in ipairs(pole_plan.place) do
              if inv.get_item_count("small-electric-pole") > 0 or storage.selftest then
                local ent = surface.create_entity{name = "small-electric-pole", position = p.position, force = ch.force}
                if ent then
                  AIRegistry.own(ent)
                  if inv.get_item_count("small-electric-pole") > 0 then
                    inv.remove{name = "small-electric-pole", count = 1}
                  end
                  placed_any = true
                end
              end
            end
            if placed_any then
              table.insert(doc.history, {action = "placed_pole", unit_number = uid, tick = tick, name = e.name})
              fixed = fixed + 1
            end
          end
        elseif st_name == "no_ingredients" and e.type == "assembling-machine" then
          local has_belt_feed = false
          for _, ins in ipairs(surface.find_entities_filtered{type = "inserter", area = {{e.position.x - 2, e.position.y - 2}, {e.position.x + 2, e.position.y + 2}}}) do
            if ins.drop_target == e and ins.pickup_target and ins.pickup_target.type == "transport-belt" then
              has_belt_feed = true; break
            end
          end
          if not has_belt_feed then
            local recipe = e.get_recipe()
            if recipe then
              local in_inv = e.get_inventory(defines.inventory.crafter_input)
              for _, ing in ipairs(recipe.ingredients or {}) do
                local have = in_inv.get_item_count(ing.name)
                local needed = math.max(1, (ing.amount or 1) * 2 - have)
                if have < (ing.amount or 1) then
                  if inv.get_item_count(ing.name) >= (ing.amount or 1) then
                    local ins_cnt = in_inv.insert{name = ing.name, count = math.min(needed, inv.get_item_count(ing.name))}
                    inv.remove{name = ing.name, count = ins_cnt}
                    table.insert(doc.history, {action = "hauled_ingredients", unit_number = uid, tick = tick, name = e.name})
                    fixed = fixed + 1
                    break
                  else
                    for _, chest_ent in ipairs(AIRegistry.owned(surface, {"container"})) do
                      local cinv = chest_ent.get_inventory(defines.inventory.chest)
                      if cinv and cinv.get_item_count(ing.name) > 0 then
                        local take_cnt = math.min(needed, cinv.get_item_count(ing.name))
                        cinv.remove{name = ing.name, count = take_cnt}
                        in_inv.insert{name = ing.name, count = take_cnt}
                        table.insert(doc.history, {action = "hauled_ingredients", unit_number = uid, tick = tick, name = e.name})
                        fixed = fixed + 1
                        break
                      end
                    end
                  end
                end
              end
            end
          end
        elseif st_name == "no_recipe" and e.type == "assembling-machine" then
          local rem = ap.remembered_recipes and ap.remembered_recipes[uid]
          if rem and ch.force.recipes[rem] and ch.force.recipes[rem].enabled then
            e.set_recipe(rem)
            table.insert(doc.history, {action = "restored_recipe", unit_number = uid, tick = tick, name = e.name})
            fixed = fixed + 1
          end
        end
      end
    end
  end
end

function AIReflexes.tick(event)
  local ap = storage.ai_player
  if not ap then return end
  local tick = event.tick
  if storage.selftest then
    if AISelftest and AISelftest.pulse then AISelftest.pulse() end
    if not storage.selftest.reflexes then return end
  end
  local r = R()
  r.bridge_offline = AIReflexes.bridge_offline()
  local ch = AICharacter.get_character()
  if not ch or setting("ai-player-reflexes") == false then
    if r.state ~= "idle" then set_state(r, "idle", nil) end
    r.origin, r.hunt = nil, nil
    if ch then release_held(ch) end
    return
  end

  local hp = hp_ratio(ch)
  heal(ch, r, tick, hp)
  if tick % TEND_EVERY == 0 and r.state ~= "fighting" then
    arm(ch)
    restock(ch, r, AIReflexes.mode() == "hunt")
  end

  local engaged = fight(ch, r, tick, hp)
  if not engaged and hunt_step(ch, r, tick, hp) then engaged = fight(ch, r, tick, hp) end
  if engaged then return end

  release_held(ch)
  if tick % TEND_EVERY == 0 then
    light_tend(ch, r, tick)
    auto_research(ch, r, tick)
  end
  if tick % DOCTOR_EVERY == 0 then
    AIReflexes.doctor_pass(ch, tick)
  end
end

-- The character respawned: a minute of retreat-only (no approach, no hunt).
function AIReflexes.on_respawn()
  if storage.ai_player then R().safe_until = game.tick + SAFE_TICKS end
end

-- The character died: remember where (the planner can fetch the corpse loot later), count it
-- against the nest being hunted, and return the respawn delay in ticks. Deaths in a row make it
-- longer (30 s, 60 s, 2 min, 5 min); 5 calm minutes reset it.
function AIReflexes.on_death(character)
  local r = R()
  local tick = game.tick
  if tick - (r.last_death_tick or -1e9) > DEATH_RESET then r.death_streak = 0 end
  r.death_streak, r.last_death_tick = (r.death_streak or 0) + 1, tick
  local delay = DEATH_DELAYS[math.min(r.death_streak, #DEATH_DELAYS)]
  if r.death_streak >= 2 then
    game.print(string.format("[AI] Died %d times in a row - respawning in %ds, away from the enemies",
      r.death_streak, math.floor(delay / 60)), {r = 1, g = 0.5, b = 0})
  end
  r.deaths = r.deaths + 1
  r.death = {x = math.floor(character.position.x), y = math.floor(character.position.y),
             tick = game.tick, surface = character.surface.name}
  if r.hunt then
    local key = r.hunt.key
    r.nest_deaths[key] = (r.nest_deaths[key] or 0) + 1
    if r.nest_deaths[key] >= 2 then
      r.skip[key], r.nest_deaths[key] = game.tick + SKIP_TICKS, nil
    end
  end
  r.hunt, r.origin = nil, nil
  set_state(r, "idle", nil)
  return delay                      -- (a held turn stays: it starts after the respawn)
end

script.on_nth_tick(PERIOD, AIReflexes.tick)

return AIReflexes
