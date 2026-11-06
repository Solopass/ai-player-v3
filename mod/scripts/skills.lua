-- Skill layer (v3).
--
-- A "skill" is a parameterized basic loop. Skills own the deterministic MECHANICS
-- (positions, orientation, fuelling, drop-positions); the LLM only chooses which
-- skill and its params. Skills orchestrate the proven PRIMITIVE handlers
-- (AIActions.run) wherever possible, so placement legality / slot resolution /
-- mining all stay in one place (primitives.lua).
--
-- Each skill: function(character, params) -> (ok:boolean, detail:string)
-- detail feeds the E1 result loop, so make it specific and actionable.

AISkills = {}

local function inv_of(character)
  return character.get_inventory(defines.inventory.character_main)
end

-- -------------------------------------------------------------------------
-- gather(item, count) — mine the nearest sources of `item` until `count`.
-- Handles wood (mine trees by type) and ores/rocks (mine by name).
-- -------------------------------------------------------------------------
local function skill_gather(character, p)
  local item = p.item
  if not item then return false, "gather: missing 'item'" end
  local need = math.min(p.count or 50, 300)
  local surface = character.surface
  local inv = inv_of(character)
  local is_wood = (item == "wood")
  local gained = 0

  for _ = 1, 150 do
    if inv.get_item_count(item) >= need then break end
    local filter = {position = character.position, radius = 40, limit = 60}
    if is_wood then filter.type = "tree" else filter.name = item end
    local sources = surface.find_entities_filtered(filter)
    local src, sd = nil, math.huge
    for _, e in ipairs(sources) do
      if e.valid and e.minable and e ~= character then
        local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
        local d = dx * dx + dy * dy
        if d < sd then sd = d; src = e end
      end
    end
    if not src then break end
    -- Teleport adjacent so the source is within mining reach, then mine.
    local sp = surface.find_non_colliding_position("character", src.position, 3, 0.5)
    if sp then character.teleport(sp) end
    local before = inv.get_item_count()
    character.mine_entity(src, true)
    local delta = inv.get_item_count() - before
    if delta <= 0 then break end  -- inventory full or stuck
    gained = gained + delta
  end

  local have = inv.get_item_count(item)
  if gained == 0 then
    return false, "gather: no reachable " .. item .. " sources within 40 tiles"
  end
  return true, string.format("gathered %d %s (now have %d)", gained, item, have)
end

-- -------------------------------------------------------------------------
-- build_smelter(ore, count) — place stone-furnaces, fuel them, feed ore.
-- Orchestrates the place + insert primitives at computed positions.
-- -------------------------------------------------------------------------
local function skill_build_smelter(character, p)
  local ore = p.ore or p.item or "iron-ore"
  local want = math.min(p.count or 2, 6)
  local surface = character.surface
  local inv = inv_of(character)

  local have_furnace = inv.get_item_count("stone-furnace")
  if have_furnace == 0 then
    local queued = character.begin_crafting{recipe = "stone-furnace", count = 1}
    if queued > 0 then
      return false, "build_smelter: out of stone-furnaces — hand-crafting one, retry next turn"
    end
    return false, "build_smelter: no stone-furnace and can't craft one (need stone)"
  end

  local count = math.min(want, have_furnace)
  -- A tidy row near home (2x2 furnaces on even coordinates), not wherever the
  -- AI happens to stand.
  local home = AICharacter.get_home(surface) or character.position
  local base = {x = math.floor(home.x / 2) * 2 + 6, y = math.floor(home.y / 2) * 2 - 6}
  local placed = 0
  for i = 1, count do
    local anchor = {x = base.x + (i - 1) * 2, y = base.y}
    local pos = surface.find_non_colliding_position("stone-furnace", anchor, 8, 2)
    if pos then
      local ok = AIActions.run(character, {action = "place", item = "stone-furnace", position = pos})
      if ok then
        placed = placed + 1
        if inv.get_item_count("coal") > 0 then
          AIActions.run(character, {action = "insert", item = "coal", count = 8, position = pos, inventory = "fuel"})
        end
        if inv.get_item_count(ore) > 0 then
          AIActions.run(character, {action = "insert", item = ore, count = 12, position = pos, inventory = "input"})
        end
      end
    end
  end

  if placed == 0 then
    return false, "build_smelter: couldn't place any furnace (no clear space nearby)"
  end
  local detail = string.format("built %d stone-furnace(s) for %s", placed, ore)
  if inv.get_item_count(ore) == 0 then
    detail = detail .. " — but you have no " .. ore .. " to smelt; gather " .. ore .. " first"
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- build_miner(resource, output) — place a burner-mining-drill ON the nearest
-- resource patch, fuel it, and place a collector (chest/furnace/belt) at its
-- drop_position. The drill→output basic loop.
-- -------------------------------------------------------------------------
local OUTPUT_ITEM = {chest = "iron-chest", furnace = "stone-furnace", belt = "transport-belt"}

-- The collector to put at a drill's drop position. A chest is a wooden-chest
-- when there's one (or wood for one), so early iron goes into drills/furnaces.
-- Returns the item name the AI has now, or nil + the item it's crafting/missing.
local function ready_collector(character, out_kind)
  local inv = inv_of(character)
  local wanted = out_kind == "chest" and {"wooden-chest", "iron-chest"} or {OUTPUT_ITEM[out_kind] or "iron-chest"}
  for _, name in ipairs(wanted) do
    if inv.get_item_count(name) > 0 then return name end
  end
  for _, name in ipairs(wanted) do
    local r = character.force.recipes[name]
    if r and r.enabled and character.get_craftable_count(r) > 0 then
      character.begin_crafting{recipe = r, count = 1, silent = true}
      return nil, name, true
    end
  end
  return nil, wanted[1], false
end

local build_electric_miner      -- defined below, once stock_up exists

local function skill_build_miner(character, p)
  local resource = p.resource or p.item or "iron-ore"
  local out_kind = (p.output or "chest"):lower()
  -- Coal and stone can't be smelted into anything useful early: store them.
  if out_kind == "furnace" and (resource == "coal" or resource == "stone") then out_kind = "chest" end
  local want = math.max(1, math.min(tonumber(p.count) or 1, 6))
  local inv = inv_of(character)

  -- Past the burner stage (drill researched, drill in hand or craftable, a pole to
  -- wire to): electric drills into furnaces, or into chests for coal/stone.
  local is_electric = character.force.recipes["electric-mining-drill"]
    and character.force.recipes["electric-mining-drill"].enabled
  if out_kind == "field" and not is_electric then
    return false, "build_miner: output=field needs the electric-mining-drill tech"
  end
  if out_kind == "furnace" or out_kind == "chest" or is_electric then
    local ok, detail = build_electric_miner(character, resource, want, out_kind)
    if ok ~= nil then return ok, detail end
  end
  if is_electric then
    return false, "build_miner: electric drills researched; burner drills are phased out. Build power grid or craft materials for electric drill."
  end
  if p.drill == "electric" then
    return false, "build_miner: electric drills need the tech, a drill in hand or craftable, "
      .. "and a powered pole within reach — build_power or extend poles first"
  end

  local drills = inv.get_item_count("burner-mining-drill")
  if drills == 0 then
    character.begin_crafting{recipe = "burner-mining-drill", count = math.min(want, 2), silent = true}
    return false, "build_miner: no burner-mining-drill in inventory — crafting, retry next move"
  end
  want = math.min(want, drills)
  local center = character.position

  if character.surface.count_entities_filtered{name = resource, type = "resource", position = center, radius = 64, limit = 1} == 0 then
    local lm
    for _, r in ipairs((AIPerception.landmarks(character.surface, center) or {}).resources or {}) do
      if r.name == resource then lm = r; break end
    end
    return false, "build_miner: no " .. resource .. " within 64 tiles"
      .. (lm and string.format(" — nearest patch is at {%d,%d}, goto it first", lm.x, lm.y) or " — explore")
  end

  if out_kind == "belt" then
    local chest = inv.get_item_count("wooden-chest") > 0 and "wooden-chest" or "iron-chest"
    local plan = AILayout.find_drill_row(character, resource, center, {count = math.max(2, want), chest = chest})
    if not plan then
      return false, "build_miner: no straight stretch of " .. resource .. " for a row of "
        .. math.max(2, want) .. " drills — try output=furnace or chest"
    end
    local missing = {}
    for name, n in pairs(AILayout.items({plan})) do
      if inv.get_item_count(name) < n then missing[#missing + 1] = (n - inv.get_item_count(name)) .. "x " .. name end
    end
    if #missing > 0 then
      return false, "build_miner: a belt row needs " .. table.concat(missing, ", ") .. " more"
    end
    local ok, res = AILayout.build(character, plan)
    if not ok then return false, "build_miner: " .. res end
    local d = res[1].position
    return true, string.format("built %d drills on %s at {%d,%d} facing %s onto a belt (flowing %s) into a %s",
      math.max(2, want), resource, math.floor(d.x), math.floor(d.y), plan.facing, plan.flow, chest)
  end

  local collector, need, crafting = ready_collector(character, out_kind)
  if not collector then
    if crafting then
      return false, "build_miner: crafting a " .. need .. " for the drill's output — retry next move"
    end
    return false, "build_miner: need a " .. need .. " for the drill's output (craft_for " .. need .. ")"
  end
  want = math.min(want, inv.get_item_count(collector))

  local plans = AILayout.find_drill_spots(character, resource, center, {collector = collector, count = want})
  if #plans == 0 then
    return false, "build_miner: no spot on the " .. resource .. " patch where a drill and its "
      .. collector .. " both fit (trees/rocks/buildings in the way?) — try another patch or deconstruct"
  end
  local built, first, facing, err = 0, nil, nil, nil
  for _, plan in ipairs(plans) do
    local ok, res = AILayout.build(character, plan)
    if ok then
      built = built + 1
      first = first or res[1].position
      facing = facing or plan.facing
    else
      err = res
    end
  end
  if built == 0 then return false, "build_miner: " .. (err or "placement failed") end
  local detail = string.format("built %d drill→%s pair(s) on %s at {%d,%d} (facing %s)",
    built, collector, resource, math.floor(first.x), math.floor(first.y), facing)
  if built < (tonumber(p.count) or 1) then
    detail = detail .. string.format("; wanted %d — short on drills/%s or space", tonumber(p.count) or 1, collector)
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- stock_up(need) — hand-craft whatever a plan is short of. Returns true when
-- everything is in the inventory, else false + what is being crafted/missing
-- so the skill can say so and the next move retries.
-- -------------------------------------------------------------------------
local function stock_up(character, need, skill)
  local inv = inv_of(character)
  local crafting, missing = {}, {}
  for name, n in pairs(need) do
    local short = n - inv.get_item_count(name)
    if short > 0 then
      local r = character.force.recipes[name]
      local queued = 0
      if r and r.enabled and character.get_craftable_count(r) > 0 then
        queued = character.begin_crafting{recipe = r, count = math.min(short, character.get_craftable_count(r)),
                                          silent = true}
      end
      if queued >= short then crafting[#crafting + 1] = short .. "x " .. name
      else missing[#missing + 1] = (short - queued) .. "x " .. name end
    end
  end
  table.sort(crafting); table.sort(missing)
  if #missing > 0 then
    return false, skill .. ": need " .. table.concat(missing, ", ") .. " more (craft_for them; plates are smelted, not crafted)"
  end
  if #crafting > 0 then
    return false, skill .. ": crafting " .. table.concat(crafting, ", ") .. " — retry next move"
  end
  return true
end

-- -------------------------------------------------------------------------
-- build_power() — offshore pump on the nearest shore, boiler, 2 steam engines
-- and a pole chain toward home / the existing grid (layout.lua find_power).
-- -------------------------------------------------------------------------
local function skill_build_power(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  local force = character.force
  if surface.count_entities_filtered{name = "boiler", force = force, limit = 1} > 0
     and surface.count_entities_filtered{name = "steam-engine", force = force, limit = 1} > 0 then
    return false, "build_power: a boiler and steam engine already exist — tend them instead"
  end
  local existing_pumps = surface.count_entities_filtered{name = "offshore-pump", force = force, limit = 1}
  local lm = (AIPerception.landmarks(surface, character.position) or {}).water
  if existing_pumps == 0 and not lm then return false, "build_power: no water found near — explore" end
  if existing_pumps == 0 and lm and lm.distance > 40 then
    return false, string.format("build_power: nearest water is %d tiles away at {%d,%d} — goto it first",
                                lm.distance, lm.x, lm.y)
  end
  local home = AICharacter.get_home(surface) or character.position
  local plan = AILayout.find_power(character, character.position, home)
  if not plan then
    return false, "build_power: no shoreline spot where a pump, boiler and 2 engines fit near {"
      .. lm.x .. "," .. lm.y .. "} — try another shore"
  end
  local ready, why = stock_up(character, AILayout.items({plan}), "build_power")
  if not ready then return false, why end
  local ok, res = AILayout.build(character, plan)
  if not ok then return false, "build_power: " .. res end
  for _, p in ipairs(res) do
    if p.entity and p.entity.valid then AIRegistry.own(p.entity) end
  end
  local poles = 0
  for _, p in ipairs(res) do if p.role == "pole" then poles = poles + 1 end end
  local pump = res[1].position
  return true, string.format("built steam power: pump at {%d,%d}, boiler (fuelled), 2 steam engines, %d pole(s)%s",
    math.floor(pump.x), math.floor(pump.y), poles,
    plan.joined and ", wired into the existing grid" or " toward home — connect consumers with more poles")
end

-- -------------------------------------------------------------------------
-- fuel_all() — top up every nearby AI-force burner that's low on fuel.
-- -------------------------------------------------------------------------
local function skill_fuel_all(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  if inv.get_item_count("coal") == 0 then
    return false, "fuel_all: no coal in inventory"
  end
  local force = AICharacter.get_force()
  local fueled = 0
  for _, e in ipairs(surface.find_entities_filtered{force = force, position = character.position, radius = 64}) do
    if e.valid and e.type ~= "character" then
      local fb = e.get_fuel_inventory and e.get_fuel_inventory()
      if fb and fb.valid and fb.get_item_count("coal") < 5 then
        local avail = inv.get_item_count("coal")
        if avail > 0 then
          local ins = fb.insert{name = "coal", count = math.min(5, avail)}
          if ins > 0 then inv.remove{name = "coal", count = ins}; fueled = fueled + 1 end
        end
      end
    end
  end
  if fueled == 0 then return true, "fuel_all: every nearby burner already has fuel" end
  return true, string.format("fueled %d burner(s)", fueled)
end

-- -------------------------------------------------------------------------
-- loot_chests(radius?, items?) — pull items from nearby chests (any force)
-- into the character's inventory. Enables human→AI resource sharing (coal,
-- building materials, etc.) and AI self-restocking before build_ghosts.
-- items: comma-separated item names to restrict looting; empty = take all.
-- -------------------------------------------------------------------------
local function skill_loot_chests(character, p)
  local surface = character.surface
  local radius  = math.min(p.radius or 32, 128)
  local inv     = inv_of(character)

  local filter = nil
  -- items: "iron-plate,coal" or ["iron-plate","coal"]
  if type(p.items) == "string" and p.items ~= "" then
    filter = {}
    for name in p.items:gmatch("[^,]+") do
      filter[name:match("^%s*(.-)%s*$")] = true
    end
  elseif type(p.items) == "table" and #p.items > 0 then
    filter = {}
    for _, name in ipairs(p.items) do filter[name] = true end
  end

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  if #chests == 0 then
    return false, "loot_chests: no chests within " .. radius .. " tiles"
  end

  local taken = {}
  for _, chest in ipairs(chests) do
    if chest.valid then
      local ci = chest.get_inventory(defines.inventory.chest)
      if ci then
        for _, slot in ipairs(ci.get_contents()) do
          local name, avail = slot.name, slot.count
          if not filter or filter[name] then
            local n = inv.insert{name = name, count = avail}
            if n > 0 then
              ci.remove{name = name, count = n}
              taken[name] = (taken[name] or 0) + n
            end
          end
        end
      end
    end
  end

  if not next(taken) then
    return false, "loot_chests: nothing taken (chests empty, inventory full, or filter matched nothing)"
  end
  local parts = {}
  for name, count in pairs(taken) do parts[#parts + 1] = count .. "x " .. name end
  table.sort(parts)
  return true, "looted " .. table.concat(parts, ", ")
end

-- -------------------------------------------------------------------------
-- deposit_to_chest(radius?, keep?) — deposit excess inventory into a nearby
-- chest. Keeps `keep` of each item; deposits the rest. Use for inventory
-- management and AI→human resource sharing.
-- -------------------------------------------------------------------------
local function skill_deposit_to_chest(character, p)
  local surface = character.surface
  local radius  = math.min(p.radius or 32, 128)
  local keep    = math.max(p.keep or 50, 0)
  local inv     = inv_of(character)

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  if #chests == 0 then
    return false, "deposit_to_chest: no chests within " .. radius .. " tiles"
  end

  local cp = character.position
  table.sort(chests, function(a, b)
    local da = (a.position.x - cp.x)^2 + (a.position.y - cp.y)^2
    local db = (b.position.x - cp.x)^2 + (b.position.y - cp.y)^2
    return da < db
  end)

  local deposited = {}
  for _, slot in ipairs(inv.get_contents()) do
    local name, have = slot.name, slot.count
    local excess = have - keep
    if excess > 0 then
      for _, chest in ipairs(chests) do
        if chest.valid then
          local ci = chest.get_inventory(defines.inventory.chest)
          if ci then
            local n = ci.insert{name = name, count = excess}
            if n > 0 then
              inv.remove{name = name, count = n}
              deposited[name] = (deposited[name] or 0) + n
              excess = excess - n
            end
          end
        end
        if excess <= 0 then break end
      end
    end
  end

  if not next(deposited) then
    return false, "deposit_to_chest: nothing deposited (nothing exceeds keep=" .. keep .. " or chests full)"
  end
  local parts = {}
  for name, count in pairs(deposited) do parts[#parts + 1] = count .. "x " .. name end
  table.sort(parts)
  return true, "deposited " .. table.concat(parts, ", ")
end

-- -------------------------------------------------------------------------
-- build_ghosts() — build the human's placed entity-ghosts (validated mechanic).
-- Highest-priority skill: ghosts are explicit human intent.
-- -------------------------------------------------------------------------
local function skill_build_ghosts(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  -- Search the ENTIRE surface — ghosts may be far from the character's current
  -- position (e.g. an oil outpost blueprinted 200+ tiles away). We teleport to
  -- the nearest ghost cluster before attempting revive.
  local ghosts = surface.find_entities_filtered{type = "entity-ghost"}
  if #ghosts == 0 then return false, "build_ghosts: no ghosts on surface to build" end

  -- Find nearest ghost so we can teleport to it.
  local nearest, nd = nil, math.huge
  for _, g in ipairs(ghosts) do
    if g.valid then
      local dx = g.position.x - character.position.x
      local dy = g.position.y - character.position.y
      local d = dx * dx + dy * dy
      if d < nd then nd = d; nearest = g end
    end
  end
  if nearest then
    -- Teleport to a spot near the nearest ghost cluster so revive() can fire.
    local tp = surface.find_non_colliding_position(
      "character", {x = nearest.position.x + 3, y = nearest.position.y + 3}, 12, 0.5)
    if tp then character.teleport(tp) end
  end

  local built = 0
  local queued_crafts = 0
  local missing = {}
  for _, g in ipairs(ghosts) do
    if g.valid then
      local proto = prototypes.entity[g.ghost_name]
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
        and proto.items_to_place_this[1].name
      if item and inv.get_item_count(item) > 0 then
        -- NB: do NOT teleport the character to the ghost first. Ghosts have no
        -- collision box, so find_non_colliding_position returns the ghost's own
        -- tile; teleporting there makes the CHARACTER block the spot and revive()
        -- fails. revive() is a force-level op and needs no character reach.
        -- Only the AI's own ghosts (placed by script, so no last_user) become AI-owned.
        -- A player's ghost stays the player's even when the AI builds it, so tend
        -- never empties or refuels the player's blueprint builds.
        local ai_ghost = g.last_user == nil
        local function claim(e)
          if ai_ghost and e and e.valid then e.last_user = nil; AIRegistry.own(e) end
        end
        local _, ent = g.revive{raise_revive = false}
        claim(ent)
        if not (ent and ent.valid) then
          -- The character may be standing ON this ghost (e.g. its home tile).
          -- Step aside to a spot clear of the ghost footprint and retry once.
          local aside = surface.find_non_colliding_position(
            "character", {x = g.position.x + 3, y = g.position.y + 3}, 8, 0.5)
          if aside then
            character.teleport(aside)
            _, ent = g.revive{raise_revive = false}
            claim(ent)
          end
        end
        if ent and ent.valid then
          inv.remove{name = item, count = 1}
          built = built + 1
        end
      elseif item then
        missing[item] = (missing[item] or 0) + 1
        local r = character.force.recipes[item]
        if r and r.enabled and character.get_craftable_count(r) > 0 then
          local q = character.begin_crafting{recipe = r, count = 1, silent = true}
          if q > 0 then queued_crafts = queued_crafts + q end
        end
      end
    end
  end

  local parts = {}
  for it, c in pairs(missing) do parts[#parts + 1] = c .. "x " .. it end
  local detail = string.format("built %d ghost(s)", built)
  if #parts > 0 then detail = detail .. "; need items: " .. table.concat(parts, ", ") end
  if built == 0 and #parts == 0 then return false, "build_ghosts: no buildable ghosts" end
  if built == 0 and queued_crafts == 0 then
    return false, "build_ghosts: " .. detail .. " — craft/smelt the missing items first"
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- deconstruct() — mine everything the human marked for deconstruction
-- (buildings, trees, rocks). SECOND priority after build_ghosts: a
-- deconstruction mark is explicit human "remove this" intent, the mirror of a
-- ghost. Unlike ghosts/ore, these targets HAVE collision, so teleporting
-- adjacent (the gather pattern) is safe — find_non_colliding_position lands the
-- character beside the target, not on it, and mine_entity collects the products.
-- -------------------------------------------------------------------------
local function skill_deconstruct(character, p)
  local surface = character.surface
  local inv = inv_of(character)
  local radius = math.min(p.radius or 96, 200)
  local marked = surface.find_entities_filtered{
    to_be_deconstructed = true, position = character.position, radius = radius, limit = 100}
  if #marked == 0 then
    return false, "deconstruct: nothing marked for deconstruction within " .. radius .. " tiles"
  end

  -- Nearest-first so the character walks an efficient path and stays near base.
  local cp = character.position
  table.sort(marked, function(a, b)
    local dax, day = a.position.x - cp.x, a.position.y - cp.y
    local dbx, dby = b.position.x - cp.x, b.position.y - cp.y
    return (dax * dax + day * day) < (dbx * dbx + dby * dby)
  end)

  local removed, skipped = 0, 0
  for _, m in ipairs(marked) do
    if m.valid and m ~= character then
      if not m.minable then
        skipped = skipped + 1
      else
        local sp = surface.find_non_colliding_position("character", m.position, 3, 0.5)
        if sp then character.teleport(sp) end
        local ok = character.mine_entity(m, true)
        if ok and not m.valid then
          removed = removed + 1
        elseif m.valid then
          break  -- inventory full or out of reach — stop rather than spin
        end
      end
    end
  end

  if removed == 0 then
    if skipped > 0 then return false, "deconstruct: marked objects can't be mined (unminable)" end
    return false, "deconstruct: couldn't mine any marked object (inventory full?)"
  end
  local detail = string.format("deconstructed %d marked object(s)", removed)
  if skipped > 0 then detail = detail .. string.format("; %d unminable skipped", skipped) end
  return true, detail
end

-- -------------------------------------------------------------------------
-- return_home() — walk back to the home anchor.
-- -------------------------------------------------------------------------
local function skill_return_home(character, _)
  local home = AICharacter.get_home()
  if not home then return false, "return_home: no home anchor set" end
  local surface = character.surface
  local sp = surface.find_non_colliding_position("character", {x = home.x, y = home.y}, 8, 0.5)
  if not sp then return false, "return_home: home area is blocked" end
  character.teleport(sp)
  return true, string.format("returned home to {%d,%d}", home.x, home.y)
end

-- -------------------------------------------------------------------------
-- research(tech?) — queue a technology on the AI force. WITHOUT this, a fed
-- lab does nothing: a separate force researches nothing unless something is
-- queued. Picks a sensible next tech if none is given.
-- -------------------------------------------------------------------------
local PREFERRED_TECH = {
  "automation", "electronics", "steel-processing", "logistics",
  "fast-inserter", "logistic-science-pack",
}

-- Techs to queue, in order, whenever nothing is being researched (the reflexes' auto-research
-- and, via perception.research.order, the bridge planner use this one list). {tech, needs_green}:
-- green-pack techs wait until green science has been made. Economy first; military techs move to
-- front only when threat is detected (nest within 150 tiles or attack in last 10 min).
AISkills.RESEARCH_ORDER = {
  {"automation", false}, {"electric-mining-drill", false},
  {"logistics", false}, {"electronics", false},
  {"logistic-science-pack", false}, {"steel-processing", false},
  {"automation-2", true}, {"fast-inserter", true},
  {"gun-turret", false}, {"military", false}, {"stone-wall", false},
  {"physical-projectile-damage-1", false}, {"weapon-shooting-speed-1", false},
  {"engine", true}, {"electric-energy-distribution-1", true},
  {"toolbelt", true}, {"advanced-material-processing", true},
  {"oil-processing", true}, {"plastics", true}, {"advanced-circuit", true},
  {"sulfur-processing", true}, {"chemical-science-pack", true},
  {"robotics", true}, {"construction-robotics", true},
}

function AISkills.has_active_threat()
  local s = storage.ai_player
  if not s then return false end
  local atk = s.last_attack
  if atk and (game.tick - atk.tick < 36000) then return true end
  local tc = s.threat_cache
  if tc and tc.nd and tc.nd <= 150 then return true end
  return false
end

function AISkills.get_research_order()
  if not AISkills.has_active_threat() then
    return AISkills.RESEARCH_ORDER
  end
  local mil = {}
  local other = {}
  local is_mil = {
    ["gun-turret"] = true, ["military"] = true, ["stone-wall"] = true,
    ["physical-projectile-damage-1"] = true, ["weapon-shooting-speed-1"] = true,
  }
  for _, e in ipairs(AISkills.RESEARCH_ORDER) do
    if is_mil[e[1]] then
      table.insert(mil, e)
    else
      table.insert(other, e)
    end
  end
  local combined = {}
  for _, e in ipairs(mil) do table.insert(combined, e) end
  for _, e in ipairs(other) do table.insert(combined, e) end
  return combined
end

local function prereqs_met(tech)
  for _, pre in pairs(tech.prerequisites) do
    if not pre.researched then return false end
  end
  return true
end

-- A tech is QUEUEABLE only if it isn't a research_trigger tech (those are
-- completed by crafting/doing something, not by add_research) and add_research
-- actually accepts it. Returns true on success (it queues as a side effect).
local function try_queue(force, tech)
  if not (tech and tech.enabled and not tech.researched and prereqs_met(tech)) then return false end
  if tech.prototype.research_trigger ~= nil then return false end
  return force.add_research(tech)
end

-- Queue the first tech of RESEARCH_ORDER that can be queued now; returns its name or nil.
function AISkills.queue_next_research(force, green_made)
  for _, e in ipairs(AISkills.get_research_order()) do
    if (green_made or not e[2]) and try_queue(force, force.technologies[e[1]]) then return e[1] end
  end
  return nil
end

-- "craft 1 lab" etc. for a tech whose research_trigger unlocks it; nil when it
-- has none. Trigger targets may be names or {name, quality} filters.
function AISkills.trigger_info(tech)
  local trig = tech.prototype.research_trigger
  if not trig then return nil end
  local function nm(v) return type(v) == "table" and v.name or v end
  local target = nm(trig.item) or trig.fluid or nm(trig.entity)
              or (trig.entities and table.concat(trig.entities, "/"))
  return {tech = tech.name, type = trig.type, target = target,
          count = trig.count or trig.amount or 1}
end

local TRIGGER_VERB = {
  ["craft-item"] = "hand-craft", ["mine-entity"] = "mine", ["build-entity"] = "build",
  ["craft-fluid"] = "produce", ["send-item-to-orbit"] = "launch",
  ["capture-spawner"] = "capture", ["create-space-platform"] = "create a space platform",
}

local function trigger_text(tech)
  local t = AISkills.trigger_info(tech)
  if not t then return nil end
  if t.type == "scripted" then return "tech " .. t.tech .. " is unlocked by a scripted event" end
  return string.format("tech %s unlocks when you %s %s%s", t.tech, TRIGGER_VERB[t.type] or t.type,
                       t.target and (t.count .. "x " .. t.target) or "",
                       t.type == "craft-item" and " (crafting NEW ones counts; ones you already hold don't)" or "")
end

local function skill_research(character, p)
  local force = character.force

  if p.tech then
    local tech = force.technologies[p.tech]
    local cur = force.current_research
    if cur and cur.name == p.tech then
      return true, "already researching " .. p.tech .. " — feed a lab with science packs"
    end
    if try_queue(force, tech) then
      return true, "queued research: " .. p.tech .. " — feed a lab with science packs to progress"
    end
    -- An explicit choice never falls back to some other tech.
    return false, (tech and trigger_text(tech))
      or ("research: can't queue " .. p.tech .. " (unknown, already done, or prerequisites missing)")
  end
  for _, name in ipairs(PREFERRED_TECH) do
    if try_queue(force, force.technologies[name]) then
      return true, "queued research: " .. name .. " — feed a lab with science packs to progress"
    end
  end
  for _, t in pairs(force.technologies) do
    if try_queue(force, t) then
      return true, "queued research: " .. t.name .. " — feed a lab with science packs to progress"
    end
  end

  -- Nothing queueable: the next research is likely a TRIGGER tech (Factorio 2.0
  -- bootstraps via crafting, not queuing). Tell the model to craft the science.
  for _, t in pairs(force.technologies) do
    if t.enabled and not t.researched and prereqs_met(t) and t.prototype.research_trigger ~= nil then
      return false, "research: nothing can be queued yet — " .. trigger_text(t)
        .. " (see research.triggers); research then opens up"
    end
  end
  return false, "research: nothing to queue right now"
end

-- -------------------------------------------------------------------------
-- goto(position) — teleport the character to an arbitrary map coordinate.
-- Use when you need to reach a location before performing other actions
-- (e.g. inspecting a distant outpost or approaching a ghost cluster manually).
-- -------------------------------------------------------------------------
local function skill_goto(character, p)
  local pos = p.position
  if not pos or pos.x == nil or pos.y == nil then
    return false, "goto: 'position' must be {x=N, y=N}"
  end
  local surface = character.surface
  local target = {x = tonumber(pos.x), y = tonumber(pos.y)}
  local safe = surface.find_non_colliding_position("character", target, 5, 0.5) or target
  character.teleport(safe)
  return true, string.format("moved to (%.0f, %.0f)", safe.x, safe.y)
end

-- -------------------------------------------------------------------------
-- place_blueprint(name[, position, resource]) — stamp a library blueprint down
-- as ghosts at a suitable spot (clear ground / ore patch / shoreline, from the
-- blueprint's placement type). build_ghosts then builds it.
-- -------------------------------------------------------------------------
local function skill_place_blueprint(character, p)
  if not p.name then return false, "place_blueprint: 'name' is required" end
  return AIBlueprints.place(character, p.name, {position = p.position, resource = p.resource})
end

-- -------------------------------------------------------------------------
-- craft_for(item[, count]) — hand-craft `item` up to `count` in inventory,
-- including intermediates, and report the raw materials still missing.
-- Smelted items (plates, steel) can't be hand-crafted; they are reported as
-- raw so the model knows to smelt or gather them.
-- -------------------------------------------------------------------------
local function handcraftable(character, recipe)
  local cats = character.prototype.crafting_categories or {}
  for _, c in ipairs(recipe.categories or {}) do
    if cats[c] then return true end
  end
  return false
end

local function product_amount(recipe, item)
  for _, pr in ipairs(recipe.products) do
    if pr.name == item then return pr.amount or pr.amount_min or 1 end
  end
  return 1
end

-- Walk the recipe tree for `amount` of `item`, consuming `have` (a mutable
-- copy of the inventory) and adding anything not hand-craftable to `out`.
local function raw_shortfall(character, item, amount, have, out, depth, visiting)
  local avail = have[item] or 0
  if avail >= amount then have[item] = avail - amount; return end
  local need = amount - avail
  have[item] = 0
  local r = character.force.recipes[item]
  if depth < 6 and r and r.enabled and handcraftable(character, r) and not visiting[item] then
    visiting[item] = true
    local crafts = math.ceil(need / product_amount(r, item))
    for _, ing in ipairs(r.ingredients) do
      if ing.type == "item" then
        raw_shortfall(character, ing.name, ing.amount * crafts, have, out, depth + 1, visiting)
      end
    end
    visiting[item] = nil
  else
    out[item] = (out[item] or 0) + need
  end
end

-- How a locked recipe gets unlocked. In 2.x some early techs (steam-power,
-- electronics, automation-science-pack, ...) unlock by a trigger — crafting
-- or mining something — not by research.
local function unlock_hint(force, recipe_name)
  for name, tech in pairs(force.technologies) do
    if not tech.researched then
      for _, eff in ipairs(tech.prototype.effects or {}) do
        if eff.type == "unlock-recipe" and eff.recipe == recipe_name then
          return trigger_text(tech) or ("unlocked by researching " .. name .. " (research skill)")
        end
      end
    end
  end
  return "not unlocked by any remaining tech"
end

-- A bare script character's hand-crafting doesn't count toward "craft X" research
-- triggers (only a connected player's does), so the AI could never unlock
-- automation-science-pack by crafting a lab. The trigger reads the force's production
-- statistics, so report the craft there. (A craft cancelled afterwards still counts, so
-- the tech can unlock slightly early; accepted.)
local function credit_craft_trigger(character, item, n)
  local force = character.force
  for _, t in pairs(force.technologies) do
    local trig = t.prototype.research_trigger
    if trig and trig.type == "craft-item" and t.enabled and not t.researched then
      local target = type(trig.item) == "table" and trig.item.name or trig.item
      if target == item then
        force.get_item_production_statistics(character.surface).on_flow(item, n)
        return
      end
    end
  end
end

local function skill_craft_for(character, p)
  local item = p.item
  if not item then return false, "craft_for: 'item' is required" end
  local count = math.max(tonumber(p.count) or 1, 1)
  local inv = inv_of(character)
  local have_now = inv.get_item_count(item)
  if have_now >= count then
    return true, string.format("craft_for: already have %d %s", have_now, item)
  end
  local r = character.force.recipes[item]
  if not r then return false, "craft_for: no recipe makes " .. item .. " — gather it instead" end
  if not r.enabled then
    return false, "craft_for: " .. item .. " is locked — " .. unlock_hint(character.force, r.name)
  end
  if not handcraftable(character, r) then
    -- Plates/bricks/steel: smelt the ingredient instead of failing.
    local is_smelt = false
    for _, cat in ipairs(r.categories or {}) do if cat == "smelting" then is_smelt = true end end
    if is_smelt and r.ingredients[1] then
      local ore = r.ingredients[1].name
      if inv.get_item_count(ore) > 0 then
        -- Idle AI furnaces first (empty input, output empty or the same plate).
        local fed = 0
        for _, f in ipairs(character.surface.find_entities_filtered{type = "furnace", force = character.force,
                                                                   position = character.position, radius = 64}) do
          if f.last_user == nil and inv.get_item_count(ore) > 0 then
            local src = f.get_inventory(defines.inventory.crafter_input)
            local out = f.get_inventory(defines.inventory.crafter_output)
            local made = out and not out.is_empty() and out[1].valid_for_read and out[1].name or nil
            if src and src.is_empty() and (made == nil or made == item) then
              local n = src.insert{name = ore, count = math.min(20, inv.get_item_count(ore))}
              if n > 0 then inv.remove{name = ore, count = n}; fed = fed + 1 end
            end
          end
        end
        if fed > 0 then
          return true, string.format("craft_for: %s is smelted, not crafted — loaded %s into %d idle furnace(s); "
            .. "tend later to collect the plates", item, ore, fed)
        end
        local ok, d = skill_build_smelter(character, {ore = ore, count = 2})
        return ok, "craft_for: " .. item .. " is smelted, not crafted — " .. d
      end
      return false, string.format("craft_for: %s is smelted from %s, which you don't have — "
        .. "gather %s, or build_miner resource=%s output=furnace, then tend to collect plates", item, ore, ore, ore)
    end
    return false, "craft_for: " .. item .. " can't be hand-crafted (needs a "
      .. table.concat(r.categories or {}, "/") .. " machine) — build one"
  end

  local crafts = math.ceil((count - have_now) / product_amount(r, item))
  local can = character.get_craftable_count(r)
  local queued = 0
  if can > 0 then
    queued = character.begin_crafting{recipe = r, count = math.min(crafts, can), silent = true}
  end
  local detail = string.format("craft_for: queued %d craft(s) of %s", queued, item)
  if queued > 0 then credit_craft_trigger(character, item, queued * product_amount(r, item)) end
  if queued < crafts then
    local have = {}
    for _, it in ipairs(inv.get_contents()) do have[it.name] = (have[it.name] or 0) + it.count end
    local out = {}
    for _, ing in ipairs(r.ingredients) do
      if ing.type == "item" then
        raw_shortfall(character, ing.name, ing.amount * (crafts - queued), have, out, 1, {[item] = true})
      end
    end
    local parts = {}
    for name, n in pairs(out) do parts[#parts + 1] = n .. "x " .. name end
    table.sort(parts)
    if #parts > 0 then
      detail = detail .. string.format("; for the other %d still missing raw: %s (gather/smelt them)",
                                       crafts - queued, table.concat(parts, ", "))
    end
  end
  return queued > 0, detail
end

-- -------------------------------------------------------------------------
-- connect_belt(from, to) — lay transport-belt ghosts along an L-shaped path
-- (tries horizontal-first, then vertical-first). Trees/rocks on the path are
-- marked for deconstruction. build_ghosts then builds the belt.
-- -------------------------------------------------------------------------
local MAX_BELT = 300

local function step_dir(dx, dy)
  if dx > 0 then return defines.direction.east end
  if dx < 0 then return defines.direction.west end
  if dy > 0 then return defines.direction.south end
  return defines.direction.north
end

local OPPOSITE_DIR = {
  [defines.direction.north] = defines.direction.south,
  [defines.direction.south] = defines.direction.north,
  [defines.direction.east]  = defines.direction.west,
  [defines.direction.west]  = defines.direction.east,
}

local function snap_endpoint_outside_buildings(surface, pt, name)
  local x, y = math.floor(pt.x) + 0.5, math.floor(pt.y) + 0.5
  -- If current tile is already traversable/passable, keep it
  local ents = surface.find_entities_filtered{area = {{x - 0.4, y - 0.4}, {x + 0.4, y + 0.4}}}
  local blocked_by_building = false
  for _, e in ipairs(ents) do
    if e.type ~= "tree" and e.type ~= "simple-entity" and e.name ~= name
       and not (e.type == "entity-ghost" and e.ghost_name == name) then
      blocked_by_building = true; break
    end
  end
  if not blocked_by_building then return {x = x, y = y} end

  -- Spiral search up to radius 3 for nearest tile clear of buildings
  local best_pt, best_dist = nil, math.huge
  for r = 1, 3 do
    for dx = -r, r do
      for dy = -r, r do
        if math.abs(dx) == r or math.abs(dy) == r then
          local tx, ty = x + dx, y + dy
          local tile = surface.get_tile(tx, ty)
          if tile and not tile.collides_with("water_tile") then
            local es = surface.find_entities_filtered{area = {{tx - 0.4, ty - 0.4}, {tx + 0.4, ty + 0.4}}}
            local b = false
            for _, e in ipairs(es) do
              if e.type ~= "tree" and e.type ~= "simple-entity" and e.name ~= name
                 and not (e.type == "entity-ghost" and e.ghost_name == name) then
                b = true; break
              end
            end
            if not b then
              local d = dx * dx + dy * dy
              if d < best_dist then best_dist = d; best_pt = {x = tx, y = ty} end
            end
          end
        end
      end
    end
    if best_pt then break end
  end
  return best_pt or {x = x, y = y}
end

local FLUID_NEIGHBOUR = {pipe = true, ["pipe-to-ground"] = true, ["storage-tank"] = true, pump = true,
                         ["offshore-pump"] = true, boiler = true, generator = true, ["oil-refinery"] = true,
                         ["chemical-plant"] = true, pumpjack = true,
                         reactor = true, ["fusion-reactor"] = true, ["fusion-generator"] = true}

local function tile_key(x, y)
  return (math.floor(x) + 50000) * 100000 + (math.floor(y) + 50000)
end

-- Does a pipe/fluid entity (or pipe ghost) sit on the tile at (x, y)?
local function fluid_entity_at(surface, x, y)
  for _, e in ipairs(surface.find_entities_filtered{area = {{x - 0.4, y - 0.4}, {x + 0.4, y + 0.4}}}) do
    if FLUID_NEIGHBOUR[e.type] or FLUID_NEIGHBOUR[e.name] then return true end
    if e.type == "entity-ghost" and (e.ghost_name == "pipe" or e.ghost_type == "pipe-to-ground"
                                     or e.ghost_type == "storage-tank") then return true end
  end
  return false
end

-- `ends` = set of tile_key()s of the route's endpoints. Existing same-kind belts/pipes only count
-- as passable AT an endpoint; mid-route they would merge the new line into someone else's network.
-- Pipes also may not run orthogonally next to a foreign pipe/fluid entity (they would auto-connect).
local function tile_traversable(surface, force, name, pt, dir, ends)
  local tile = surface.get_tile(pt.x, pt.y)
  if tile and tile.collides_with("water_tile") then return false end
  local endpoint = ends ~= nil and ends[tile_key(pt.x, pt.y)] == true
  if not endpoint then
    local ex = surface.find_entities_filtered{area = {{pt.x - 0.4, pt.y - 0.4}, {pt.x + 0.4, pt.y + 0.4}}, name = name, limit = 1}[1]
    if ex then return false end
    local g = surface.find_entities_filtered{area = {{pt.x - 0.4, pt.y - 0.4}, {pt.x + 0.4, pt.y + 0.4}}, type = 'entity-ghost', limit = 1}[1]
    if g and g.ghost_name == name then return false end
  end
  if surface.can_place_entity{name = name, position = pt, direction = dir,
                              force = force, build_check_type = defines.build_check_type.manual_ghost,
                              forced = true} then
    if name == "pipe" and not endpoint then
      for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
        local nx, ny = pt.x + d[1], pt.y + d[2]
        if not (ends and ends[tile_key(nx, ny)]) and fluid_entity_at(surface, nx, ny) then return false end
      end
    end
    return true
  end
  local ents = surface.find_entities_filtered{area = {{pt.x - 0.4, pt.y - 0.4}, {pt.x + 0.4, pt.y + 0.4}}}
  if #ents == 0 then return false end
  for _, e in ipairs(ents) do
    if e.type == "tree" or e.type == "simple-entity" then
      -- tree/rock can be deconstructed
    elseif endpoint and (e.name == name or (e.type == "entity-ghost" and e.ghost_name == name)) then
      -- matching belt/pipe or ghost, only at an endpoint
    else
      return false
    end
  end
  return true
end

-- A* Grid Pathfinder fallback when L-paths are obstructed. Binary-heap open set, closed set,
-- search box around start/goal, and a node cap (each node costs tile checks).
local ASTAR_MARGIN, ASTAR_MAX_NODES = 12, 400
local function astar_path(surface, force, name, start_pt, goal_pt, max_tiles, opts)
  local sx, sy = math.floor(start_pt.x) + 0.5, math.floor(start_pt.y) + 0.5
  local gx, gy = math.floor(goal_pt.x) + 0.5, math.floor(goal_pt.y) + 0.5
  local start_key = tile_key(sx, sy)
  local goal_key = tile_key(gx, gy)
  if start_key == goal_key then
    return {{x = sx, y = sy}}
  end
  local ends = {[start_key] = true, [goal_key] = true}
  local min_x, max_x = math.min(sx, gx) - ASTAR_MARGIN, math.max(sx, gx) + ASTAR_MARGIN
  local min_y, max_y = math.min(sy, gy) - ASTAR_MARGIN, math.max(sy, gy) + ASTAR_MARGIN

  local allow_ug = (opts == nil) or (opts.underground ~= false)
  local ug_name = (name == "transport-belt") and "underground-belt"
    or ((name == "pipe") and "pipe-to-ground" or nil)
  local is_ug = allow_ug and ug_name and force.recipes[ug_name] and force.recipes[ug_name].enabled
  local ug_proto = ug_name and prototypes.entity[ug_name]
  local ug_max_span = ug_proto and ug_proto.max_underground_distance or 0


  local function heuristic(x, y)
    return math.abs(x - gx) + math.abs(y - gy)
  end

  -- min-heap on f
  local heap, hn = {}, 0
  local function push(node)
    hn = hn + 1
    heap[hn] = node
    local i = hn
    while i > 1 do
      local par = math.floor(i / 2)
      if heap[par].f <= heap[i].f then break end
      heap[par], heap[i] = heap[i], heap[par]
      i = par
    end
  end
  local function pop()
    local top = heap[1]
    heap[1] = heap[hn]
    heap[hn] = nil
    hn = hn - 1
    local i = 1
    while true do
      local l, r, m = i * 2, i * 2 + 1, i
      if l <= hn and heap[l].f < heap[m].f then m = l end
      if r <= hn and heap[r].f < heap[m].f then m = r end
      if m == i then break end
      heap[m], heap[i] = heap[i], heap[m]
      i = m
    end
    return top
  end

  local g_score = {[start_key] = 0}
  local came_from = {}
  local came_dir = {}
  local came_ug = {}
  local closed = {}
  local tile_ok = {}     -- per-call cache of tile checks

  push({x = sx, y = sy, key = start_key, f = heuristic(sx, sy)})

  local DIRS = {
    {dx = 1, dy = 0, dir = defines.direction.east},
    {dx = -1, dy = 0, dir = defines.direction.west},
    {dx = 0, dy = 1, dir = defines.direction.south},
    {dx = 0, dy = -1, dir = defines.direction.north},
  }

  local expanded = 0
  while hn > 0 and expanded < ASTAR_MAX_NODES do
    local current = pop()
    if not closed[current.key] then
      closed[current.key] = true
      expanded = expanded + 1
      if current.key == goal_key then
        -- Reconstruct path
        local path = {}
        local cur_key = goal_key
        local cur_pt = {x = gx, y = gy}
        while cur_key do
          local node = came_from[cur_key]
          if node then
            if node.ug then
              cur_pt.ug = "output"
              cur_pt.ug_dir = node.ug_dir
              table.insert(path, 1, cur_pt)
              cur_pt = {x = node.x, y = node.y, ug = "input", ug_dir = node.ug_dir}
            else
              table.insert(path, 1, cur_pt)
              cur_pt = {x = node.x, y = node.y}
            end
            cur_key = node.prev_key
          else
            table.insert(path, 1, cur_pt)
            break
          end
        end
        return path
      end

      local cur_g = g_score[current.key]
      local cur_dir = came_dir[current.key]
      local cur_is_exit = (came_ug[current.key] == "exit")

      for _, d in ipairs(DIRS) do
        -- Out of an underground exit tile, only a straight step is allowed
        local skip_step = cur_is_exit and cur_dir and (d.dir ~= cur_dir)
        local nx, ny = current.x + d.dx, current.y + d.dy
        local nkey = tile_key(nx, ny)
        local traversable = false
        if not skip_step and not closed[nkey] and nx >= min_x and nx <= max_x and ny >= min_y and ny <= max_y then
          traversable = (nkey == goal_key)
          if not traversable then
            traversable = tile_ok[nkey]
            if traversable == nil then
              traversable = tile_traversable(surface, force, name, {x = nx, y = ny}, d.dir, ends)
              tile_ok[nkey] = traversable
            end
          end
          if traversable then
            local turn_penalty = (cur_dir and cur_dir ~= d.dir) and 0.25 or 0.0
            local tent_g = cur_g + 1 + turn_penalty
            if tent_g < (g_score[nkey] or math.huge) then
              local h = heuristic(nx, ny)
              if (tent_g + h) <= (max_tiles or MAX_BELT) then
                g_score[nkey] = tent_g
                came_from[nkey] = {x = current.x, y = current.y, prev_key = current.key}
                came_dir[nkey] = d.dir
                came_ug[nkey] = nil
                push({x = nx, y = ny, key = nkey, f = tent_g + h})
              end
            end
          end
        end

        -- Underground hops: must be straight along came_dir (or at start node), never out of an exit tile
        local can_hop = is_ug and not cur_is_exit and (cur_dir == nil or cur_dir == d.dir)
        if can_hop then
          for k = 2, ug_max_span do
            local ex, ey = current.x + k * d.dx, current.y + k * d.dy
            if ex < min_x or ex > max_x or ey < min_y or ey > max_y then break end

            -- Intermediate tile check at (k - 1): break immediately if blocked
            local mx, my = current.x + (k - 1) * d.dx, current.y + (k - 1) * d.dy
            local mt = surface.get_tile(mx, my)
            if not mt or mt.collides_with("water_tile") then break end
            local m_collides = surface.find_entities_filtered{area = {{mx - 0.4, my - 0.4}, {mx + 0.4, my + 0.4}}, type = {"cliff", ug_name}}
            if #m_collides > 0 then break end

            local ekey = tile_key(ex, ey)
            if not closed[ekey] then
              local ex_ok = (ekey == goal_key)
              if not ex_ok then
                ex_ok = tile_ok[ekey]
                if ex_ok == nil then
                  ex_ok = tile_traversable(surface, force, name, {x = ex, y = ey}, d.dir, ends)
                  tile_ok[ekey] = ex_ok
                end
              end
              if ex_ok then
                local hop_cost = (name == "pipe") and (k * 0.9) or (k + (traversable and 1.0 or 0.25))
                local tent_g = cur_g + hop_cost
                if tent_g < (g_score[ekey] or math.huge) then
                  local h = heuristic(ex, ey)
                  if (tent_g + h) <= (max_tiles or MAX_BELT) then
                    g_score[ekey] = tent_g
                    came_from[ekey] = {x = current.x, y = current.y, prev_key = current.key, ug = true, ug_dir = d.dir}
                    came_dir[ekey] = d.dir
                    came_ug[ekey] = "exit"
                    push({x = ex, y = ey, key = ekey, f = tent_g + h})
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  return nil
end

local function belt_path(a, b, horizontal_first, final_dir)
  local ax, ay = math.floor(a.x) + 0.5, math.floor(a.y) + 0.5
  local bx, by = math.floor(b.x) + 0.5, math.floor(b.y) + 0.5
  local pts = {{x = ax, y = ay}}
  local function walk_to(tx, ty)
    local cur = pts[#pts]
    local dx = (tx > cur.x and 1) or (tx < cur.x and -1) or 0
    local dy = (ty > cur.y and 1) or (ty < cur.y and -1) or 0
    while (cur.x ~= tx or cur.y ~= ty) and #pts <= MAX_BELT do
      cur = {x = cur.x + dx, y = cur.y + dy}
      pts[#pts + 1] = cur
    end
  end
  if horizontal_first then walk_to(bx, ay); walk_to(bx, by)
  else walk_to(ax, by); walk_to(bx, by) end
  local tiles = {}
  for i, pt in ipairs(pts) do
    local nxt = pts[i + 1]
    local d
    if nxt then d = step_dir(nxt.x - pt.x, nxt.y - pt.y)
    else d = final_dir or (tiles[#tiles] and tiles[#tiles].direction or step_dir(bx - ax, by - ay)) end
    tiles[#tiles + 1] = {position = pt, direction = d}
  end
  return tiles
end

local function skill_connect_belt(character, p)
  local a, b = p.from, p.to
  if not (a and b and a.x and a.y and b.x and b.y) then
    return false, "connect_belt: 'from' and 'to' must be {x=N, y=N}"
  end
  local surface, force = character.surface, character.force
  -- Snap endpoints clear of existing buildings (like assemblers/furnaces) if needed
  a = snap_endpoint_outside_buildings(surface, a, "transport-belt")
  b = snap_endpoint_outside_buildings(surface, b, "transport-belt")

  local blocked_at
  local chosen_tiles = nil
  local ends = {[tile_key(a.x, a.y)] = true, [tile_key(b.x, b.y)] = true}

  -- 1. Try fast L-paths first
  for _, hfirst in ipairs({true, false}) do
    local tiles = belt_path(a, b, hfirst, p.final_dir)
    if #tiles <= MAX_BELT then
      local ok = true
      if p.final_dir and #tiles > 1 then
        local p_step = step_dir(tiles[#tiles].position.x - tiles[#tiles - 1].position.x,
                                tiles[#tiles].position.y - tiles[#tiles - 1].position.y)
        if (p_step + 8) % 16 == p.final_dir then ok = false end
      end
      if ok then
        for _, t in ipairs(tiles) do
          if not tile_traversable(surface, force, "transport-belt", t.position, t.direction, ends) then
            ok = false; blocked_at = t.position; break
          end
        end
      end
      if ok then chosen_tiles = tiles; break end
    end
  end

  -- 2. Fall back to A* pathfinder if L-paths are blocked
  if not chosen_tiles then
    local astar_pts = astar_path(surface, force, "transport-belt", a, b, MAX_BELT, {underground = p.underground ~= false})
    if astar_pts and #astar_pts > 0 then
      local tiles = {}
      for i, pt in ipairs(astar_pts) do
        if pt.ug == "input" then
          tiles[#tiles + 1] = {position = {x = pt.x, y = pt.y}, direction = pt.ug_dir, name = "underground-belt", ug_type = "input"}
        elseif pt.ug == "output" then
          tiles[#tiles + 1] = {position = {x = pt.x, y = pt.y}, direction = pt.ug_dir, name = "underground-belt", ug_type = "output"}
        else
          local nxt = astar_pts[i + 1]
          local d
          if nxt then
            d = (nxt.ug == "output") and nxt.ug_dir or step_dir(nxt.x - pt.x, nxt.y - pt.y)
          else
            d = p.final_dir or (tiles[#tiles] and tiles[#tiles].direction or step_dir(b.x - a.x, b.y - a.y))
          end
          tiles[#tiles + 1] = {position = {x = pt.x, y = pt.y}, direction = d, name = "transport-belt"}
        end
      end
      if p.final_dir and #tiles > 1 then
        local p_step = step_dir(tiles[#tiles].position.x - tiles[#tiles - 1].position.x,
                                tiles[#tiles].position.y - tiles[#tiles - 1].position.y)
        if (p_step + 8) % 16 == p.final_dir then tiles = nil end
      end
      chosen_tiles = tiles
    end
  end

  if chosen_tiles then
    local tiles = chosen_tiles
    local placed, marked = 0, 0
    for _, t in ipairs(tiles) do
      local x, y = t.position.x, t.position.y
      for _, e in ipairs(surface.find_entities_filtered{area = {{x - 0.5, y - 0.5}, {x + 0.5, y + 0.5}},
                                                        type = {"tree", "simple-entity"}}) do
        if e.order_deconstruction(force) then marked = marked + 1 end
      end
      local existing = surface.find_entities_filtered{position = t.position, radius = 0.4}
      local already_has = false
      if t.name == "underground-belt" then
        for _, ex in ipairs(existing) do
          if ex.name == "underground-belt" or (ex.type == "entity-ghost" and ex.ghost_name == "underground-belt") then
            already_has = true; break
          end
        end
        if not already_has then
          local g = surface.create_entity{name = "entity-ghost", inner_name = "underground-belt",
                                          position = t.position, direction = t.direction,
                                          type = t.ug_type, force = force}
          if g then placed = placed + 1; AIRegistry.register_ghost(g) end
        end
      else
        for _, ex in ipairs(existing) do
          if ex.name == "transport-belt" or (ex.type == "entity-ghost" and ex.ghost_name == "transport-belt") then
            already_has = true; break
          end
        end
        if not already_has then
          local g = surface.create_entity{name = "entity-ghost", inner_name = "transport-belt",
                                          position = t.position, direction = t.direction, force = force}
          if g then placed = placed + 1; AIRegistry.register_ghost(g) end
        end
      end
    end
    if storage.ai_player then
      storage.ai_player.connected_belts = storage.ai_player.connected_belts or {}
      table.insert(storage.ai_player.connected_belts, {from = {x = math.floor(a.x) + 0.5, y = math.floor(a.y) + 0.5},
                                                      to = {x = math.floor(b.x) + 0.5, y = math.floor(b.y) + 0.5}})
      AIDebug.event("connect_belt", {from = a, to = b, tiles = #tiles})
    end
    -- If character has belts, try immediately building what is in inventory
    local inv = inv_of(character)
    if inv.get_item_count("transport-belt") > 0 or inv.get_item_count("underground-belt") > 0 then
      skill_build_ghosts(character, {})
    end
    if placed == 0 then
      return true, string.format("connect_belt: connected %d tile(s) along existing belts", #tiles)
    end
    local next_step = marked > 0
      and string.format("deconstruct first (%d tree/rock(s) in the way), then build_ghosts", marked)
      or "build_ghosts next"
    return true, string.format("connect_belt: placed %d/%d belt ghost(s) — %s (needs %d transport-belt)",
                               placed, #tiles, next_step, placed)
  end

  return false, string.format("connect_belt: no route found (L-paths and A* blocked near {%.0f,%.0f}); routes may not run through existing belts — deconstruct obstacles or pick other endpoints",
                              blocked_at and blocked_at.x or 0, blocked_at and blocked_at.y or 0)
end

-- -------------------------------------------------------------------------
-- connect_pipe(from, to) — lay pipe ghosts along an L-shaped path.
-- Trees/rocks on the path are marked for deconstruction.
-- -------------------------------------------------------------------------
local function pipe_path(a, b, horizontal_first)
  local ax, ay = math.floor(a.x) + 0.5, math.floor(a.y) + 0.5
  local bx, by = math.floor(b.x) + 0.5, math.floor(b.y) + 0.5
  local pts = {{x = ax, y = ay}}
  local function walk_to(tx, ty)
    local cur = pts[#pts]
    local dx = (tx > cur.x and 1) or (tx < cur.x and -1) or 0
    local dy = (ty > cur.y and 1) or (ty < cur.y and -1) or 0
    while (cur.x ~= tx or cur.y ~= ty) and #pts <= MAX_BELT do
      cur = {x = cur.x + dx, y = cur.y + dy}
      pts[#pts + 1] = cur
    end
  end
  if horizontal_first then walk_to(bx, ay); walk_to(bx, by)
  else walk_to(ax, by); walk_to(bx, by) end
  return pts
end

local function skill_connect_pipe(character, p)
  local a, b = p.from, p.to
  if not (a and b and a.x and a.y and b.x and b.y) then
    return false, "connect_pipe: 'from' and 'to' must be {x=N, y=N}"
  end
  local surface, force = character.surface, character.force

  -- If 'from' is a water tile (e.g. water landmark), snap to nearest shoreline land tile
  local sp_a = surface.get_tile(a.x, a.y)
  if sp_a and sp_a.collides_with("water_tile") then
    local best_land, min_d = nil, 999
    for dx = -6, 6 do
      for dy = -6, 6 do
        local test_t = surface.get_tile(a.x + dx, a.y + dy)
        if test_t and not test_t.collides_with("water_tile") then
          local d = dx * dx + dy * dy
          if d < min_d then
            min_d = d
            best_land = {x = math.floor(a.x + dx) + 0.5, y = math.floor(a.y + dy) + 0.5}
          end
        end
      end
    end
    if best_land then a = best_land end
  end

  -- Snap endpoints clear of existing buildings (e.g. boiler/refinery footprints)
  a = snap_endpoint_outside_buildings(surface, a, "pipe")
  b = snap_endpoint_outside_buildings(surface, b, "pipe")

  local blocked_at
  local chosen_pts = nil
  local ends = {[tile_key(a.x, a.y)] = true, [tile_key(b.x, b.y)] = true}

  -- 1. Try fast L-paths first
  for _, hfirst in ipairs({true, false}) do
    local pts = pipe_path(a, b, hfirst)
    if #pts <= MAX_BELT then
      local ok = true
      for _, pt in ipairs(pts) do
        if not tile_traversable(surface, force, "pipe", pt, defines.direction.north, ends) then
          ok = false; blocked_at = pt; break
        end
      end
      if ok then chosen_pts = pts; break end
    end
  end

  -- 2. Fall back to A* pathfinder if L-paths are blocked
  if not chosen_pts then
    local astar_pts = astar_path(surface, force, "pipe", a, b, MAX_BELT, {underground = p.underground ~= false})
    if astar_pts and #astar_pts > 0 then
      chosen_pts = astar_pts
    end
  end

  if chosen_pts then
    local pts = chosen_pts
    local placed, marked = 0, 0
    for _, pt in ipairs(pts) do
      local x, y = pt.x, pt.y
      for _, e in ipairs(surface.find_entities_filtered{area = {{x - 0.5, y - 0.5}, {x + 0.5, y + 0.5}},
                                                        type = {"tree", "simple-entity"}}) do
        if e.order_deconstruction(force) then marked = marked + 1 end
      end
      local existing = surface.find_entities_filtered{position = {x = x, y = y}, radius = 0.4}
      local already_has = false
      if pt.ug then
        for _, ex in ipairs(existing) do
          if ex.name == "pipe-to-ground" or (ex.type == "entity-ghost" and ex.ghost_name == "pipe-to-ground") then
            already_has = true; break
          end
        end
        if not already_has then
          local dir = (pt.ug == "input") and OPPOSITE_DIR[pt.ug_dir] or pt.ug_dir
          local g = surface.create_entity{name = "entity-ghost", inner_name = "pipe-to-ground",
                                          position = {x = x, y = y}, direction = dir, force = force}
          if g then placed = placed + 1; AIRegistry.register_ghost(g) end
        end
      else
        for _, ex in ipairs(existing) do
          if ex.name == "pipe" or (ex.type == "entity-ghost" and ex.ghost_name == "pipe") then
            already_has = true; break
          end
        end
        if not already_has then
          local g = surface.create_entity{name = "entity-ghost", inner_name = "pipe",
                                          position = {x = x, y = y}, force = force}
          if g then placed = placed + 1; AIRegistry.register_ghost(g) end
        end
      end
    end
    if storage.ai_player then
      storage.ai_player.connected_pipes = storage.ai_player.connected_pipes or {}
      table.insert(storage.ai_player.connected_pipes, {from = {x = math.floor(a.x) + 0.5, y = math.floor(a.y) + 0.5},
                                                       to = {x = math.floor(b.x) + 0.5, y = math.floor(b.y) + 0.5}})
      AIDebug.event("connect_pipe", {from = a, to = b, tiles = #pts})
    end
    -- If character has pipes, try immediately building what is in inventory
    local inv = inv_of(character)
    if inv.get_item_count("pipe") > 0 or inv.get_item_count("pipe-to-ground") > 0 then
      skill_build_ghosts(character, {})
    end
    if placed == 0 then
      return true, string.format("connect_pipe: connected %d tile(s) along existing pipes", #pts)
    end
    local next_step = marked > 0
      and string.format("deconstruct first (%d tree/rock(s) in the way), then build_ghosts", marked)
      or "build_ghosts next"
    return true, string.format("connect_pipe: placed %d/%d pipe ghost(s) — %s (needs %d pipe)",
                               placed, #pts, next_step, placed)
  end

  return false, string.format("connect_pipe: no route found (L-paths and A* blocked near {%.0f,%.0f}); routes may not run through or beside existing pipes — deconstruct obstacles or pick other endpoints",
                              blocked_at and blocked_at.x or 0, blocked_at and blocked_at.y or 0)
end

-- -------------------------------------------------------------------------
-- connect_ports(from_bp, from_port, to_bp, to_port) — route belt or pipe
-- between blueprint ports using world port positions and facings.
-- -------------------------------------------------------------------------
local function skill_connect_ports(character, p)
  local from_bp = p.from_bp
  local from_port = p.from_port
  local to_bp = p.to_bp
  local to_port = p.to_port
  if not (from_bp and from_port and to_bp and to_port) then
    return false, "connect_ports: 'from_bp', 'from_port', 'to_bp', 'to_port' are required"
  end

  local function find_placed(name_or_idx)
    local placed = storage.ai_player and storage.ai_player.placed_blueprints or {}
    if type(name_or_idx) == "number" then return placed[name_or_idx] end
    for i = #placed, 1, -1 do
      if placed[i].name == name_or_idx then return placed[i] end
    end
    return nil
  end

  local f_entry = find_placed(from_bp)
  if not f_entry then return false, string.format("connect_ports: blueprint '%s' not placed", tostring(from_bp)) end
  local t_entry = find_placed(to_bp)
  if not t_entry then return false, string.format("connect_ports: blueprint '%s' not placed", tostring(to_bp)) end

  local function find_port(bp, port_name)
    for _, pt in ipairs(bp.ports or {}) do
      if pt.name == port_name then return pt end
    end
    return nil
  end

  local fp = find_port(f_entry, from_port)
  if not fp then return false, string.format("connect_ports: port '%s' not found on '%s'", tostring(from_port), tostring(from_bp)) end
  local tp = find_port(t_entry, to_port)
  if not tp then return false, string.format("connect_ports: port '%s' not found on '%s'", tostring(to_port), tostring(to_bp)) end

  local function dir_step(d)
    if d == defines.direction.north then return 0, -1
    elseif d == defines.direction.east then return 1, 0
    elseif d == defines.direction.south then return 0, 1
    elseif d == defines.direction.west then return -1, 0
    end
    return 0, 0
  end

  local fdx, fdy = dir_step(fp.dir)
  local tdx, tdy = dir_step(tp.dir)

  local is_pipe = (fp.kind == "pipe" or tp.kind == "pipe")

  -- Direct connection check: out port faces straight into in port
  if fp.x + fdx == tp.x and fp.y + fdy == tp.y then
    if is_pipe then
      storage.ai_player.connected_pipes = storage.ai_player.connected_pipes or {}
      table.insert(storage.ai_player.connected_pipes, {
        from_bp = from_bp, from_port = from_port,
        to_bp = to_bp, to_port = to_port,
        from = {x = fp.x, y = fp.y}, to = {x = tp.x, y = tp.y}
      })
    else
      storage.ai_player.connected_belts = storage.ai_player.connected_belts or {}
      table.insert(storage.ai_player.connected_belts, {
        from_bp = from_bp, from_port = from_port,
        to_bp = to_bp, to_port = to_port,
        from = {x = fp.x, y = fp.y}, to = {x = tp.x, y = tp.y}
      })
    end
    return true, string.format("connect_ports: %s:%s and %s:%s are directly adjacent", from_bp, from_port, to_bp, to_port)
  end

  local start_pt = {x = fp.x + fdx, y = fp.y + fdy}
  local end_pt = {x = tp.x - tdx, y = tp.y - tdy}

  if is_pipe then
    local ok, detail = skill_connect_pipe(character, {from = start_pt, to = end_pt})
    if ok then
      storage.ai_player.connected_pipes = storage.ai_player.connected_pipes or {}
      table.insert(storage.ai_player.connected_pipes, {
        from_bp = from_bp, from_port = from_port,
        to_bp = to_bp, to_port = to_port,
        from = start_pt, to = end_pt
      })
      return true, string.format("connect_ports: connected pipe %s:%s -> %s:%s (%s)", from_bp, from_port, to_bp, to_port, detail)
    end
    return false, detail
  else
    local ok, detail = skill_connect_belt(character, {
      from = start_pt,
      to = end_pt,
      final_dir = tp.dir,
      underground = p.underground
    })
    if ok then
      storage.ai_player.connected_belts = storage.ai_player.connected_belts or {}
      table.insert(storage.ai_player.connected_belts, {
        from_bp = from_bp, from_port = from_port,
        to_bp = to_bp, to_port = to_port,
        from = start_pt, to = end_pt
      })
      return true, string.format("connect_ports: connected belt %s:%s -> %s:%s (%s)", from_bp, from_port, to_bp, to_port, detail)
    end
    return false, detail
  end
end

-- -------------------------------------------------------------------------
-- connect_power(to) — chains small electric poles from the active grid
-- to the target position so unpowered machines are wired into the network.
-- -------------------------------------------------------------------------
local function skill_connect_power(character, p)
  local target = p and (p.to or p.position)
  if not (target and target.x and target.y) then
    return false, "connect_power: 'to' must be {x=N, y=N}"
  end
  local surface, force = character.surface, character.force
  local best_pole, best_d = nil, nil
  local poles = surface.find_entities_filtered{type = "electric-pole", force = force, position = target, radius = 300}
  for _, pole in ipairs(poles) do
    local net = pole.electric_network_id
    local valid_grid = false
    if net then
      local stats = pole.electric_network_statistics
      if stats and stats.get_flow_count{category = "input", count = true} > 0 then
        valid_grid = true
      end
    end
    if not valid_grid and surface.count_entities_filtered{type = {"generator", "boiler"}, force = force, limit = 1} > 0 then
      valid_grid = true
    end
    if valid_grid then
      local dx, dy = pole.position.x - target.x, pole.position.y - target.y
      local d = dx * dx + dy * dy
      if not best_d or d < best_d then
        best_pole = pole
        best_d = d
      end
    end
  end

  if not best_pole then
    return false, "connect_power: no powered electric pole found within 300 tiles — build_power first"
  end

  if best_d and best_d <= 49 then
    return true, string.format("connect_power: target {%.1f,%.1f} is already within reach of pole at {%.1f,%.1f}",
      target.x, target.y, best_pole.position.x, best_pole.position.y)
  end

  local plan_poles, joined = AILayout.pole_chain(character, best_pole.position, target, {})
  if not plan_poles or #plan_poles == 0 then
    return true, "connect_power: already connected"
  end

  local plan = {place = plan_poles}
  local ready, why = stock_up(character, AILayout.items({plan}), "connect_power")
  if not ready then return false, why end

  local ok, res = AILayout.build(character, plan)
  if not ok then return false, "connect_power: " .. tostring(res) end

  return true, string.format("connect_power: placed %d electric pole(s) from {%.1f,%.1f} to {%.1f,%.1f}",
    #plan_poles, best_pole.position.x, best_pole.position.y, target.x, target.y)
end

-- -------------------------------------------------------------------------
-- fix_flow(target) — checks and repairs flow faults (reversed inserters,
-- dead-end belts) around machines.
-- -------------------------------------------------------------------------
local function skill_fix_flow(character, p)
  if not (AIFlow and AIFlow.check and AIFlow.repair) then
    return false, "fix_flow: AIFlow module not available"
  end
  local surface = character.surface
  local pos = p and (p.target or p.position) or character.position
  local radius = tonumber(p and p.radius) or 32

  local ents = surface.find_entities_filtered{
    position = pos,
    radius = radius,
    force = character.force,
    type = {"inserter", "transport-belt", "underground-belt", "assembling-machine", "furnace"}
  }
  -- the force is shared with the player in co-op: AIFlow.check keeps only the AI's own

  local res = AIFlow.check(ents)
  if res.ok or #res.faults == 0 then
    return true, "fix_flow: no flow faults detected in area"
  end

  local ok, detail = AIFlow.repair(character, res)
  return ok, string.format("fix_flow: audited %d entities, repaired %d fault(s)", #ents, #res.faults)
end

-- -------------------------------------------------------------------------
-- build_pumpjack — places a pumpjack on the nearest unmined crude-oil node.
-- -------------------------------------------------------------------------
local function skill_build_pumpjack(character, p)
  local surface, force = character.surface, character.force
  local target_pos = p and p.position
  local node = nil
  if target_pos then
    node = surface.find_entities_filtered{name = "crude-oil", position = target_pos, radius = 4, limit = 1}[1]
  end
  if not node then
    local center = character.position
    local nodes = surface.find_entities_filtered{name = "crude-oil", position = center, radius = 96}
    for _, n in ipairs(nodes) do
      if surface.count_entities_filtered{name = {"pumpjack", "entity-ghost"}, position = n.position, radius = 2} == 0 then
        node = n; break
      end
    end
  end
  if not node then
    local lm = nil
    for _, r in ipairs((AIPerception.landmarks(surface, character.position) or {}).resources or {}) do
      if r.name == "crude-oil" then lm = r; break end
    end
    if lm then
      return false, string.format("build_pumpjack: nearest crude-oil is at {%d,%d} (%d tiles away) — goto it first",
                                  lm.x, lm.y, math.floor(lm.distance or 0))
    end
    return false, "build_pumpjack: no crude-oil patch discovered yet — explore or build a radar first"
  end

  local pos = node.position
  local inv = inv_of(character)
  local recipe = force.recipes["pumpjack"]
  if recipe and not recipe.enabled then
    return false, "build_pumpjack: oil-processing technology not yet researched"
  end

  for _, e in ipairs(surface.find_entities_filtered{area = {{pos.x - 2, pos.y - 2}, {pos.x + 2, pos.y + 2}},
                                                    type = {"tree", "simple-entity"}}) do
    e.destroy()
  end

  if inv.get_item_count("pumpjack") == 0 then
    if recipe and character.get_craftable_count(recipe) > 0 then
      character.begin_crafting{recipe = "pumpjack", count = 1, silent = true}
      local g = surface.create_entity{name = "entity-ghost", inner_name = "pumpjack", position = pos, force = force}
      AIRegistry.register_ghost(g)
      return true, string.format("build_pumpjack: placed pumpjack ghost at {%.1f, %.1f} and began crafting", pos.x, pos.y)
    else
      local g = surface.create_entity{name = "entity-ghost", inner_name = "pumpjack", position = pos, force = force}
      AIRegistry.register_ghost(g)
      return true, string.format("build_pumpjack: placed pumpjack ghost at {%.1f, %.1f} — build_ghosts once crafted", pos.x, pos.y)
    end
  end

  inv.remove{name = "pumpjack", count = 1}
  local pj = surface.create_entity{name = "pumpjack", position = pos, force = force}
  if not pj then
    inv.insert{name = "pumpjack", count = 1}
    return false, string.format("build_pumpjack: could not place pumpjack at {%.1f, %.1f}", pos.x, pos.y)
  end
  AIRegistry.add(pj)
  AIRegistry.own(pj)

  if surface.count_entities_filtered{type = "electric-pole", position = pos, radius = 7} == 0 then
    local pole_pos = surface.find_non_colliding_position("small-electric-pole", {x = pos.x + 2, y = pos.y + 2}, 5, 0.5)
    if pole_pos then
      if inv.get_item_count("small-electric-pole") > 0 then
        inv.remove{name = "small-electric-pole", count = 1}
        local pole = surface.create_entity{name = "small-electric-pole", position = pole_pos, force = force}
        if pole then
          AIRegistry.add(pole)
          AIRegistry.own(pole)
        end
      else
        local g = surface.create_entity{name = "entity-ghost", inner_name = "small-electric-pole", position = pole_pos, force = force}
        AIRegistry.register_ghost(g)
      end
    end
  end

  return true, string.format("built pumpjack at {%.1f, %.1f}", pos.x, pos.y)
end

-- -------------------------------------------------------------------------
-- build_offshore_pump — places an offshore pump on the nearest shoreline.
-- -------------------------------------------------------------------------
local PUMP_ORIENT = {[0] = "north", [1] = "east", [2] = "south", [3] = "west"}
local function pump_unit16(dir)
  local d = dir % 16
  if d == 0 then return 0, -1 elseif d == 4 then return 1, 0 elseif d == 8 then return 0, 1 end
  return -1, 0
end

local function skill_build_offshore_pump(character, p)
  local surface, force = character.surface, character.force
  local target_pos = p and p.position
  local center = target_pos or character.position

  -- Small radius first, widening only when nothing fits (a radius-64 scan is ~12.8k tiles).
  local found_pos, found_dir
  local tried = 0
  for _, radius in ipairs({20, 40, 64}) do
    local tiles = surface.find_tiles_filtered{collision_mask = "water_tile", position = center, radius = radius}
    table.sort(tiles, function(a, b)
      local da = (a.position.x - center.x) ^ 2 + (a.position.y - center.y) ^ 2
      local db = (b.position.x - center.x) ^ 2 + (b.position.y - center.y) ^ 2
      return da < db
    end)
    for _, t in ipairs(tiles) do
      for r = 0, 3 do
        local wx, wy = pump_unit16(r * 4)
        local px, py = t.position.x + 0.5 - wx, t.position.y + 0.5 - wy
        local sp = surface.get_tile(px, py)
        if sp and not sp.collides_with("water_tile") then
          tried = tried + 1
          if tried > 400 then break end
          local dir_enum = AIActions.DIRECTION_MAP[PUMP_ORIENT[r]]
          if surface.can_place_entity{name = "offshore-pump", position = {x = px, y = py}, direction = dir_enum, force = force} then
            found_pos = {x = px, y = py}
            found_dir = PUMP_ORIENT[r]
            break
          end
        end
      end
      if found_pos or tried > 400 then break end
    end
    if found_pos or tried > 400 then break end
  end

  if not found_pos then
    local lm = (AIPerception.landmarks(surface, character.position) or {}).water
    if lm and lm.distance > 30 then
      return false, string.format("build_offshore_pump: nearest water is %d tiles away at {%d,%d} — goto it first",
                                  lm.distance, lm.x, lm.y)
    end
    return false, "build_offshore_pump: no valid shoreline found for offshore pump — explore or clear trees"
  end

  for _, e in ipairs(surface.find_entities_filtered{area = {{found_pos.x - 1.5, found_pos.y - 1.5}, {found_pos.x + 1.5, found_pos.y + 1.5}},
                                                    type = {"tree", "simple-entity"}}) do
    e.destroy()
  end

  local inv = inv_of(character)
  local recipe = force.recipes["offshore-pump"]
  if inv.get_item_count("offshore-pump") == 0 then
    if recipe and character.get_craftable_count(recipe) > 0 then
      character.begin_crafting{recipe = "offshore-pump", count = 1, silent = true}
      local g = surface.create_entity{name = "entity-ghost", inner_name = "offshore-pump", position = found_pos, direction = AIActions.DIRECTION_MAP[found_dir], force = force}
      AIRegistry.register_ghost(g)
      return true, string.format("build_offshore_pump: placed offshore pump ghost at {%.1f, %.1f} and began crafting", found_pos.x, found_pos.y)
    else
      local g = surface.create_entity{name = "entity-ghost", inner_name = "offshore-pump", position = found_pos, direction = AIActions.DIRECTION_MAP[found_dir], force = force}
      AIRegistry.register_ghost(g)
      return true, string.format("build_offshore_pump: placed offshore pump ghost at {%.1f, %.1f} — build_ghosts once crafted", found_pos.x, found_pos.y)
    end
  end

  local ok, detail = AIActions.run(character, {action = "place", item = "offshore-pump", position = found_pos, direction = found_dir})
  if not ok then
    return false, "build_offshore_pump: " .. (detail or "could not place offshore pump")
  end
  local pump = surface.find_entities_filtered{name = "offshore-pump", position = found_pos, radius = 0.5, limit = 1}[1]
  if pump then
    AIRegistry.add(pump)
    AIRegistry.own(pump)
  end

  -- Lay lead pipes extending from the offshore pump inland away from water
  local ux, uy = 0, 0
  if found_dir == "north" then uy = -1
  elseif found_dir == "east" then ux = 1
  elseif found_dir == "south" then uy = 1
  elseif found_dir == "west" then ux = -1
  end

  local pipes_laid = 0
  for s = 1, 4 do
    local pip_pos = {x = found_pos.x + ux * s, y = found_pos.y + uy * s}
    for _, e in ipairs(surface.find_entities_filtered{area = {{pip_pos.x - 0.5, pip_pos.y - 0.5}, {pip_pos.x + 0.5, pip_pos.y + 0.5}},
                                                      type = {"tree", "simple-entity"}}) do
      e.destroy()
    end
    if surface.can_place_entity{name = "pipe", position = pip_pos, force = force} then
      if inv.get_item_count("pipe") > 0 then
        local pok = AIActions.run(character, {action = "place", item = "pipe", position = pip_pos})
        if pok then
          pipes_laid = pipes_laid + 1
          local pe = surface.find_entities_filtered{name = "pipe", position = pip_pos, radius = 0.5, limit = 1}[1]
          if pe then AIRegistry.own(pe) end
        end
      else
        local g = surface.create_entity{name = "entity-ghost", inner_name = "pipe", position = pip_pos, force = force}
        if g then
          AIRegistry.register_ghost(g)
          pipes_laid = pipes_laid + 1
        end
      end
    end
  end

  return true, string.format("built offshore pump at {%.1f, %.1f} with %d lead pipe(s)", found_pos.x, found_pos.y, pipes_laid)
end

-- -------------------------------------------------------------------------
-- build_radar — places a radar to survey distant chunks.
-- -------------------------------------------------------------------------
local function skill_build_radar(character, p)
  local surface, force = character.surface, character.force
  local center = character.position
  local home = AICharacter.get_home(surface) or center

  if surface.count_entities_filtered{name = "radar", force = force, position = home, radius = 50, limit = 1} > 0 then
    return false, "build_radar: a radar is already surveying near home"
  end

  local inv = inv_of(character)
  local recipe = force.recipes["radar"]
  if recipe and not recipe.enabled then
    return false, "build_radar: radar technology not yet researched"
  end

  local spot = surface.find_non_colliding_position("radar", {x = home.x + 10, y = home.y + 10}, 20, 1)
  if not spot then return false, "build_radar: no clear spot for radar near home" end

  if inv.get_item_count("radar") == 0 then
    if recipe and character.get_craftable_count(recipe) > 0 then
      character.begin_crafting{recipe = "radar", count = 1, silent = true}
    end
    local g = surface.create_entity{name = "entity-ghost", inner_name = "radar", position = spot, force = force}
    AIRegistry.register_ghost(g)
    return true, string.format("build_radar: placed radar ghost at {%.1f, %.1f} — build_ghosts next", spot.x, spot.y)
  end

  inv.remove{name = "radar", count = 1}
  local radar = surface.create_entity{name = "radar", position = spot, force = force}
  if not radar then
    inv.insert{name = "radar", count = 1}
    return false, "build_radar: failed to place radar"
  end
  AIRegistry.add(radar)
  AIRegistry.own(radar)

  if surface.count_entities_filtered{type = "electric-pole", position = spot, radius = 7} == 0 then
    local pole_pos = surface.find_non_colliding_position("small-electric-pole", {x = spot.x + 2, y = spot.y + 2}, 4, 0.5)
    if pole_pos then
      if inv.get_item_count("small-electric-pole") > 0 then
        inv.remove{name = "small-electric-pole", count = 1}
        local pole = surface.create_entity{name = "small-electric-pole", position = pole_pos, force = force}
        if pole then
          AIRegistry.add(pole)
          AIRegistry.own(pole)
        end
      else
        local g = surface.create_entity{name = "entity-ghost", inner_name = "small-electric-pole", position = pole_pos, force = force}
        AIRegistry.register_ghost(g)
      end
    end
  end

  return true, string.format("built radar at {%.1f, %.1f} to survey surrounding terrain", spot.x, spot.y)
end

-- A chest item for plans that need `n`: what the AI holds enough of, else
-- wooden when there's wood for it, else iron.
local function chest_for(character, n)
  local inv = inv_of(character)
  for _, name in ipairs({"wooden-chest", "iron-chest"}) do
    if inv.get_item_count(name) >= n then return name end
  end
  return inv.get_item_count("wood") >= 2 * n and "wooden-chest" or "iron-chest"
end

-- Electric drill -> furnace -> inserter -> chest pairs (or electric drill -> chest for coal/stone).
-- Returns nil (use burner drills instead) only when electric technology is not yet unlocked.
function build_electric_miner(character, resource, want, out_kind)
  local force, inv = character.force, inv_of(character)
  local recipe = force.recipes["electric-mining-drill"]
  if not (recipe and recipe.enabled) then return nil end
  if not AILayout.nearest_pole(character, character.position) then
    return false, "build_miner: electric drills need power — build_power or extend poles first"
  end
  local chest = chest_for(character, want)
  if out_kind == "field" then
    local plan = AILayout.find_mining_field(character, resource, character.position, {rate = (want or 2) * 18.75, chest = chest})
    if not plan then
      return false, "build_miner: no spot on the " .. resource .. " patch for an electric mining field"
    end
    local ready, why = stock_up(character, AILayout.items({plan}), "build_miner")
    if not ready then return false, why end
    local ok, res = AILayout.build(character, plan)
    if not ok then return false, "build_miner: " .. tostring(res) end
    -- Remember the field so perception can watch its patch run down (AILayout.fields_report).
    local surface = character.surface
    local ap = storage.ai_player
    local remaining = AILayout.field_resource_remaining(surface, plan.bounds, resource)
    ap.fields = ap.fields or {}
    ap.fields[#ap.fields + 1] = {
      resource = resource, surface = surface.name, bounds = plan.bounds, furnaces = plan.furnaces,
      position = {x = math.floor(plan.place[1].position.x), y = math.floor(plan.place[1].position.y)},
      initial = remaining, remaining = remaining, checked = game.tick,
    }
    while #ap.fields > 12 do table.remove(ap.fields, 1) end
    return true, string.format("built electric mining field on %s (%d drills, %d furnaces, %d coal drill(s))",
      resource, plan.drills or 0, plan.furnaces or 0, plan.coal_drills or 0)
  end
  if out_kind == "belt" then
    local plan = AILayout.find_electric_row(character, resource, character.position, {count = math.max(2, want), chest = chest})
    if not plan then
      return false, "build_miner: no spot on the " .. resource .. " patch for an electric drill row — try output=furnace or chest"
    end
    local ready, why = stock_up(character, AILayout.items({plan}), "build_miner")
    if not ready then return false, why end
    local ok, res = AILayout.build(character, plan)
    if not ok then return false, "build_miner: " .. tostring(res) end
    local drills_placed = 0
    for _, e in ipairs(res) do
      if e.name == "electric-mining-drill" then drills_placed = drills_placed + 1 end
    end
    return true, string.format("built electric drill row (%d drills) on %s at {%d,%d}",
      drills_placed, resource, math.floor(res[1].position.x), math.floor(res[1].position.y))
  end
  local built, first, err = 0, nil, nil
  for _ = 1, want do
    local plan
    if out_kind == "chest" then
      plan = AILayout.find_electric_chest(character, resource, character.position, {chest = chest})
    else
      plan = AILayout.find_electric_pair(character, resource, character.position, {chest = chest})
    end
    if not plan then
      err = err or ("no spot on the " .. resource .. " patch for an electric drill")
      break
    end
    local ready, why = stock_up(character, AILayout.items({plan}), "build_miner")
    if not ready then return false, why end
    local ok, res = AILayout.build(character, plan)
    if not ok then err = res; break end
    built = built + 1
    first = first or res[1].position
  end
  if built == 0 then
    return false, "build_miner: " .. (err or ("no spot on " .. resource .. " patch for electric drill"))
  end
  local detail = string.format("built %d electric drill%s on %s at {%d,%d}",
    built, out_kind == "chest" and "->chest" or "->furnace->inserter->chest pair(s)", resource, math.floor(first.x), math.floor(first.y))
  if built < want then detail = detail .. "; stopped: " .. tostring(err) end
  return true, detail
end

-- Whether an assembling-machine-1 can run this recipe (category match, no fluids).
local function asm_can_make(recipe)
  local cats = prototypes.entity["assembling-machine-1"].crafting_categories or {}
  local ok = false
  for _, c in ipairs(recipe.categories or {}) do if cats[c] then ok = true end end
  for _, ing in ipairs(recipe.ingredients) do if ing.type == "fluid" then return false end end
  return ok
end

-- -------------------------------------------------------------------------
-- build_assembler(recipe, count) — assembler with the recipe set, an input
-- chest -> inserter in front and inserter -> output chest behind, powered by
-- poles wired to the nearest grid pole. `tend` then hauls plates in.
-- -------------------------------------------------------------------------
local function skill_build_assembler(character, p)
  local recipe = p.recipe or p.item
  local force = character.force
  if not recipe then return false, "build_assembler: 'recipe' is required (e.g. iron-gear-wheel)" end
  local r = force.recipes[recipe]
  if not r then return false, "build_assembler: no recipe named " .. recipe end
  if not r.enabled then return false, "build_assembler: " .. recipe .. " is locked — " .. unlock_hint(force, recipe) end
  if not force.recipes["assembling-machine-1"].enabled then
    return false, "build_assembler: assemblers are locked — research automation first"
  end
  if not asm_can_make(r) then
    return false, "build_assembler: " .. recipe .. " needs a different machine than assembling-machine-1 "
      .. "(a fluid recipe, or a special crafting category)"
  end
  local surface = character.surface
  local want = math.max(1, math.min(tonumber(p.count) or 1, 3))
  local home = AICharacter.get_home(surface) or character.position
  local chest = chest_for(character, 2 * want)
  local claimed, built, last, notes = {}, 0, nil, nil
  for i = 1, want do
    local plan = AILayout.find_assembler_unit(character, recipe, home, claimed, chest)
    if not plan then
      notes = "no clear spot near home for another assembler cell"
      break
    end
    if not plan.grid then
      return false, "build_assembler: no electric pole anywhere — build_power first"
    end
    local ready, why = stock_up(character, AILayout.items({plan}), "build_assembler")
    if not ready then
      if built == 0 then return false, why end
      notes = why
      break
    end
    local ok, res = AILayout.build(character, plan)
    if not ok then
      if built == 0 then return false, "build_assembler: " .. res end
      notes = res
      break
    end
    built = built + 1
    last = plan
    for _, b in ipairs(plan.boxes) do claimed[#claimed + 1] = b end
  end
  if built == 0 then return false, "build_assembler: " .. tostring(notes) end
  local a = last.anchor
  local detail = string.format("built %d %s assembler cell(s) at {%d,%d}: input chest -> inserter -> assembler -> "
    .. "inserter -> output chest; tend hauls plates in", built, recipe, a.x, a.y)
  if notes then detail = detail .. "; stopped: " .. notes end
  return true, detail
end

-- -------------------------------------------------------------------------
-- build_red_cell() — one gear assembler feeding two red-science assemblers
-- that drop into a lab (or a chest), with input chests and poles.
-- -------------------------------------------------------------------------
local function skill_build_red_cell(character, _)
  local force = character.force
  local surface = character.surface
  if not force.recipes["assembling-machine-1"].enabled then
    return false, "build_red_cell: assemblers are locked — research automation first"
  end
  local inv = inv_of(character)
  for _, a in ipairs(surface.find_entities_filtered{type = "assembling-machine", force = force}) do
    local r = a.get_recipe()
    if a.last_user == nil and r and r.name == "automation-science-pack" then
      return false, "build_red_cell: a red-science cell already exists — tend it"
    end
  end
  local home = AICharacter.get_home(surface) or character.position
  local plan = AILayout.find_red_cell(character, home, chest_for(character, 5), inv.get_item_count("lab"))
  if not plan then
    return false, "build_red_cell: no clear 15x9 area near home for the cell (trees/rocks/buildings in the way?)"
  end
  if not plan.grid then return false, "build_red_cell: no electric pole anywhere — build_power first" end
  local ready, why = stock_up(character, AILayout.items({plan}), "build_red_cell")
  if not ready then return false, why end
  local ok, res = AILayout.build(character, plan)
  if not ok then return false, "build_red_cell: " .. res end
  local a = plan.anchor
  return true, string.format("built the red-science cell at {%d,%d}: gear assembler feeding 2 science assemblers; "
    .. "tend hauls iron and copper plates into its chests", a.x, a.y)
end

-- -------------------------------------------------------------------------
-- build_green_cell() — green science from assembler units that build_assembler
-- makes (chest -> inserter -> assembler -> inserter -> chest): gears, copper cable,
-- circuits, inserters, belts, and two logistic-science-pack assemblers. tend hauls
-- plates in, carries each unit's output to the next unit's input chest, and the
-- packs to the labs. Builds up to 3 missing units per call.
-- -------------------------------------------------------------------------
local GREEN_UNITS = {"iron-gear-wheel", "copper-cable", "electronic-circuit", "inserter", "transport-belt",
                     "logistic-science-pack", "logistic-science-pack"}

local function skill_build_green_cell(character, _)
  local force = character.force
  local surface = character.surface
  if not force.recipes["logistic-science-pack"].enabled then
    return false, "build_green_cell: logistic-science-pack is locked — research it first"
  end
  local have = {}
  for _, a in ipairs(surface.find_entities_filtered{type = "assembling-machine", force = force}) do
    local r = a.get_recipe()
    if a.last_user == nil and r then have[r.name] = (have[r.name] or 0) + 1 end
  end
  local missing = {}
  for _, recipe in ipairs(GREEN_UNITS) do
    if (have[recipe] or 0) > 0 then have[recipe] = have[recipe] - 1 else missing[#missing + 1] = recipe end
  end
  if #missing == 0 then
    return false, "build_green_cell: all 7 units exist — tend them"
  end
  local built, notes = {}, nil
  for i = 1, math.min(#missing, 3) do
    local ok, detail = skill_build_assembler(character, {recipe = missing[i], count = 1})
    if not ok then notes = detail; break end
    built[#built + 1] = missing[i]
  end
  if #built == 0 then return false, notes end
  local detail = string.format("built green-science units: %s (%d of 7 still to build)", table.concat(built, ", "),
                               #missing - #built)
  if notes then detail = detail .. "; stopped: " .. notes end
  return true, detail
end

-- -------------------------------------------------------------------------
-- build_defense([count]) — 2-4 gun turrets on the side of home facing the nearest
-- enemy nest (or the latest attack), each loaded with firearm magazines. tend keeps
-- them stocked.
-- -------------------------------------------------------------------------
local TURRET_AMMO, TURRET_MAX_COUNT = 10, 4

local function skill_build_defense(character, p)
  local force, surface = character.force, character.surface
  local recipe = force.recipes["gun-turret"]
  if not (recipe and recipe.enabled) then
    return false, "build_defense: gun-turret is locked — research gun-turret first"
  end
  local site_name = p.site or "home"
  local center = AICharacter.get_home(surface) or character.position
  local dist_out = 18
  local check_radius = 60
  if p.site == "power" then
    local boiler = surface.find_entities_filtered{name = "boiler", force = force, limit = 1}[1]
    if boiler and boiler.valid then
      center = boiler.position
      dist_out = 8
      check_radius = 25
    end
  end

  local want = math.max(1, math.min(tonumber(p.count) or (p.site == "power" and 1 or 3), TURRET_MAX_COUNT))
  local have = surface.count_entities_filtered{name = "gun-turret", force = force, position = center, radius = check_radius}
  if have >= want then
    return false, string.format("build_defense: %d gun turrets already stand near %s — tend keeps them stocked", have, site_name)
  end
  -- Which way the danger lies: the nearest nest, else where the AI was last attacked.
  local dx, dy
  local nest, nd
  for _, e in ipairs(surface.find_entities_filtered{position = center, radius = 300, force = "enemy",
                                                    type = {"unit-spawner", "turret"}}) do
    local d = (e.position.x - center.x) ^ 2 + (e.position.y - center.y) ^ 2
    if not nd or d < nd then nest, nd = e, d end
  end
  local atk = storage.ai_player and storage.ai_player.last_attack
  if nest then dx, dy = nest.position.x - center.x, nest.position.y - center.y
  elseif atk then dx, dy = atk.x - center.x, atk.y - center.y
  else dx, dy = 1, 0 end
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then dx, dy, len = 1, 0, 1 end
  dx, dy = dx / len, dy / len
  local need = want - have
  local ready, why = stock_up(character, {["gun-turret"] = need, ["firearm-magazine"] = need * TURRET_AMMO}, "build_defense")
  if not ready then return false, why end
  local inv = inv_of(character)
  local built = 0
  -- a line across the approach, dist_out tiles out from center, 4 tiles apart
  for i = 1, need do
    local off = (i - (need + 1) / 2) * 4
    local at = {x = center.x + dx * dist_out - dy * off, y = center.y + dy * dist_out + dx * off}
    local spot = surface.find_non_colliding_position("gun-turret", at, 8, 1)
    if spot and AIActions.run(character, {action = "place", item = "gun-turret", position = spot}) then
      local t = surface.find_entities_filtered{name = "gun-turret", position = spot, radius = 1, limit = 1}[1]
      if t then
        local put = t.insert{name = "firearm-magazine", count = math.min(TURRET_AMMO, inv.get_item_count("firearm-magazine"))}
        if put > 0 then inv.remove{name = "firearm-magazine", count = put} end
        built = built + 1
      end
    end
  end
  if built == 0 then return false, "build_defense: no clear spot for a gun turret toward the threat" end
  return true, string.format("built %d gun turret(s) %d tiles toward %s near %s, each with %d magazines", built, dist_out,
    nest and string.format("the nest at {%d,%d}", nest.position.x, nest.position.y) or "the last attack", site_name, TURRET_AMMO)
end

-- -------------------------------------------------------------------------
-- tend() — look after the AI's own burner base near home in one call:
-- collect plates/ore from its furnaces and chests, refuel its burners, feed
-- ore into idle furnaces, and give drills that spill onto the ground a
-- collector. Only touches entities the AI placed (create_entity leaves
-- last_user nil; anything the human builds has them as last_user), so in
-- co-op it never empties the player's machines.
-- -------------------------------------------------------------------------
local SMELTS = {["iron-ore"] = "iron-plate", ["copper-ore"] = "copper-plate", ["stone"] = "stone-brick"}
local TURRET_REFILL = 10
AISkills.TEND_TYPES = {"mining-drill", "furnace", "container", "boiler", "inserter", "assembling-machine", "lab",
                       "ammo-turret"}
local TEND_MAX = 400      -- machines one tend looks after
-- Hauling into assembler chests: fill each to HAUL_FILL, at most HAUL_CAP items per
-- tend, and never dig into the last HAUL_RESERVE of anything the AI crafts with.
-- Plates, steel, and stone keep a higher reserve so hand-crafting boilers, engines,
-- drills, and pipes never starves.
local HAUL_FILL, HAUL_CAP, HAUL_RESERVE = 50, 200, 20
local RAW_RESERVE = 40    -- iron-plate, copper-plate, steel-plate, stone kept back for crafting

local function item_reserve(name, made_by_assembler)
  if name == "iron-plate" or name == "copper-plate" or name == "steel-plate" or name == "stone" then
    return RAW_RESERVE
  end
  -- Even if made by assembler units, keep a working reserve in character inventory
  -- so craft_for (e.g. steam-engine needing gears) does not get completely drained.
  if made_by_assembler then
    return 15
  end
  return HAUL_RESERVE
end

local function ai_owned(e) return AIRegistry.is_owned(e) end

local function take_all(from, inv, got)
  if not (from and from.valid) then return end
  for _, it in ipairs(from.get_contents()) do
    local n = inv.insert{name = it.name, count = it.count, quality = it.quality}
    if n > 0 then
      from.remove{name = it.name, count = n, quality = it.quality}
      got[it.name] = (got[it.name] or 0) + n
    end
  end
end

AISkills.take_all = take_all

-- Furnace results, and the chests that drills / assembler inserters fill, into `inv`
-- (other chests may be storage the AI deposited into on purpose). got: item -> count.
function AISkills.collect_outputs(inv, own, got)
  for _, e in ipairs(own) do
    if e.valid and e.last_user ~= nil then
      -- a human's machine (it may sit in the owned set after they took it over): hands off
    elseif e.valid and e.type == "furnace" then
      take_all(e.get_inventory(defines.inventory.crafter_output), inv, got)
    elseif e.valid and (e.type == "mining-drill" or e.type == "inserter") and e.drop_target
           and e.drop_target.type == "container" and ai_owned(e.drop_target) then
      take_all(e.drop_target.get_inventory(defines.inventory.chest), inv, got)
    end
  end
end

-- Coal into every burner of `own` that runs low, and into the furnaces a drill feeds.
-- Returns how many were refuelled.
function AISkills.refuel(inv, own)
  local fueled = 0
  -- If inventory is low on coal, replenish from owned coal mining chests
  if inv.get_item_count("coal") < 20 then
    for _, e in ipairs(own) do
      if e.valid and e.type == "container" and e.last_user == nil then
        local cinv = e.get_inventory(defines.inventory.chest)
        if cinv and cinv.valid and cinv.get_item_count("coal") > 0 then
          local taken = cinv.remove{name = "coal", count = math.min(50, cinv.get_item_count("coal"))}
          if taken > 0 then
            inv.insert{name = "coal", count = taken}
            if inv.get_item_count("coal") >= 50 then break end
          end
        end
      end
    end
  end

  for _, e in ipairs(own) do
    local fb = e.valid and e.last_user == nil and e.get_fuel_inventory and e.get_fuel_inventory()
    -- Boilers run the whole base: keep them at 50 coal, not 10.
    local boiler = e.valid and e.type == "boiler"
    if fb and fb.valid and fb.get_item_count("coal") < (boiler and 30 or 5) then
      local want = boiler and (50 - fb.get_item_count("coal")) or 10
      local n = math.min(want, inv.get_item_count("coal"))
      if n > 0 then
        local ins = fb.insert{name = "coal", count = n}
        if ins > 0 then inv.remove{name = "coal", count = ins}; fueled = fueled + 1 end
      end
    end
  end
  for _, d in ipairs(own) do
    local tgt = d.valid and d.type == "mining-drill" and d.drop_target
    if tgt and tgt.type == "furnace" and ai_owned(tgt) then
      local fb = tgt.get_fuel_inventory()
      if fb and fb.get_item_count("coal") < 5 and inv.get_item_count("coal") > 0 then
        local ins = fb.insert{name = "coal", count = math.min(10, inv.get_item_count("coal"))}
        if ins > 0 then inv.remove{name = "coal", count = ins}; fueled = fueled + 1 end
      end
    end
  end
  return fueled
end

-- Gun turrets of `own` back up to TURRET_REFILL magazines from the inventory; with `craft`,
-- hand-craft magazines when the inventory has none. Prioritizes piercing (red) ammo when available.
function AISkills.top_up_turrets(character, inv, own, craft)
  local given = 0
  local ammos = {"piercing-rounds-magazine", "firearm-magazine"}
  for _, e in ipairs(own) do
    if e.valid and e.type == "ammo-turret" then
      local ai = e.get_inventory(defines.inventory.turret_ammo)
      if ai then
        local current_total = 0
        for _, a in ipairs(ammos) do current_total = current_total + ai.get_item_count(a) end
        local short = TURRET_REFILL - current_total
        if short > 0 then
          if craft and inv.get_item_count("firearm-magazine") == 0 and inv.get_item_count("piercing-rounds-magazine") == 0 then
            local red_r = character.force.recipes["piercing-rounds-magazine"]
            if red_r and red_r.enabled and character.get_craftable_count(red_r) > 0 then
              character.begin_crafting{recipe = "piercing-rounds-magazine", count = 5, silent = true}
            else
              character.begin_crafting{recipe = "firearm-magazine", count = 5, silent = true}
            end
          end
          for _, a in ipairs(ammos) do
            local avail = inv.get_item_count(a)
            if avail > 0 and short > 0 then
              local n = math.min(short, avail)
              local ins = ai.insert{name = a, count = n}
              if ins > 0 then
                inv.remove{name = a, count = ins}
                given = given + ins
                short = short - ins
              end
            end
          end
        end
      end
    end
  end
  return given
end

-- What a drill mines: its current target, else the ore under it.
function AISkills.drill_resource(drill)
  local t = drill.mining_target
  if t and t.valid then return t.name end
  local under = drill.surface.find_entities_filtered{type = "resource", position = drill.position, radius = 1, limit = 1}[1]
  return under and under.name or nil
end

local function skill_tend(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  local center = AICharacter.get_home(surface) or character.position
  local got, fueled, fed, fixed, notes = {}, 0, 0, 0, {}

  -- Every machine the AI placed (registry.lua owned set; ore patches can lie 100+ tiles from
  -- home and from each other, and the AI only teleports below where it must place something).
  if storage.ai_player.owned == nil then AIRegistry.rebuild_owned(AISkills.TEND_TYPES) end
  local own = {}
  for _, e in ipairs(AIRegistry.owned(surface, AISkills.TEND_TYPES)) do
    own[#own + 1] = e
    if #own >= TEND_MAX then break end
  end
  if #own == 0 then
    return true, "tend: no AI-built drills/furnaces/chests yet"
  end
  local origin = character.position

  -- 1. collect output: furnace results, and chests a drill fills (other chests
  -- may be storage the AI deposited into on purpose)
  AISkills.collect_outputs(inv, own, got)

  -- 1a. what assembler units made: the output chest of each unit goes into the inventory
  -- (the next unit's input chest is filled from it in step 5; science packs go to the labs)
  local made = {}
  for _, e in ipairs(own) do
    if e.valid and e.type == "assembling-machine" then
      local r = e.get_recipe()
      if r then made[r.name] = true end
      local out = e.get_inventory(defines.inventory.crafter_output)
      if out and not out.is_empty() then
        take_all(out, inv, got)
      end
    end
    local src, dst = e.valid and e.type == "inserter" and e.pickup_target, e.valid and e.type == "inserter" and e.drop_target
    if src and dst and src.valid and dst.valid and src.type == "assembling-machine" and dst.type == "container" then
      take_all(dst.get_inventory(defines.inventory.chest), inv, got)
    end
  end

  -- 1b. drills whose ore ran out: pick them (and the furnace/chest only they fed) up, so the
  -- planner rebuilds them on fresh ore
  local recycled = 0
  local feeding = {}                  -- collector unit_number -> drills dropping into it
  for _, d in ipairs(own) do
    local t = d.valid and d.type == "mining-drill" and d.drop_target
    if t and t.unit_number then feeding[t.unit_number] = (feeding[t.unit_number] or 0) + 1 end
  end
  for _, d in ipairs(own) do
    if d.valid and d.type == "mining-drill" and d.status == defines.entity_status.no_minable_resources then
      local t = d.drop_target
      if d.mine{inventory = inv, force = false, raise_destroyed = true} then
        recycled = recycled + 1
        if t and t.valid and ai_owned(t) and (t.type == "furnace" or t.type == "container")
           and (feeding[t.unit_number] or 0) <= 1 then
          take_all(t.get_inventory(t.type == "furnace" and defines.inventory.crafter_output or defines.inventory.chest), inv, got)
          t.mine{inventory = inv, force = false, raise_destroyed = true}
        end
      end
    end
  end

  -- 2. drills spilling onto the ground: pick the spill up, place a collector
  for _, d in ipairs(own) do
    if d.valid and d.type == "mining-drill" and not d.drop_target
       and surface.count_entities_filtered{type = "transport-belt", position = d.drop_position, radius = 0.5} == 0 then
      local drop = d.drop_position
      for _, ie in ipairs(surface.find_entities_filtered{type = "item-entity", position = drop, radius = 1.5}) do
        local st = ie.stack
        if st and st.valid_for_read then
          local name, n = st.name, inv.insert(st)
          if n > 0 then
            got[name] = (got[name] or 0) + n
            if n >= st.count then ie.destroy() else st.count = st.count - n end
          end
        end
      end
      if math.abs(d.position.x - character.position.x) + math.abs(d.position.y - character.position.y) > 12 then
        -- placing needs the AI beside the drill; it goes back to where it was at the end
        local near = surface.find_non_colliding_position("character", d.position, 6, 0.5)
        if near then character.teleport(near) end
      end
      local res = AISkills.drill_resource(d)
      local want = (res and SMELTS[res] and res ~= "stone") and {"stone-furnace"} or {"wooden-chest", "iron-chest"}
      local placed
      for _, item in ipairs(want) do
        local at = inv.get_item_count(item) > 0 and AILayout.collector_position(d, item)
        if at and AIActions.run(character, {action = "place", item = item, position = at}) then
          placed = item
          break
        end
      end
      if placed then
        fixed = fixed + 1
      else
        -- Make one; the turn queue waits for the craft before the next move.
        local r = character.force.recipes[want[1]]
        local crafting = r and r.enabled and character.get_craftable_count(r) > 0
          and character.begin_crafting{recipe = r, count = 1, silent = true} > 0
        local key = math.floor(d.position.x) .. "," .. math.floor(d.position.y)
        if not notes[key] then
          notes[key] = true
          notes[#notes + 1] = string.format("drill on %s at {%s} needs a %s under its output%s",
            res or "?", key, want[1], crafting and " — crafting one, tend again to place it" or " — craft_for " .. want[1])
        end
      end
    end
  end

  character.teleport(origin)

  -- 3. refuel (furnaces placed in step 2 included)
  fueled = AISkills.refuel(inv, own)

  -- 4. feed idle furnaces with matching ore (never mix: output must be empty or
  -- the same plate). Furnaces a drill feeds are left to the drill.
  local drill_fed = {}
  for _, d in ipairs(own) do
    local tgt = d.valid and d.type == "mining-drill" and d.drop_target
    if tgt and tgt.unit_number then drill_fed[tgt.unit_number] = true end
  end
  for _, e in ipairs(own) do
    if e.valid and e.type == "furnace" and not drill_fed[e.unit_number] then
      local src = e.get_inventory(defines.inventory.crafter_input)
      local out = e.get_inventory(defines.inventory.crafter_output)
      if src and src.is_empty() then
        local made = out and not out.is_empty() and out[1].valid_for_read and out[1].name or nil
        for ore, plate in pairs(SMELTS) do
          -- stone stays in the inventory: drills and furnaces are built from it
          if ore ~= "stone" and (made == nil or made == plate) and inv.get_item_count(ore) > 0 then
            local ins = src.insert{name = ore, count = math.min(20, inv.get_item_count(ore))}
            if ins > 0 then inv.remove{name = ore, count = ins}; fed = fed + 1; break end
          end
        end
      end
    end
  end

  -- 5. assemblers: haul plates from the AI's inventory (what steps 1 and 4 gathered)
  -- into their input chests, and finished science packs into the labs. Capped so
  -- a tend stays short and the AI keeps plates to craft with.
  local hauled, packs_fed = 0, 0
  local feeds = {}
  for _, e in ipairs(own) do
    if e.valid and e.type == "inserter" then
      local src, dst = e.pickup_target, e.drop_target
      if src and dst and src.valid and dst.valid and dst.type == "assembling-machine" and src.type == "container" then
        local f = feeds[dst.unit_number] or {asm = dst, chests = {}}
        f.chests[#f.chests + 1] = src
        feeds[dst.unit_number] = f
      end
    end
  end
  for _, f in pairs(feeds) do
    local r = f.asm.valid and f.asm.get_recipe()
    for _, ing in ipairs(r and r.ingredients or {}) do
      for _, chest in ipairs(f.chests) do
        local ci = ing.type == "item" and chest.valid and chest.get_inventory(defines.inventory.chest)
        if ci then
          local reserve = item_reserve(ing.name, made[ing.name])
          local n = math.min(HAUL_FILL - ci.get_item_count(ing.name),
                             inv.get_item_count(ing.name) - reserve, HAUL_CAP - hauled)
          if n > 0 then
            local ins = ci.insert{name = ing.name, count = n}
            if ins > 0 then inv.remove{name = ing.name, count = ins}; hauled = hauled + ins end
          end
        end
      end
    end
  end
  for _, e in ipairs(own) do
    if e.valid and e.type == "assembling-machine" then
      local r = e.get_recipe()
      local ci = e.get_inventory(defines.inventory.crafter_input)
      if r and ci then
        for _, ing in ipairs(r.ingredients or {}) do
          if ing.type == "item" and ci.get_item_count(ing.name) < 5 then
            local reserve = item_reserve(ing.name, made[ing.name])
            local avail = inv.get_item_count(ing.name) - reserve
            if avail > 0 then
              local n = math.min(10 - ci.get_item_count(ing.name), avail, HAUL_CAP - hauled)
              if n > 0 then
                local ins = ci.insert{name = ing.name, count = n}
                if ins > 0 then inv.remove{name = ing.name, count = ins}; hauled = hauled + ins end
              end
            elseif character.force.recipes[ing.name] and character.force.recipes[ing.name].enabled
                   and inv.get_item_count("iron-plate") > (RAW_RESERVE + 20)
                   and character.get_craftable_count(character.force.recipes[ing.name]) > 0 then
              character.begin_crafting{recipe = ing.name, count = 5, silent = true}
            end
          end
        end
      end
    end
  end
  for _, lab in ipairs(own) do
    if lab.valid and lab.type == "lab" then
      local li = lab.get_inventory(defines.inventory.lab_input)
      for _, it in ipairs(inv.get_contents()) do
        if li and it.name:find("science%-pack$") and li.get_item_count(it.name) < 10 then
          local ins = li.insert{name = it.name, count = math.min(10, it.count)}
          if ins > 0 then inv.remove{name = it.name, count = ins}; packs_fed = packs_fed + ins end
        end
      end
    end
  end

  -- 5b. gun turrets: top their ammo up from the inventory, crafting magazines when out
  local ammo_given = AISkills.top_up_turrets(character, inv, own, true)

  -- 6. wire consumers no pole reaches (the lab went down before the grid got there)
  local wired = 0
  for _, e in ipairs(own) do
    if wired < 2 and e.valid and (e.type == "lab" or e.type == "assembling-machine"
                                  or e.type == "mining-drill" or e.type == "inserter"
                                  or e.type == "radar" or e.type == "pumpjack")
       and (e.status == defines.entity_status.no_power
            or e.status == defines.entity_status.not_plugged_in_electric_network) then
      local plan = AILayout.find_consumer_poles(character, e)
      if plan and stock_up(character, AILayout.items({plan}), "tend") and AILayout.build(character, plan) then
        wired = wired + 1
      end
    end
  end
  if wired > 0 then character.teleport(origin) end

  local total_hauled = hauled + packs_fed
  if total_hauled > 0 and storage.ai_player then
    storage.ai_player.hand_hauls = storage.ai_player.hand_hauls or {}
    table.insert(storage.ai_player.hand_hauls, {tick = game.tick, count = total_hauled})
    local cur_tick = game.tick
    local recent = {}
    for _, h in ipairs(storage.ai_player.hand_hauls) do
      if cur_tick - h.tick <= 126000 then recent[#recent + 1] = h end
    end
    storage.ai_player.hand_hauls = recent
  end

  local parts = {}
  for name, n in pairs(got) do parts[#parts + 1] = n .. "x " .. name end
  table.sort(parts)
  local idle = #parts == 0 and fueled == 0 and fed == 0 and fixed == 0 and hauled == 0 and packs_fed == 0
               and wired == 0 and recycled == 0 and ammo_given == 0
  local detail = string.format("tend: collected %s; refueled %d, fed %d furnace(s), fixed %d spilling drill(s)",
    #parts > 0 and table.concat(parts, ", ") or "nothing", fueled, fed, fixed)
  if hauled > 0 then detail = detail .. string.format("; hauled %d plates into assembler chests", hauled) end
  if packs_fed > 0 then detail = detail .. string.format("; fed %d science pack(s) to labs", packs_fed) end
  if wired > 0 then detail = detail .. string.format("; wired %d unpowered machine(s) to the grid", wired) end
  if ammo_given > 0 then detail = detail .. string.format("; loaded %d magazine(s) into gun turrets", ammo_given) end
  if recycled > 0 then detail = detail .. string.format("; picked up %d drill(s) whose ore ran out", recycled) end
  if inv.get_item_count("coal") == 0 then detail = detail .. "; OUT OF COAL — gather coal or build_miner coal" end
  if #notes > 0 then detail = detail .. "; " .. table.concat(notes, "; ", 1, math.min(#notes, 3)) end
  -- Nothing done = not useful this turn; the bridge doesn't count it as a
  -- failure, but the model should move on.
  return not idle, detail
end

-- -------------------------------------------------------------------------
-- Registry + required params (mirrored in the bridge router prompt/validation)
-- -------------------------------------------------------------------------
AISkills.REGISTRY = {
  build_ghosts     = skill_build_ghosts,
  deconstruct      = skill_deconstruct,
  gather           = skill_gather,
  build_miner      = skill_build_miner,
  build_power      = skill_build_power,
  build_assembler  = skill_build_assembler,
  build_red_cell   = skill_build_red_cell,
  build_green_cell = skill_build_green_cell,
  build_defense    = skill_build_defense,
  build_smelter    = skill_build_smelter,
  fuel_all         = skill_fuel_all,
  tend             = skill_tend,
  loot_chests      = skill_loot_chests,
  deposit_to_chest = skill_deposit_to_chest,
  return_home      = skill_return_home,
  research         = skill_research,
  ["goto"]         = skill_goto,
  place_blueprint  = skill_place_blueprint,
  craft_for        = skill_craft_for,
  connect_belt     = skill_connect_belt,
  connect_pipe     = skill_connect_pipe,
  connect_ports    = skill_connect_ports,
  build_pumpjack   = skill_build_pumpjack,
  build_offshore_pump = skill_build_offshore_pump,
  build_radar      = skill_build_radar,
  connect_power    = skill_connect_power,
  fix_flow         = skill_fix_flow,
}

-- -------------------------------------------------------------------------
-- Unified executor: a response entry is either a skill {skill=...} or a
-- primitive {action=...}. Dispatch each, collect E1 results.
-- -------------------------------------------------------------------------
-- Run a single entry (skill OR primitive) with error isolation.
-- Returns (ok, detail, label). Shared by execute() and the external run()
-- entrypoint so there is exactly one dispatch path to keep correct.
local function run_entry(character, entry)
  local ok, detail, label
  if entry.skill then
    label = "skill:" .. tostring(entry.skill)
    local handler = AISkills.REGISTRY[entry.skill]
    if handler then
      local call_ok, rok, rdetail = AIDebug.xpcall(handler, character, entry)
      if not call_ok then
        -- rok is the traceback; keep the first line for the model, all of it
        -- for the debug log.
        ok, detail = false, "error: " .. tostring(rok):match("^[^\n]*")
        AIDebug.event("error", {skill = entry.skill, error = tostring(rok), entry = entry})
      else ok, detail = (rok ~= false), rdetail end
    else
      ok, detail = false, "unknown skill '" .. tostring(entry.skill) .. "'"
    end
  elseif entry.action then
    label = entry.action
    ok, detail = AIActions.run(character, entry)
  else
    label = "?"
    ok, detail = false, "entry has neither 'skill' nor 'action'"
  end
  AIDebug.event(entry.skill and "skill" or "action",
                {skill = entry.skill, action = entry.action, ok = (ok ~= false), detail = detail, entry = entry})
  return (ok ~= false), detail, label
end

-- Params copied into each result so the bridge can tell "the same move failed
-- again" (craft_for lab vs craft_for gear) without guessing.
local RESULT_KEYS = {"item", "tech", "resource", "recipe", "name", "ore", "output", "count"}

local function result_of(entry, ok, detail, label)
  local r = {action = label, ok = ok, detail = detail}
  for _, k in ipairs(RESULT_KEYS) do
    local v = entry[k]
    if type(v) == "string" or type(v) == "number" then r[k] = v end
  end
  return r
end

-- source_id: the request id this turn answers. The bridge counts a batch of
-- results once per id; manual runs (/ai-do) pass nil so they aren't counted.
function AISkills.execute(character, entries, source_id)
  if not character or not character.valid then return end
  local results = {}
  for _, entry in ipairs(entries) do
    local ok, detail, label = run_entry(character, entry)
    results[#results + 1] = result_of(entry, ok, detail, label)
  end
  local mem = storage.ai_player.memory
  mem.last_action_results = results
  mem.last_results_req_id = source_id
end

-- -------------------------------------------------------------------------
-- Turn queue: a bridge reply's moves run one after another over several
-- ticks. A move waits while the AI is still hand-crafting (so "craft_for a
-- drill, then build_miner" works in one turn), up to TURN_WAIT_TICKS; then it
-- runs anyway and reports what happened. No new request goes out until the
-- whole turn is done, so the model sees every result.
-- -------------------------------------------------------------------------
local TURN_WAIT_TICKS = 600
local FAST_DECIDE_TICKS = 60      -- at least 1 s between a finished turn and the next request

function AISkills.queue_turn(character, entries, source_id)
  -- A fight is on: the reflexes hold the character, the turn starts when it is over.
  if AIReflexes.in_combat() then
    local held = storage.ai_player.held_turn          -- a second reply joins the first, none is lost
    if held then
      for _, e in ipairs(entries) do held.entries[#held.entries + 1] = e end
      held.source_id = source_id
    else
      storage.ai_player.held_turn = {entries = entries, source_id = source_id}
    end
    return
  end
  storage.ai_player.turn = {entries = entries, i = 1, results = {}, source_id = source_id,
                            waited_from = nil}
  AISkills.step_turn(game.tick)
end

local function finish_turn(turn)
  local mem = storage.ai_player.memory
  mem.last_action_results = turn.results
  mem.last_results_req_id = turn.source_id
  storage.ai_player.turn = nil
  -- Ask for the next decision soon (autopilot turns chain), unless the turn did
  -- nothing: then the normal interval applies so failing moves can't spin.
  -- Only for autopilot turns (model turns keep the normal interval, so the GPU isn't
  -- asked nonstop), and a lone successful tend doesn't count as getting something done.
  local any_ok = false
  for _, r in ipairs(turn.results) do
    if r.ok and r.action ~= "skill:tend" then any_ok = true end
  end
  storage.ai_player.fast_decide_tick = (turn.autopilot and any_ok) and (game.tick + FAST_DECIDE_TICKS) or nil
end

function AISkills.step_turn(tick)
  local turn = storage.ai_player.turn
  if not turn then return end
  local character = storage.ai_player.character
  if not (character and character.valid) then
    turn.results[#turn.results + 1] = {action = "turn", ok = false, detail = "AI character is gone"}
    return finish_turn(turn)
  end
  local entry = turn.entries[turn.i]
  if not entry then return finish_turn(turn) end
  if turn.i > 1 and character.crafting_queue_size > 0 then
    turn.waited_from = turn.waited_from or tick
    if tick - turn.waited_from < TURN_WAIT_TICKS then return end
  end
  turn.waited_from = nil
  local ok, detail, label = run_entry(character, entry)
  turn.results[#turn.results + 1] = result_of(entry, ok, detail, label)
  turn.i = turn.i + 1
  if not turn.entries[turn.i] then finish_turn(turn) end
end

-- A player order shouldn't wait for the rest of the turn.
function AISkills.cancel_turn(reason)
  local turn = storage.ai_player.turn
  if not turn then return end
  for i = turn.i, #turn.entries do
    local e = turn.entries[i]
    turn.results[#turn.results + 1] = result_of(e, false, "cancelled: " .. reason,
      e.skill and ("skill:" .. e.skill) or e.action)
  end
  finish_turn(turn)
end

-- Single-entry runner for external (RCON/remote) callers. Same dispatch and
-- error isolation as execute(), but returns (ok, detail) directly instead of
-- recording into memory. Used by the "ai_player" remote interface (control.lua).
function AISkills.run(character, entry)
  if not character or not character.valid then
    return false, "no valid character"
  end
  local ok, detail = run_entry(character, entry)
  return ok, detail or ""
end

return AISkills
