-- ai-player-v3 entry point (skill-based agent)
-- Registers event handlers and console commands.
-- Logic delegates to scripts/*: character, perception, primitives (Tier-0
-- actions), skills (Tier-1 loops + unified executor), brain (request lifecycle).

require("scripts.debug")
require("scripts.character")
require("scripts.registry")
require("scripts.perception")
require("scripts.primitives")
require("scripts.queries")
require("scripts.brain")
require("scripts.blueprints")
require("scripts.layout")
require("scripts.baseplan")
require("scripts.stamps")
require("scripts.flowcheck")
require("scripts.skills")
require("scripts.reflexes")
require("scripts.selftest")
require("scripts.selftest_reflex")
require("scripts.gui")
require("scripts.station_gui")

-- -------------------------------------------------------------------------
-- Remote interface — lets an external MCP/RCON client invoke a skill against
-- the AI character and get its {ok, detail} result back synchronously, reusing
-- the SAME dispatch path the bridge uses (AISkills.run -> REGISTRY). Registered
-- in the main chunk so it exists on every load (Factorio requires interfaces to
-- be added identically each load). Call over RCON:
--   /sc rcon.print(game.table_to_json(
--     remote.call("ai_player", "run_skill", "gather", {item="coal", count=50})))
-- -------------------------------------------------------------------------
remote.add_interface("ai_player", {
  -- Blueprint library sync from the bridge (bridge/blueprints.py). Strings
  -- arrive in chunks; bp_hashes lets the bridge push only what changed.
  bp_chunk = function(name, i, n, part, meta_json, total_len)
    if not storage.ai_player then return "error: not initialised" end
    return AIBlueprints.receive_chunk(name, i, n, part, meta_json, total_len)
  end,
  bp_remove = function(name)
    if storage.ai_player then AIBlueprints.remove(name) end
  end,
  bp_hashes = function()
    if not storage.ai_player then return {} end
    return AIBlueprints.hashes()
  end,

  -- Bridge -> mod after each decision: current goal, model, timings. Shown in
  -- the in-game panel. status_json is a JSON object string.
  set_status = function(status_json)
    if not storage.ai_player then return end
    local ok, t = pcall(helpers.json_to_table, status_json)
    if ok and type(t) == "table" then
      t.tick = game.tick
      storage.ai_player.bridge_status = t
    end
  end,

  -- Bridge startup housekeeping (bridge/factorio/rcon.py). These must be
  -- remote calls: /sc console commands run in the scenario's Lua state and
  -- can't see the mod's storage.
  clear_pending = function()
    if not storage.ai_player then return "no AI state" end
    local n = 0
    for _ in pairs(storage.ai_player.pending_requests) do n = n + 1 end
    storage.ai_player.pending_requests = {}
    if n > 0 then game.print("[AI Bridge] Cleared " .. n .. " pending request(s)") end
    return "cleared " .. n
  end,
  set_request_timeout = function(ticks)
    if not storage.ai_player then return "no AI state" end
    storage.ai_player.request_timeout_ticks = math.max(tonumber(ticks) or 0, 600)
    return "timeout " .. math.floor(storage.ai_player.request_timeout_ticks / 60) .. "s"
  end,
  clear_memory = function()
    local mem = storage.ai_player and storage.ai_player.memory
    if not mem then return "no AI memory" end
    mem.notes, mem.todo_lists, mem.todo_order = {}, {}, {}
    mem.previous_summary, mem.user_directive, mem.directive_expire_tick = nil, nil, nil
    mem.last_responded_to_message = nil
    game.print("[AI Bridge] Memory cleared (notes, todos, summary, directive)")
    return "cleared"
  end,

  -- Everything needed to see what's going on, in one call (bridge/diag.py).
  diag = function()
    local ap = storage.ai_player
    if not ap then return { ok = false, detail = "mod not initialised" } end
    local c = ap.character
    local char = { valid = c ~= nil and c.valid }
    if char.valid then
      char.surface = c.surface.name
      char.position = { x = math.floor(c.position.x), y = math.floor(c.position.y) }
      char.health = math.floor(c.health)
      char.home = AICharacter.get_home(c.surface)
    end
    local pending = {}
    for id, req in pairs(ap.pending_requests or {}) do
      pending[id] = math.floor((game.tick - req.timestamp) / 60)
    end
    local lib, locked = 0, 0
    for _ in pairs(ap.blueprints or {}) do lib = lib + 1 end
    for _ in pairs(ap.bp_geo or {}) do locked = locked + 1 end
    local mem = ap.memory or {}
    return {
      ok = true, tick = game.tick, character = char,
      autonomy = ap.autonomy_enabled ~= false, coop = ap.force_name == "player",
      force = ap.force_name, respawn_tick = ap.respawn_tick,
      pending = pending, request_timeout_s = math.floor((ap.request_timeout_ticks or 0) / 60),
      tick_interval = settings.global["ai-player-tick-interval"].value,
      directive = mem.user_directive, last_summary = mem.previous_summary,
      last_results = mem.last_action_results, notes = #(mem.notes or {}),
      blueprints = lib, blueprints_measured = locked,
      placed = ap.placed_blueprints and { table.unpack(ap.placed_blueprints, math.max(1, #ap.placed_blueprints - 4)) } or {},
      bridge_status = ap.bridge_status, events = ap.events or {},
      reflex = AIReflexes.status(),
      flow_faults = (function()
        local faults = ap.flow_faults or {}
        local details = {}
        for i = 1, math.min(5, #faults) do
          details[#details + 1] = faults[i].detail or faults[i].kind
        end
        return {count = #faults, details = details}
      end)(),
      boiler_logistics = (function()
        local c = ap.character
        if not (c and c.valid) then return nil end
        local p = AIPerception.compute_power(c.surface, c.force)
        return {
          fuel_connected = p.boiler_fuel_connected,
          has_fuel_inserter = p.boiler_has_fuel_inserter,
          fuel_in_position = p.fuel_in_position,
        }
      end)(),
      doctor = (function()
        local doc = ap.doctor
        if not doc then return {total_stuck = 0, attention = {}, recent_fixes = 0} end
        local top = {}
        for uid, info in pairs(doc.tracked or {}) do
          if #top < 10 then
            top[#top + 1] = {unit_number = uid, name = info.name, status = info.status, seconds_ago = math.floor((game.tick - (info.since or game.tick)) / 60)}
          end
        end
        return {total_stuck = #top, attention = top, recent_fixes = #(doc.history or {})}
      end)(),
    }
  end,

  -- skill: registry name; params: table of skill params (item/count/ore/...).
  run_skill = function(skill, params)
    local character = AICharacter.get_character()
    if not character then
      return { ok = false, detail = "no ai character — /spawn-ai-player first" }
    end
    local entry = params or {}
    entry.skill = skill
    local ok, detail = AISkills.run(character, entry)
    return { ok = ok, detail = detail or "" }
  end,
  -- Discovery: sorted list of valid skill names.
  list_skills = function()
    local names = {}
    for n in pairs(AISkills.REGISTRY) do names[#names + 1] = n end
    table.sort(names)
    return names
  end,
  -- Compact, registry-backed situation snapshot (perception.lua factory_state).
  get_state = function()
    local character = AICharacter.get_character()
    if not character then
      return { error = "no ai character — /spawn-ai-player first" }
    end
    return AIPerception.factory_state(character)
  end,
  -- Combat mode, as `ai: hunt` / `ai: defend` in chat (soak harness: tests/ingame/run_soak.py).
  set_combat_mode = function(mode)
    if mode ~= "hunt" and mode ~= "defend" then return "mode must be hunt or defend" end
    AIReflexes.set_mode(mode)
    return mode
  end,
  -- Toggle the autonomous on_tick decision loop. enabled: boolean.
  -- Returns the new state so the caller can confirm.
  set_autonomy = function(enabled)
    storage.ai_player.autonomy_enabled = (enabled == true)
    return { autonomy = storage.ai_player.autonomy_enabled }
  end,
  -- Switch co-op (rides the player force) vs solo (own force). enabled: boolean.
  -- Returns { coop = bool, force = name } so the caller can confirm.
  set_coop = function(enabled)
    return AICharacter.set_coop(enabled == true)
  end,
  -- Read-only world/prototype query (queries.lua). name: query name;
  -- params: table of query params. Works without a spawned character for
  -- queries that take an explicit x/y. Returns the query's own table
  -- ({error = ...} on failure).
  query = function(name, params)
    return AIQueries.run(name, params)
  end,
  -- Discovery: sorted list of valid query names.
  list_queries = function()
    return AIQueries.list()
  end,
  -- Run ONE primitive action (primitives.lua HANDLERS) against the AI
  -- character — the same Tier-0 dispatch the bridge LLM uses, so an MCP
  -- client can do surgical one-off operations (place/mine/craft/insert/take)
  -- that no skill covers. action: table with an 'action' field plus the
  -- handler's params (item/position/recipe/...).
  run_primitive = function(action)
    local character = AICharacter.get_character()
    if not character then
      return { ok = false, detail = "no ai character — /spawn-ai-player first" }
    end
    if type(action) ~= "table" or not action.action then
      return { ok = false, detail = "action table with an 'action' field required" }
    end
    local ok, detail = AIActions.run(character, action)
    return { ok = ok, detail = detail or "" }
  end,
  -- Read chat messages logged since a given tick (inclusive). Returns
  -- { messages = { {player,message,tick}, ... }, latest_tick = <tick> }.
  -- Pass since = 0 (or omit) to get the whole ring buffer. An external
  -- harness polls this to receive player chat without the python_bridge.
  get_chat = function(params)
    local s = storage.ai_player
    if not s then return { messages = {}, latest_tick = game.tick } end
    local log = s.chat_log or {}
    local since = (params and tonumber(params.since)) or 0
    local out, latest = {}, 0
    for _, e in ipairs(log) do
      if (e.tick or 0) >= since then
        out[#out + 1] = { player = e.player or "", message = e.message or "", tick = e.tick or 0 }
        if (e.tick or 0) > latest then latest = e.tick or 0 end
      end
    end
    return { messages = out, latest_tick = latest }
  end,

  -- Import a Factorio blueprint string as entity ghosts at {x,y} on the AI's
  -- current surface.
  -- Ghosts are placed with build_mode=forced (2.x; the old force_build flag no
  -- longer exists, which made this silently place nothing): whatever can be
  -- built is ghosted and obstructing trees/rocks are marked for
  -- deconstruction. They are NOT revived — build_ghosts constructs them from
  -- inventory afterwards. force defaults to the AI's force.
  -- Returns { ok, errors, ghost_count } or { ok=false, detail=... }.
  import_blueprint = function(params)
    local s = AICharacter.get_surface()
    if not s then return { ok = false, detail = "no surface" } end
    local p = params or {}
    local bp = p.blueprint
    local x = tonumber(p.x) or 0
    local y = tonumber(p.y) or 0
    if type(bp) ~= "string" or bp == "" then
      return { ok = false, detail = "blueprint string required" }
    end
    local fname = p.force or (storage.ai_player and storage.ai_player.force_name) or "player"
    local f = game.forces[fname]
    if not f then return { ok = false, detail = "force '" .. fname .. "' not found" } end
    local inv = game.create_inventory(1)
    local stack = inv[1]
    local err = stack.import_stack(bp)
    if not (stack.valid_for_read and stack.is_blueprint) then
      inv.destroy()
      return { ok = false, detail = "string is not a single blueprint (import_err=" .. tostring(err) .. ")" }
    end
    local gs = stack.build_blueprint{
      surface = s, force = f,
      position = { x = x, y = y },
      build_mode = defines.build_mode.forced,
    }
    inv.destroy()
    return { ok = true, errors = err or 0, ghost_count = #(gs or {}), import_err = tostring(err) }
  end,

  -- Export all entities in a rectangle (x1,y1)-(x2,y2) on the AI's current
  -- surface to a blueprint string. force defaults to the AI's force. Returns
  -- { ok, blueprint } or { ok=false, detail=... }. Empty area -> ok=false.
  export_blueprint = function(params)
    local s = AICharacter.get_surface()
    if not s then return { ok = false, detail = "no surface" } end
    local p = params or {}
    local x1, y1 = tonumber(p.x1) or 0, tonumber(p.y1) or 0
    local x2, y2 = tonumber(p.x2) or 0, tonumber(p.y2) or 0
    local fname = p.force or (storage.ai_player and storage.ai_player.force_name) or "player"
    local f = game.forces[fname]
    if not f then return { ok = false, detail = "force '" .. fname .. "' not found" } end
    local lt = { x = math.min(x1, x2), y = math.min(y1, y2) }
    local rb = { x = math.max(x1, x2), y = math.max(y1, y2) }
    -- Count first so we can report "no entities" without making an empty bp.
    local ents = s.find_entities_filtered{ area = { left_top = lt, right_bottom = rb }, force = f }
    if #ents == 0 then
      return { ok = false, detail = "no entities in area for force '" .. fname .. "'" }
    end
    local e = s.create_entity{ name = "item-on-ground", position = { x = lt.x, y = lt.y }, stack = "blueprint" }
    if not e or not e.valid then
      return { ok = false, detail = "could not create blueprint item-on-ground" }
    end
    e.stack.label = "Exported Area"
    e.stack.create_blueprint{
      surface = s, force = f,
      area = { left_top = lt, right_bottom = rb },
      include_entities = true, include_modules = true,
      include_station_names = true, include_trains = true, include_fuel = true,
    }
    local str = e.stack.export_stack()
    e.destroy()
    if not str or str == "" then
      return { ok = false, detail = "export_stack returned empty" }
    end
    return { ok = true, blueprint = str }
  end,
})

-- -------------------------------------------------------------------------
-- Storage initialisation
-- -------------------------------------------------------------------------

local function init_storage()
  storage.ai_player = storage.ai_player or {}
  local s = storage.ai_player
  s.character        = s.character or nil
  -- "player" = co-op (AI rides the human's force: shared base view, power,
  -- research). Any other name = solo (own force). Doubles as the mode switch
  -- (AICharacter.set_coop / remote set_coop / /ai-coop). Default: co-op.
  s.force_name       = s.force_name or "player"
  s.tick_counter     = s.tick_counter or 0
  s.pending_requests = s.pending_requests or {}
  s.chat_log         = s.chat_log or {}
  s.respawn_tick     = s.respawn_tick or nil
  s.map_tag          = s.map_tag or nil
  s.memory           = s.memory or AIBrain.init_memory()
  s.machines         = s.machines or {}   -- registry.lua: unit_number -> LuaEntity
  s.last_reconcile_tick = s.last_reconcile_tick or 0
  -- Autonomous on_tick decision loop on by default; an external harness can
  -- disable it (set_autonomy) so it doesn't contend with skill calls. The
  -- `~= false` keeps an explicit false across re-init instead of resetting it.
  s.autonomy_enabled = (s.autonomy_enabled ~= false)
end

-- Ensure exactly one AI character exists on ai_player_force.
-- If the stored reference is stale (entity was removed externally), clears it.
-- If multiple characters exist on the force (duplicate spawns), destroys extras.
-- Returns the valid character entity, or nil if none exists.
local function reconcile_character()
  if not storage.ai_player then return nil end

  local force   = AICharacter.get_force()
  if not force then return nil end

  -- AI characters have NO controlling/associated player (the human's character
  -- does). This distinguishes the AI even when it shares the player force in
  -- co-op mode, so we never select or destroy the human's character.
  -- Searched on every surface: the AI may be on any planet.
  local chars = AICharacter.find_all_ai_characters(force)

  if #chars == 0 then
    -- No character in world — clear any stale reference
    storage.ai_player.character = nil
    return nil
  end

  if #chars > 1 then
    -- Duplicates — keep the one matching storage, or the first found; destroy the rest
    local keep = nil
    local stored = storage.ai_player.character
    for _, c in ipairs(chars) do
      if stored and stored.valid and c == stored then
        keep = c
        break
      end
    end
    if not keep then keep = chars[1] end
    for _, c in ipairs(chars) do
      if c ~= keep and c.valid then
        game.print(string.format("[AI] Removing duplicate character at {%.0f,%.0f}", c.position.x, c.position.y), {r=1,g=0.5,b=0})
        c.destroy()
      end
    end
    storage.ai_player.character = keep
    return keep
  end

  -- Exactly one character — ensure storage points to it
  storage.ai_player.character = chars[1]
  return chars[1]
end

-- Update/create the chart tag that marks the AI on the player's map.
-- Reveals fog of war around the character and places a named map marker.
local function update_map_tag()
  if not storage.ai_player then return end
  local character = storage.ai_player.character
  if not character or not character.valid then
    local tag = storage.ai_player.map_tag
    if tag and tag.valid then tag.destroy() end
    storage.ai_player.map_tag = nil
    return
  end

  local player_force = game.forces["player"]
  if not player_force then return end
  local surface = character.surface
  local pos     = character.position

  -- Reveal fog of war around AI so the tag is always visible on the map
  player_force.chart(surface, {
    left_top     = {x = pos.x - 64, y = pos.y - 64},
    right_bottom = {x = pos.x + 64, y = pos.y + 64},
  })

  -- Recreate tag at current position (tags are not moveable)
  local tag = storage.ai_player.map_tag
  if tag and tag.valid then tag.destroy() end
  storage.ai_player.map_tag = player_force.add_chart_tag(surface, {
    position = pos,
    text     = "AI Player",
    icon     = {type = "virtual", name = "signal-A"},
  })
end

-- -------------------------------------------------------------------------
-- Events
-- -------------------------------------------------------------------------

script.on_init(function()
  init_storage()
  local session_id = string.format("s_%d_%06d", game.tick, math.random(100000, 999999))
  storage.ai_player.session_id = session_id
  local sfc = game.surfaces[1]
  local seed = (sfc and sfc.map_gen_settings and sfc.map_gen_settings.seed) or 0
  AIDebug.session_header("init", session_id, seed)
  storage.ai_player.session_logged = true
  AICharacter.create_force()
  AIBrain.write_bridge_config()
  for _, p in pairs(game.players) do AIGui.ensure_button(p) end
  game.print("[AI Player v3] Initialised — open the AI panel (top-left button or Ctrl+Shift+A)", {r=0, g=1, b=1})
end)

script.on_configuration_changed(function()
  init_storage()
  AICharacter.create_force()
  -- Header for a save that never logged one (or a mod update); the flag lives in storage so every
  -- peer agrees on it (a module-local flag diverges between host and clients).
  if not storage.ai_player.session_logged then
    local session_id = storage.ai_player.session_id
    if not session_id then
      session_id = string.format("s_%d_%06d", game.tick, math.random(100000, 999999))
      storage.ai_player.session_id = session_id
    end
    local sfc = game.surfaces[1]
    local seed = (sfc and sfc.map_gen_settings and sfc.map_gen_settings.seed) or 0
    AIDebug.session_header("config", session_id, seed)
    storage.ai_player.session_logged = true
  end
  -- A mod update may change the panel layout: close open panels so stored
  -- element refs never point at an old layout.
  AIGui.reset_all()
  for _, p in pairs(game.players) do AIGui.ensure_button(p) end
  storage.ai_player.pending_requests = {}
  AIRegistry.rebuild_owned(AISkills.TEND_TYPES)
  reconcile_character()
  -- Give an already-spawned character a home anchor if it lacks one (e.g. after
  -- updating to a mod version that added home tracking mid-session).
  local c = storage.ai_player.character
  if c and c.valid and not AICharacter.get_home(c.surface) then
    AICharacter.set_home(c.surface, c.position)
  end
  AIBrain.write_bridge_config()
  -- Rebuild the machine registry from the live world (covers mod-update load and
  -- any machines created while the registry was absent/stale).
  AIRegistry.reconcile(AICharacter.get_surface(), game.forces[storage.ai_player.force_name])
  game.print("[AI Player v3] Configuration reloaded", {r=0.7, g=1, b=0.7})
end)

script.on_load(function()
  -- on_load must NOT modify storage — Factorio CRC-checks it before/after
  -- and will abort with a save/load stability error if anything changed.
  --
  -- pending_requests: the bridge calls clear_pending_requests() via RCON on
  -- startup, and process_pending() expires stale requests after 150s anyway.
  --
  -- reconcile_character: entity references in storage survive save/load in
  -- Factorio automatically. on_configuration_changed handles reconciliation
  -- after F5 / mod setting changes where game is available.
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "ai-player-combat-mode" and storage.ai_player then
    storage.ai_player.combat_mode = nil          -- the setting wins over an earlier "ai: hunt" in chat
  end
  local bridge_settings = {
    "ai-player-provider", "ai-player-model-name", "ai-player-lm-studio-url",
    "ai-player-openai-api-key", "ai-player-openai-api-base", "ai-player-custom-url",
    "ai-player-rcon-host", "ai-player-rcon-port", "ai-player-rcon-password",
  }
  for _, name in ipairs(bridge_settings) do
    if event.setting == name then
      AIBrain.write_bridge_config()
      break
    end
  end
end)

-- -------------------------------------------------------------------------
-- Machine registry — event-driven add/remove (latency optimisation; the
-- periodic reconcile in on_tick is the authoritative backbone). Filtered to
-- tracked machine types so these handlers don't fire for trees, biters, etc.
-- -------------------------------------------------------------------------

local function on_machine_built(event)
  local e = event.entity or event.created_entity or event.destination
  if e then AIRegistry.add(e) end
end

local function on_machine_removed(event)
  local e = event.entity
  if e and e.unit_number then AIRegistry.remove(e.unit_number) end
end

for _, ev in ipairs({
  defines.events.on_built_entity, defines.events.on_robot_built_entity,
  defines.events.script_raised_built, defines.events.script_raised_revive,
}) do
  script.on_event(ev, on_machine_built, AIRegistry.event_filters())
end

for _, ev in ipairs({
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity, defines.events.script_raised_destroy,
}) do
  script.on_event(ev, on_machine_removed, AIRegistry.event_filters())
end
-- on_entity_died is registered once, below with the character-death handler
-- (a second script.on_event for the same event replaces the first).

-- -------------------------------------------------------------------------
-- Main tick
-- -------------------------------------------------------------------------

script.on_event(defines.events.on_tick, function(event)
  -- Saves from before the header existed: log it once, from storage state so all peers agree.
  if storage.ai_player and not storage.ai_player.session_logged then
    local session_id = storage.ai_player.session_id
    if not session_id then
      session_id = string.format("s_%d_%06d", game.tick, math.random(100000, 999999))
      storage.ai_player.session_id = session_id
    end
    local sfc = game.surfaces[1]
    local seed = (sfc and sfc.map_gen_settings and sfc.map_gen_settings.seed) or 0
    AIDebug.session_header("load", session_id, seed)
    storage.ai_player.session_logged = true
  end

  -- Self-heal if storage was never initialised (e.g. save loaded without on_init firing)
  if not storage.ai_player then
    init_storage()
    AICharacter.create_force()
    return
  end

  local tick = event.tick

  -- Periodic registry reconciliation — the authoritative correction path for the
  -- machine registry (events keep it fresh between these; this catches anything
  -- missed and prunes invalids). Every 600 ticks (~10s); cheap relative to that.
  if tick % 600 == 0 then
    AIRegistry.reconcile(AICharacter.get_surface(), game.forces[storage.ai_player.force_name])
  end

  -- Auto-respawn
  if storage.ai_player.respawn_tick and tick >= storage.ai_player.respawn_tick then
    storage.ai_player.respawn_tick = nil
    AICharacter.spawn_ai_player()
  end

  -- Planet change (carried over by /ai-come, a rocket, etc.): remember the
  -- surface, give it a home anchor on first arrival, and rescan its machines.
  -- Runs every tick (a string compare) and before the autonomy gate, so the
  -- surface stays current even while an external harness drives the AI.
  local ai_char = storage.ai_player.character
  if ai_char and ai_char.valid and storage.ai_player.surface_name ~= ai_char.surface.name then
    local surface = ai_char.surface
    AICharacter.remember_surface(surface)
    if not AICharacter.get_home(surface) then AICharacter.set_home(surface, ai_char.position) end
    AIRegistry.reconcile(surface, game.forces[storage.ai_player.force_name])
  end

  -- Run the next move of the current turn (moves wait for hand-crafting).
  AISkills.step_turn(tick)

  -- Expire stale pending requests
  AIBrain.process_pending(tick)

  -- Expire directive
  AIBrain.process_directive_expiry(tick)

  -- Autonomy gate: when disabled (an external MCP/harness is driving via skill
  -- tools), skip the periodic self-directed decision so the built-in router
  -- doesn't issue competing actions. Maintenance above (registry reconcile,
  -- respawn, pending expiry) still runs; chat directives still trigger decisions
  -- via on_console_chat, which is independent of this loop.
  if storage.ai_player.autonomy_enabled == false then
    -- Paused: no self-directed turns, but an order the player gave while a
    -- request was in flight still gets its turn once the bridge is free.
    local mem = storage.ai_player.memory
    if mem.pending_user_message and next(storage.ai_player.pending_requests) == nil then
      local character = AICharacter.get_character()
      if character then AIBrain.request_decision(character, nil) end
    end
    return
  end

  -- A turn that got something done asks for the next one soon (autopilot chains).
  local ap = storage.ai_player
  if ap.fast_decide_tick and tick >= ap.fast_decide_tick then
    ap.fast_decide_tick = nil
    if not ap.turn and next(ap.pending_requests) == nil then
      local fc = AICharacter.get_character()
      if fc then
        ap.tick_counter = 0
        AIBrain.request_decision(fc, nil)
        return
      end
    end
  end

  -- Decision tick
  local interval = settings.global["ai-player-tick-interval"].value or 300
  storage.ai_player.tick_counter = (storage.ai_player.tick_counter or 0) + 1
  if storage.ai_player.tick_counter < interval then return end
  storage.ai_player.tick_counter = 0

  local character = AICharacter.get_character()
  if not character then return end

  update_map_tag()
  AIBrain.request_decision(character, nil)
end)

-- -------------------------------------------------------------------------
-- Character death
-- -------------------------------------------------------------------------

-- Machine deaths keep the registry fresh; the AI character's death schedules
-- a respawn. Filtered to tracked machine types + characters.
local death_filters = {}
for _, f in ipairs(AIRegistry.event_filters()) do death_filters[#death_filters + 1] = f end
death_filters[#death_filters + 1] = {filter = "type", type = "character", mode = "or"}

-- An enemy hit something the AI owns: remember where and when (perception.threat.attack).
local function ai_owned_target(e)
  return e.valid and storage.ai_player and e.force == AICharacter.get_force()
    and (e.type == "character" or e.last_user == nil)
end

script.on_event(defines.events.on_entity_damaged, function(event)
  if not storage.ai_player or not (event.force and event.force.name == "enemy") then return end
  local e = event.entity
  if ai_owned_target(e) then
    storage.ai_player.last_attack = {tick = event.tick, x = math.floor(e.position.x),
                                     y = math.floor(e.position.y), name = e.name, surface = e.surface.index}
  end
end, {{filter = "turret"}, {filter = "crafting-machine", mode = "or"}, {filter = "type", type = "mining-drill", mode = "or"},
      {filter = "type", type = "lab", mode = "or"}, {filter = "type", type = "character", mode = "or"},
      {filter = "type", type = "container", mode = "or"}, {filter = "type", type = "boiler", mode = "or"},
      {filter = "type", type = "generator", mode = "or"}, {filter = "type", type = "offshore-pump", mode = "or"},
      {filter = "type", type = "electric-pole", mode = "or"}, {filter = "type", type = "inserter", mode = "or"}})

script.on_event(defines.events.on_entity_died, function(event)
  on_machine_removed(event)
  if not storage.ai_player then return end
  -- soak runs count what the enemy destroyed (selftest.lua soak_snapshot)
  if storage.soak and storage.soak.on and event.force and event.force.name == "enemy" and ai_owned_target(event.entity) then
    local lost = storage.soak.lost or {}
    storage.soak.lost = lost
    lost[event.entity.name] = (lost[event.entity.name] or 0) + 1
  end
  if event.entity == storage.ai_player.character then
    local delay = AIReflexes.on_death(event.entity)
    game.print(string.format("[AI] Character died — respawning in %ds", math.floor(delay / 60)), {r=1, g=0.5, b=0})
    -- Respawn on the planet it died on, not Nauvis.
    AICharacter.remember_surface(event.entity.surface)
    storage.ai_player.character = nil
    if settings.global["ai-player-auto-respawn"].value then
      storage.ai_player.respawn_tick = event.tick + delay
    end
  end
end, death_filters)

-- -------------------------------------------------------------------------
-- Player chat → directive
-- -------------------------------------------------------------------------

-- Append a chat line to the ring buffer (newest last). Capped so storage
-- doesn't grow unbounded over a long session. Kept on storage.ai_player.chat_log
-- so it survives save/load and is readable via remote.call('ai_player','get_chat').
local function log_chat(player_name, message, tick)
  local log = storage.ai_player.chat_log
  log[#log + 1] = {
    player = player_name or "",
    message = message or "",
    tick = tick or game.tick,
  }
  while #log > 100 do table.remove(log, 1) end
end

-- A player order for the AI (chat "ai: ..." or the panel's Tell box).
local function give_directive(directive)
  local mem = storage.ai_player.memory
  -- A repeated order is a real order (the player wants it again), so no
  -- dedup against the last answered message.
  mem.last_responded_to_message = nil
  mem.last_player_message = directive
  -- Queue it so it reaches the bridge even if a request is currently in flight.
  mem.pending_user_message = directive

  AIBrain.set_directive(directive, 1800)

  -- Immediate, model-independent acknowledgement so the player always gets
  -- feedback the instant they speak — does not wait on the (possibly slow) LLM.
  game.print("[AI] Got it — working on: " .. directive, {r=0.5, g=0.9, b=1})

  local character = AICharacter.get_character()
  if character then
    AIBrain.request_decision(character, directive)
  else
    game.print("[AI] (no character spawned — use /spawn-ai-player)", {r=1, g=0.6, b=0})
  end
end

script.on_event(defines.events.on_console_chat, function(event)
  if not storage.ai_player then return end
  if not event.message then return end

  local msg = event.message
  -- Log EVERY console chat line (not just AI directives) so an external
  -- harness (pi-factorio RCON bridge) can poll the full conversation via
  -- remote.call('ai_player','get_chat', {since = <tick>}).
  local pname = (event.player_index and game.players[event.player_index])
    and game.players[event.player_index].name or ""
  log_chat(pname, msg, event.tick)

  -- Prefixes: "ai: <text>", "ai, <text>", "!ai <text>" (any case, space after
  -- ":"/"," optional). A bare "ai <text>" no longer counts — ordinary chat
  -- like "ai is stuck" was being taken as an order.
  local directive = msg:match("^%s*[Aa][Ii]%s*[:,]%s*(.-)%s*$")
                 or msg:match("^%s*![Aa][Ii]%s+(.-)%s*$")

  if not directive or directive == "" then return end
  -- "ai: hunt" / "ai: defend" switch the combat mode (reflexes.lua) instead of being an order.
  local mode = directive:lower()
  if mode == "hunt" or mode == "defend" then return AIReflexes.set_mode(mode) end
  give_directive(directive)
end)

-- -------------------------------------------------------------------------
-- Console commands
-- -------------------------------------------------------------------------

-- Commands that change the AI's state are admin-only. cmd.player_index is nil
-- for RCON and the server console, so the bridge is always allowed.
local function add_admin_command(name, help, fn)
  commands.add_command(name, help, function(cmd)
    if cmd.player_index then
      local p = game.get_player(cmd.player_index)
      if not (p and p.admin) then
        if p then p.print("[AI] /" .. name .. " is admin-only", {r=1,g=0.5,b=0}) end
        return
      end
    end
    fn(cmd)
  end)
end

add_admin_command("spawn-ai-player", "Spawn or reset the AI player character",
  function(cmd)
    if not storage.ai_player then
      game.print("[AI] Not initialised", {r=1,g=0,b=0}); return
    end
    -- Spawn where the caller physically is (not the surface they're viewing in
    -- remote/map view); from RCON, on the AI's current/last surface.
    local p = cmd.player_index and game.get_player(cmd.player_index)
    local ok = AICharacter.spawn_ai_player(p and p.physical_surface or nil)
    if ok then
      game.print("[AI] Character spawned", {r=0,g=1,b=0})
    end
  end
)

add_admin_command("remove-ai-player", "Destroy the AI player character",
  function()
    if not storage.ai_player then return end
    -- Destroy only AI characters (no controlling/associated player) — so this is
    -- safe even when the AI shares the player force in co-op mode.
    local force   = AICharacter.get_force()
    local removed = 0
    if force then
      for _, c in ipairs(AICharacter.find_all_ai_characters(force)) do
        if c.valid then c.destroy(); removed = removed + 1 end
      end
    end
    storage.ai_player.character = nil
    storage.ai_player.respawn_tick = nil
    game.print(string.format("[AI] Removed %d character(s)", removed), {r=1,g=0.5,b=0})
  end
)

-- A free spot BESIDE `target` (never on top of it). Characters don't collide
-- with each other, so find_non_colliding_position happily returns the target's
-- exact position — landing a teleport there stacks the two characters and can
-- trap the human under an AI that isn't moving. Search adjacent offsets and
-- reject anything closer than 1 tile.
local function position_beside(surface, target)
  local offsets = {{1.5,0},{-1.5,0},{0,1.5},{0,-1.5},{1.5,1.5},{-1.5,-1.5},{1.5,-1.5},{-1.5,1.5}}
  for _, off in ipairs(offsets) do
    local pos = surface.find_non_colliding_position("character",
      {target.x + off[1], target.y + off[2]}, 4, 0.25)
    if pos then
      local dx, dy = pos.x - target.x, pos.y - target.y
      if (dx*dx + dy*dy) >= 1 then return pos end
    end
  end
  return target  -- fully enclosed target; overlap beats a failed teleport
end

commands.add_command("goto-ai-player", "Teleport to the AI player",
  function(cmd)
    if not storage.ai_player or not cmd.player_index then return end   -- RCON has no player
    local character = AICharacter.get_character()
    if not character then
      game.print("[AI] No character active", {r=1,g=0,b=0}); return
    end
    local player = game.get_player(cmd.player_index)
    if player then
      player.teleport(position_beside(character.surface, character.position), character.surface)
    end
  end
)

add_admin_command("ai-coop",
  "Switch the AI between co-op (shares your force) and solo (own force). Usage: /ai-coop on|off",
  function(cmd)
    if not storage.ai_player then return end
    local arg = (cmd.parameter or ""):lower():match("%S+")
    if arg ~= "on" and arg ~= "off" then
      local cur = storage.ai_player.force_name == "player" and "co-op" or "solo"
      game.print("[AI] Usage: /ai-coop on|off  (currently " .. cur .. ")", {r=1,g=1,b=0})
      return
    end
    local r = AICharacter.set_coop(arg == "on")
    game.print("[AI] Mode: " .. (r.coop and "CO-OP — shares your force, sees your base" or "SOLO — own force"), {r=0,g=1,b=1})
  end
)

local function bring_ai_to(player)
  local character = AICharacter.get_character()
  if not character then
    game.print("[AI] No character active", {r=1,g=0,b=0}); return
  end
  if player and player.character then
    local ps = player.character.surface
    character.teleport(position_beside(ps, player.character.position), ps)
    game.print("[AI] Coming to you", {r=0,g=1,b=1})
  end
end

commands.add_command("ai-come", "Bring the AI character to you",
  function(cmd)
    if not storage.ai_player or not cmd.player_index then return end   -- RCON has no player
    bring_ai_to(game.get_player(cmd.player_index))
  end
)

add_admin_command("ai-collect",
  "AI mines back ALL buildings it placed (into its inventory), then returns to you",
  function(cmd)
    if not storage.ai_player then return end
    -- Force-sweep mine: only safe on the AI's OWN (solo) force. In co-op the AI
    -- shares the player force, so this would mine the human's entire base — refuse.
    if storage.ai_player.force_name == "player" then
      game.print("[AI] ai-collect is disabled in co-op mode (it would mine the shared base). Switch to solo with /ai-coop off first.", {r=1,g=0.5,b=0})
      return
    end
    local character = AICharacter.get_character()
    if not character then
      game.print("[AI] No character active", {r=1,g=0,b=0}); return
    end
    local surface = character.surface
    local force   = AICharacter.get_force()
    local char_inv = character.get_inventory(defines.inventory.character_main)
    local mined, left = 0, 0
    for _, e in ipairs(surface.find_entities_filtered{force = force}) do
      if e.valid and e.type ~= "character" and e.minable then
        local ok = e.mine{inventory = char_inv, raise_destroyed = true}
        if ok then mined = mined + 1 else left = left + 1 end
      end
    end
    game.print(string.format("[AI] Collected %d building(s)%s", mined,
      left > 0 and (" — " .. left .. " left (inventory full or unminable)") or ""),
      {r=0, g=1, b=0.5})
    -- Return to the player
    local player = game.get_player(cmd.player_index)
    if player and player.character then
      local ps = player.character.surface
      character.teleport(position_beside(ps, player.character.position), ps)
      game.print("[AI] Returned to you", {r=0, g=1, b=1})
    end
  end
)

-- Run one skill from text args, as /ai-do and the panel's Run button do, and
-- print the result. arg1 maps to item/resource/ore/tech so one token works
-- across gather/miner/smelter/research; arg2 = count or output.
-- place_blueprint takes <name> [resource]; connect_belt is LLM-only.
local function run_skill_text(character, skill, rest)
  local tokens = {}
  for tok in (rest or ""):gmatch("%S+") do tokens[#tokens + 1] = tok end
  local entry = {skill = skill}
  if skill == "place_blueprint" then
    entry.name = tokens[1]; entry.resource = tokens[2]
    tokens = {}
  elseif tokens[1] then
    entry.item = tokens[1]; entry.resource = tokens[1]; entry.ore = tokens[1]; entry.tech = tokens[1]; entry.recipe = tokens[1]
  end
  if tokens[2] then
    local n = tonumber(tokens[2])
    if n then entry.count = n else entry.output = tokens[2] end
  end
  AISkills.execute(character, {entry})
  local r = storage.ai_player.memory.last_action_results
  r = r and r[1]
  if r then
    game.print("[AI /ai-do] " .. (r.ok and "OK: " or "FAILED: ") .. (r.detail or ""),
      r.ok and {r=0.6,g=1,b=0.6} or {r=1,g=0.6,b=0.4})
  end
  return r
end

add_admin_command("ai-do",
  "Force-run a skill deterministically (bypasses the LLM): /ai-do <skill> [arg] [count|output]",
  function(cmd)
    if not storage.ai_player then return end
    local character = AICharacter.get_character()
    if not character then
      game.print("[AI] No character active — /spawn-ai-player first", {r=1,g=0,b=0}); return
    end
    local param = cmd.parameter or ""
    local skill, rest = param:match("^%s*(%S+)%s*(.*)$")
    if not skill then
      game.print("[AI] usage: /ai-do <skill> [arg] [count|output]  e.g. /ai-do build_miner iron-ore", {r=1,g=0.8,b=0.3})
      return
    end
    if not AISkills.REGISTRY[skill] then
      local names = {}
      for n in pairs(AISkills.REGISTRY) do names[#names+1] = n end
      table.sort(names)
      game.print("[AI] unknown skill '" .. skill .. "'. Known: " .. table.concat(names, ", "), {r=1,g=0.6,b=0.3})
      return
    end
    run_skill_text(character, skill, rest)
  end
)

add_admin_command("ai-force",
  "Lock the LLM to one skill until cleared: /ai-force <skill> [args] | /ai-force off",
  function(cmd)
    if not storage.ai_player then return end
    local mem = storage.ai_player.memory
    local param = (cmd.parameter or ""):match("^%s*(.-)%s*$")  -- trim both ends

    -- No arg: report current lock state.
    if param == "" then
      if mem.force_skill then
        game.print("[AI] Locked to skill: " .. mem.force_skill .. "  (/ai-force off to clear)", {r=1,g=0.9,b=0.5})
      else
        game.print("[AI] Not locked. Usage: /ai-force <skill> [args] | /ai-force off", {r=1,g=0.8,b=0.3})
      end
      return
    end

    -- Clear the lock.
    local lower = param:lower()
    if lower == "off" or lower == "none" or lower == "clear" then
      mem.force_skill = nil
      mem.user_directive = nil
      mem.directive_expire_tick = nil
      game.print("[AI] Skill lock cleared", {r=0.6,g=1,b=0.6})
      return
    end

    local skill = param:match("^(%S+)")
    if not AISkills.REGISTRY[skill] then
      local names = {}
      for n in pairs(AISkills.REGISTRY) do names[#names + 1] = n end
      table.sort(names)
      game.print("[AI] unknown skill '" .. skill .. "'. Known: " .. table.concat(names, ", "), {r=1,g=0.6,b=0.3})
      return
    end

    -- Persistent lock: unlike a chat directive (30s TTL), this has no expiry —
    -- it holds until /ai-force off. user_directive carries the param context
    -- (e.g. "build_miner iron-ore") into the prompt so the model fills params.
    mem.force_skill = skill
    mem.user_directive = param
    mem.directive_expire_tick = nil
    game.print("[AI] Locked to skill: " .. param .. "  (until /ai-force off)", {r=0.5,g=0.9,b=1})

    -- Kick off a decision now (tick-based, no chat ack) so it takes effect immediately.
    local character = AICharacter.get_character()
    if character then AIBrain.request_decision(character, nil) end
  end
)

add_admin_command("ai-response",
  "Internal: deliver bridge response to the mod",
  function(cmd)
    if not cmd.parameter then return end
    local sep = cmd.parameter:find("|")
    if not sep then
      game.print("[AI] ai-response: malformed (missing |)", {r=1,g=0,b=0}); return
    end
    local req_id     = cmd.parameter:sub(1, sep - 1)
    local actions_json = cmd.parameter:sub(sep + 1)
    AIBrain.handle_response(req_id, actions_json)
  end
)

-- Blueprint library. add/book export the held blueprint (or whole book) for
-- the bridge to import; it becomes usable once the bridge syncs it back.
add_admin_command("ai-bp",
  "AI blueprint library: /ai-bp add [name] [category] | book | list | remove <name> | test <name>",
  function(cmd)
    if not storage.ai_player then return end
    local player = cmd.player_index and game.get_player(cmd.player_index)
    local function say(msg, color)
      if player then player.print("[AI bp] " .. msg, color) else rcon.print(msg) end
    end
    local sub, a, b = (cmd.parameter or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)")
    if sub == "add" or sub == "book" then
      if not player then return say("run this in game while holding a blueprint") end
      local ok, res = AIBlueprints.export_held(player, a ~= "" and a or nil, b ~= "" and b or nil)
      if ok then
        say("exported '" .. res .. "' — the bridge will import it and sync it back within a few seconds"
            .. " (books are split into one entry per blueprint)", {r=0.5, g=1, b=0.5})
      else
        say(res, {r=1, g=0.6, b=0.3})
      end
    elseif sub == "list" then
      local l = AIBlueprints.list()
      if #l == 0 then return say("library is empty — start the bridge, or /ai-bp add while holding a blueprint") end
      for _, e in ipairs(l) do
        say(string.format("%s  [%s, %s]", e.name, e.category or "?", e.placement or "?"))
      end
    elseif sub == "remove" and a ~= "" then
      local n = AIBlueprints.safe_name(a)
      if not n then return say("not a valid blueprint name") end
      AIBlueprints.remove(n)
      helpers.write_file("ai-player/blueprints/remove_" .. n .. ".json",
                         helpers.table_to_json({remove = n}), false, 0)
      say("removed '" .. n .. "' (the bridge deletes it from blueprints/local too)")
    elseif sub == "test" and a ~= "" then
      if not player then return say("run this in game") end
      local ok, res = AIBlueprints.test_place(player, a)
      say(res, ok and {r=0.5, g=1, b=0.5} or {r=1, g=0.6, b=0.3})
    else
      say("usage: /ai-bp add [name] [category] | book | list | remove <name> | test <name>")
    end
  end
)

commands.add_command("ai-pending",
  "Show pending AI requests",
  function()
    if not storage.ai_player then return end
    local pending = storage.ai_player.pending_requests
    if not next(pending) then
      game.print("[AI] No pending requests"); return
    end
    for id, req in pairs(pending) do
      local age = math.floor((game.tick - req.timestamp) / 60)
      local trigger = req.user_message and ("triggered by: \"" .. req.user_message .. "\"") or "tick-based"
      game.print(string.format("[AI] Pending #%s — %ds ago (%s)", id, age, trigger),
        {r=1, g=0.8, b=0.3})
    end
  end
)

add_admin_command("ai-clear",
  "Abort all in-flight AI requests (manual recovery if the agent is stalled)",
  function()
    if not storage.ai_player then return end
    local n = 0
    for _ in pairs(storage.ai_player.pending_requests) do n = n + 1 end
    storage.ai_player.pending_requests = {}
    game.print(string.format("[AI] Cleared %d pending request(s)", n), {r=1, g=0.8, b=0.3})
  end
)

commands.add_command("ai-memory",
  "Show AI memory (notes, todos, summary)",
  function()
    if not storage.ai_player then return end
    local mem = storage.ai_player.memory
    game.print("[AI Memory] === Notes ===", {r=0.8,g=0.8,b=1})
    if #mem.notes == 0 then
      game.print("  (none)")
    else
      for i, note in ipairs(mem.notes) do
        game.print(string.format("  %d: %s", i, note.text), {r=0.9,g=0.9,b=1})
      end
    end
    game.print("[AI Memory] === Todos ===", {r=0.8,g=1,b=0.8})
    if not next(mem.todo_lists) then
      game.print("  (none)")
    else
      for title, items in pairs(mem.todo_lists) do
        game.print("  [" .. title .. "]", {r=0.7,g=1,b=0.7})
        for i, item in ipairs(items) do
          local status = item.completed and "[DONE]" or "[ ]"
          game.print(string.format("    %s %d: %s", status, i, item.text))
        end
      end
    end
    if mem.previous_summary then
      game.print("[AI Memory] === Last Summary ===", {r=1,g=1,b=0.8})
      game.print("  " .. mem.previous_summary, {r=0.9,g=0.9,b=0.7})
    end
    if mem.user_directive then
      game.print("[AI Memory] === Active Directive ===", {r=1,g=0.8,b=0.5})
      game.print("  " .. mem.user_directive, {r=1,g=0.9,b=0.6})
    end
  end
)

-- The panel's buttons run the same functions as the console commands.
AIGui.set_actions({
  give_directive = give_directive,
  bring_ai_to = bring_ai_to,
  run_skill_text = run_skill_text,
})

-- An owned entity was destroyed: drop it from the owned set (registry.lua).
script.on_event(defines.events.on_object_destroyed, function(event)
  if event.type == defines.target_type.entity then AIRegistry.disown(event.useful_id) end
end)

-- -------------------------------------------------------------------------
-- AI Monitoring Station: Observation bunker driving lifecycle & commands
-- -------------------------------------------------------------------------
script.on_event(defines.events.on_player_driving_changed_state, function(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end
  local vehicle = player.vehicle
  if vehicle and vehicle.valid and vehicle.name == "ai-monitoring-station" then
    StationGui.open(player, vehicle)
  else
    StationGui.close(player)
  end
end)

commands.add_command("ai-station",
  "Deploy an AI Monitoring Station next to you or receive one in inventory",
  function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    if not player then
      game.print("[AI Station] Run this command in-game as a player.")
      return
    end
    if not (player.character and player.character.valid) then
      game.print("[AI Station] Player character not found.")
      return
    end

    local surface = player.character.surface
    local pos = surface.find_non_colliding_position("ai-monitoring-station", player.character.position, 15, 1)
    if pos then
      local station = surface.create_entity{
        name = "ai-monitoring-station",
        position = pos,
        force = player.force
      }
      if station then
        player.print(string.format("[AI Station] Monitoring Station deployed at {%.1f, %.1f}. Press Enter next to it to enter observation deck!", pos.x, pos.y), {r=0.4, g=1, b=0.4})
        return
      end
    end

    local n = player.insert{name = "ai-monitoring-station", count = 1}
    if n > 0 then
      player.print("[AI Station] Placed 1 AI Monitoring Station into your inventory.", {r=0.4, g=1, b=0.4})
    else
      player.print("[AI Station] Inventory is full and no valid build space nearby.", {r=1, g=0.5, b=0.2})
    end
  end
)
