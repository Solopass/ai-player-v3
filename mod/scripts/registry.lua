-- Event-driven machine registry.
--
-- A maintained SET of this AI force's production machines, keyed by unit_number,
-- so perception does NOT rescan the whole surface every tick (see
-- perception.lua gather_factory). Correctness model, in order of authority:
--   1. reconcile()  — periodic full surface scan; the backbone. Rebuilds the set
--                     from scratch, so anything missed by events self-corrects.
--   2. add()/remove()— event-driven updates for immediacy between reconciles.
--   3. lazy pruning  — machines() drops invalid refs on read (covers AI self-
--                     mining and any destroy path that fired no event).
--
-- LuaEntity references persist in `storage` across save/load (becoming invalid
-- if destroyed), so the set survives save/load with no work; only a fresh game
-- or a mod update needs the first reconcile.

AIRegistry = {}

-- Production machines worth tracking (mirrors perception MACHINE_TYPES).
local TRACKED_TYPES = {
  ["assembling-machine"] = true, ["furnace"] = true, ["mining-drill"] = true,
  ["lab"] = true, ["boiler"] = true, ["generator"] = true, ["ammo-turret"] = true,
  ["offshore-pump"] = true, ["pump"] = true, ["rocket-silo"] = true,
}

-- Array form for find_entities_filtered + a type-OR filter list for events.
local TYPE_LIST = {}
local EVENT_FILTERS = {}
for t in pairs(TRACKED_TYPES) do
  TYPE_LIST[#TYPE_LIST + 1] = t
  -- First filter must have NO mode; subsequent ones OR onto it. (Note: the
  -- `cond and nil or x` idiom can't express this — nil is falsy — so branch.)
  local f = {filter = "type", type = t}
  if #EVENT_FILTERS > 0 then f.mode = "or" end
  EVENT_FILTERS[#EVENT_FILTERS + 1] = f
end

function AIRegistry.is_tracked_type(t) return TRACKED_TYPES[t] == true end
function AIRegistry.event_filters() return EVENT_FILTERS end

local function store()
  storage.ai_player.machines = storage.ai_player.machines or {}
  return storage.ai_player.machines
end

local function ai_force_name()
  return storage.ai_player and storage.ai_player.force_name
end

-- Register a machine. Ignores non-tracked types and entities not on the AI force,
-- so human/enemy builds never enter the set.
function AIRegistry.add(entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  if not TRACKED_TYPES[entity.type] then return end
  if entity.force.name ~= ai_force_name() then return end
  store()[entity.unit_number] = entity
end

function AIRegistry.remove(unit_number)
  if unit_number then store()[unit_number] = nil end
end

-- Per-tick read path: valid tracked machines on the AI's current surface as a
-- plain array, pruning invalid refs as we go. No surface query. Build events
-- add machines from every surface, so filter to the planet the AI is on.
local function current_surface_index()
  local s = AICharacter.get_surface()
  return s and s.index
end

function AIRegistry.machines()
  local m = store()
  local si = current_surface_index()
  local out = {}
  for un, e in pairs(m) do
    if not e.valid then m[un] = nil
    elseif e.surface_index == si then out[#out + 1] = e end
  end
  return out
end

function AIRegistry.count()
  local m = store()
  local si = current_surface_index()
  local n = 0
  for un, e in pairs(m) do
    if not e.valid then m[un] = nil
    elseif e.surface_index == si then n = n + 1 end
  end
  return n
end

-- Full reconciliation: rebuild the set from a surface scan. The authoritative
-- correction path — call periodically (not every tick) and on load/update.
function AIRegistry.reconcile(surface, force)
  if not (surface and force) then return end
  local m = {}
  for _, e in ipairs(surface.find_entities_filtered{force = force, type = TYPE_LIST}) do
    if e.valid and e.unit_number then m[e.unit_number] = e end
  end
  storage.ai_player.machines = m
  storage.ai_player.last_reconcile_tick = game.tick
end

-- ---------------------------------------------------------------------------
-- Owned set: entities the AI itself placed (storage.ai_player.owned, keyed by
-- unit_number). tend works from this, never from a surface scan: in co-op the AI
-- shares the player force, so a scan would walk the human's whole base.
-- "Owned" still also needs last_user == nil (see skills.lua ai_owned). NB: script
-- entities from other mods have last_user nil too, which is why membership here,
-- not last_user alone, decides what tend touches.
-- ---------------------------------------------------------------------------
local function owned_store()
  storage.ai_player.owned = storage.ai_player.owned or {}
  return storage.ai_player.owned
end

function AIRegistry.own(entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  owned_store()[entity.unit_number] = entity
  script.register_on_object_destroyed(entity)
end

function AIRegistry.disown(unit_number)
  if unit_number and storage.ai_player and storage.ai_player.owned then
    storage.ai_player.owned[unit_number] = nil
  end
end

-- Valid owned entities of the given types on `surface` (pruning dead refs).
function AIRegistry.owned(surface, types)
  local set = {}
  for _, t in ipairs(types) do set[t] = true end
  local out = {}
  local m = owned_store()
  for un, e in pairs(m) do
    if not e.valid then m[un] = nil
    elseif e.surface == surface and set[e.type] and e.last_user == nil then out[#out + 1] = e end
  end
  return out
end

-- One-off rebuild for saves that predate the owned set: everything on the AI force
-- with last_user nil within OWNED_RADIUS of each surface's home.
local OWNED_RADIUS = 300
function AIRegistry.rebuild_owned(types)
  if not storage.ai_player then return end
  local force = game.forces[storage.ai_player.force_name]
  local m = {}
  storage.ai_player.owned = m
  if not force then return end
  for _, surface in pairs(game.surfaces) do
    local home = AICharacter.get_home(surface)
    if home then
      for _, e in ipairs(surface.find_entities_filtered{force = force, position = home, radius = OWNED_RADIUS,
                                                        type = types}) do
        if e.valid and e.unit_number and e.last_user == nil then
          m[e.unit_number] = e
          script.register_on_object_destroyed(e)
        end
      end
    end
  end
end

return AIRegistry
