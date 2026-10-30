-- Manages the AI player character entity and force.

AICharacter = {}

local FORCE_NAME = "ai_player_force"
-- Where the AI starts when it has never been anywhere else. After that it
-- follows its character: whatever surface (planet) the character is on.
local DEFAULT_SURFACE = "nauvis"

local STARTING_ITEMS = {
  {name = "wood",                count = 50},
  {name = "coal",                count = 100},
  {name = "stone",               count = 50},
  {name = "iron-plate",          count = 50},
  {name = "copper-plate",        count = 30},
  {name = "burner-mining-drill", count = 4},
  {name = "stone-furnace",       count = 4},
  {name = "burner-inserter",     count = 10},
  {name = "transport-belt",      count = 50},
  {name = "small-electric-pole", count = 20},
  {name = "assembling-machine-1",count = 2},
  {name = "offshore-pump",       count = 1},
  {name = "boiler",              count = 2},
  {name = "steam-engine",        count = 2},
  {name = "pipe",                count = 20},
  {name = "iron-chest",          count = 4},
  {name = "lab",                 count = 1},
}

function AICharacter.create_force()
  if game.forces[FORCE_NAME] then
    return game.forces[FORCE_NAME]
  end

  local force = game.create_force(FORCE_NAME)
  force.set_friend("player", true)
  game.forces["player"].set_friend(FORCE_NAME, true)
  force.set_cease_fire("player", true)
  game.forces["player"].set_cease_fire(FORCE_NAME, true)

  game.print("[AI] Force created", {r=0, g=1, b=1})
  return force
end

-- The force the AI currently operates on. Driven by storage.ai_player.force_name,
-- which doubles as the co-op/solo switch: "player" = co-op (rides the human's
-- force — shared base view, power, research), anything else = solo (own force).
function AICharacter.get_force()
  local name = (storage.ai_player and storage.ai_player.force_name) or FORCE_NAME
  return game.forces[name] or game.forces["player"]
end

-- Flip co-op (enabled=true → player force) vs solo (enabled=false → own force).
-- Reversible: re-parents the live character and re-scopes the machine registry,
-- so perception immediately reflects the new force's base. Returns the new mode.
function AICharacter.set_coop(enabled)
  local target = enabled and "player" or FORCE_NAME
  if not enabled then AICharacter.create_force() end  -- ensure the solo force exists
  storage.ai_player.force_name = target
  local force = game.forces[target]

  local character = AICharacter.get_character()
  if character and character.valid and force then
    character.force = force
  end
  -- Re-scope the registry to the new force so the factory view updates now.
  if force then
    AIRegistry.reconcile(AICharacter.get_surface(), force)
  end
  return { coop = (target == "player"), force = target }
end

-- The surface the AI lives on: its character's surface, else the last surface
-- it was seen on (kept across death/respawn), else Nauvis.
function AICharacter.get_surface()
  local ap = storage.ai_player
  local c = ap and ap.character
  if c and c.valid then return c.surface end
  local name = ap and ap.surface_name
  return (name and game.surfaces[name]) or game.surfaces[DEFAULT_SURFACE]
end

function AICharacter.remember_surface(surface)
  if storage.ai_player and surface and surface.valid then
    storage.ai_player.surface_name = surface.name
  end
end

-- One home anchor per surface. Saves from before multi-planet support stored a
-- single anchor in home_position; it is treated as the Nauvis home.
function AICharacter.get_home(surface)
  local ap = storage.ai_player
  if not ap then return nil end
  surface = surface or AICharacter.get_surface()
  if not surface then return nil end
  if ap.homes and ap.homes[surface.name] then return ap.homes[surface.name] end
  if surface.name == DEFAULT_SURFACE then return ap.home_position end
  return nil
end

function AICharacter.set_home(surface, pos)
  local ap = storage.ai_player
  ap.homes = ap.homes or {}
  local home = {x = math.floor(pos.x), y = math.floor(pos.y)}
  ap.homes[surface.name] = home
  if surface.name == DEFAULT_SURFACE then ap.home_position = home end
end

-- Every AI character (no controlling/associated player) on the force, across
-- all surfaces.
function AICharacter.find_all_ai_characters(force)
  local out = {}
  for _, s in pairs(game.surfaces) do
    for _, c in ipairs(s.find_entities_filtered{type = "character", force = force}) do
      if c.valid and c.player == nil and c.associated_player == nil then
        out[#out + 1] = c
      end
    end
  end
  return out
end

-- surface: where to spawn (e.g. the surface of the player who ran the
-- command). Defaults to the AI's current/last surface.
function AICharacter.spawn_ai_player(surface)
  if storage.ai_player.character and storage.ai_player.character.valid then
    storage.ai_player.character.destroy()
  end

  local force = AICharacter.get_force()
  surface = surface or AICharacter.get_surface()
  local pos = AICharacter.find_spawn_position(surface)

  local character = surface.create_entity{
    name = "character",
    position = pos,
    force = force
  }

  if not character then
    game.print("[AI] Failed to create character", {r=1, g=0, b=0})
    return false
  end

  AICharacter.give_starting_items(character)
  storage.ai_player.character = character
  AICharacter.remember_surface(surface)

  -- Anchor the home/base location on first spawn on this surface so the AI can
  -- navigate back and avoid wandering. Persists across respawns (only set when
  -- missing).
  if not AICharacter.get_home(surface) then
    AICharacter.set_home(surface, pos)
  end

  game.print(string.format("[AI] Spawned at {%.1f, %.1f}", pos.x, pos.y), {r=0, g=1, b=0})
  return true
end

function AICharacter.find_spawn_position(surface)
  -- Try near the lowest-index connected player first
  local candidates = {}
  for _, player in ipairs(game.connected_players) do
    if player.valid and player.character and player.character.valid
       and player.character.surface == surface then
      table.insert(candidates, player)
    end
  end
  table.sort(candidates, function(a, b) return a.index < b.index end)

  local offsets = {
    {x=20,y=0},{x=14,y=14},{x=0,y=20},{x=-14,y=14},
    {x=-20,y=0},{x=-14,y=-14},{x=0,y=-20},{x=14,y=-14}
  }

  for _, player in ipairs(candidates) do
    local base = player.character.position
    for _, off in ipairs(offsets) do
      local pos = {x = base.x + off.x, y = base.y + off.y}
      if surface.can_place_entity{name="character", position=pos} then
        return pos
      end
    end
  end

  -- Scan origin area
  for x = -50, 50, 5 do
    for y = -50, 50, 5 do
      local pos = {x=x, y=y}
      if surface.can_place_entity{name="character", position=pos} then
        return pos
      end
    end
  end

  return {x=0, y=0}
end

function AICharacter.give_starting_items(character)
  local inv = character.get_inventory(defines.inventory.character_main)
  if not inv then return end

  for _, item in ipairs(STARTING_ITEMS) do
    if prototypes.item[item.name] then
      inv.insert(item)
    end
  end

  local guns = character.get_inventory(defines.inventory.character_guns)
  local ammo = character.get_inventory(defines.inventory.character_ammo)
  if guns  and prototypes.item["pistol"]           then guns.insert{name="pistol", count=1} end
  if ammo  and prototypes.item["firearm-magazine"] then ammo.insert{name="firearm-magazine", count=200} end
end

function AICharacter.is_alive()
  return storage.ai_player.character and storage.ai_player.character.valid
end

function AICharacter.get_character()
  return AICharacter.is_alive() and storage.ai_player.character or nil
end

function AICharacter.get_health_percentage()
  local c = AICharacter.get_character()
  if not c then return 0 end
  return (c.health / (c.max_health or 250)) * 100
end

return AICharacter
