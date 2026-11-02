-- Blueprint library + placement.
--
-- The bridge owns the library (blueprints/ in the repo) and pushes each entry
-- here over RCON in chunks (bp_chunk). Entries live in
-- storage.ai_player.blueprints[name] = {string, meta, hash}. The in-game
-- /ai-bp add command only exports the held blueprint/book to script-output;
-- the bridge imports it and pushes it back, so there is one source of truth.
--
-- Placement needs each blueprint's footprint and rotation offset. Rather than
-- trusting hand-written geometry, it is measured once per blueprint by
-- building it as ghosts on a hidden lab surface (all four rotations), then
-- cached in storage.ai_player.bp_geo[name].

AIBlueprints = {}

local LAB = "ai-player-bp-lab"
local DIRS = {defines.direction.north, defines.direction.east,
              defines.direction.south, defines.direction.west}
local MAX_BUILD_TRIES = 30
local MAX_CANDIDATES = 400
local MAX_PLACED_LOG = 50

-- Blueprint rotation about its origin, per 16-way direction (y points down).
local function rot(d, x, y)
  if d == defines.direction.east  then return -y, x end
  if d == defines.direction.south then return -x, -y end
  if d == defines.direction.west  then return y, -x end
  return x, y
end

-- Entity types that don't block a building spot (trees/rocks get marked for
-- deconstruction by a forced build; the rest are harmless).
local NON_BLOCKING = {"tree", "simple-entity", "resource", "fish", "corpse",
                      "item-entity", "character", "unit", "spider-unit"}

local function lib()
  storage.ai_player.blueprints = storage.ai_player.blueprints or {}
  return storage.ai_player.blueprints
end

local function geo_cache()
  storage.ai_player.bp_geo = storage.ai_player.bp_geo or {}
  return storage.ai_player.bp_geo
end

-- -------------------------------------------------------------------------
-- Library (remote interface backends)
-- -------------------------------------------------------------------------

-- One chunk of a blueprint string from the bridge. The buffer lives in storage
-- so a save (or a joining client) mid-transfer can't desync.
function AIBlueprints.receive_chunk(name, i, n, part, meta_json, total_len)
  storage.ai_player.bp_buf = storage.ai_player.bp_buf or {}
  local buf = storage.ai_player.bp_buf
  if i == 1 then buf[name] = {} end
  local b = buf[name]
  if not b then return "error: chunk " .. i .. " before chunk 1" end
  b[i] = part
  if i < n then return "partial" end
  local s = table.concat(b, "", 1, n)
  buf[name] = nil
  if #s ~= total_len then
    return string.format("error: length %d, expected %d", #s, total_len)
  end
  local ok, meta = pcall(helpers.json_to_table, meta_json)
  if not ok or type(meta) ~= "table" then meta = {} end
  lib()[name] = {string = s, meta = meta, hash = meta.hash}
  geo_cache()[name] = nil
  return "ok"
end

function AIBlueprints.remove(name)
  lib()[name] = nil
  geo_cache()[name] = nil
end

function AIBlueprints.hashes()
  local out = {}
  for name, e in pairs(lib()) do out[name] = e.hash or "" end
  return out
end

function AIBlueprints.list()
  local out = {}
  for name, e in pairs(lib()) do
    out[#out + 1] = {name = name, category = e.meta.category, placement = e.meta.placement}
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- -------------------------------------------------------------------------
-- Temporary blueprint item (script inventory, created and destroyed in the
-- same tick)
-- -------------------------------------------------------------------------

local function with_stack(bp_string, fn)
  local inv = game.create_inventory(1)
  local stack = inv[1]
  -- import_stack: 0 = ok, -1 = imported with errors (still usable), 1 = failed
  local res = stack.import_stack(bp_string)
  local ok, a, b, c
  if res == 1 or not stack.valid_for_read or not stack.is_blueprint then
    ok, a = false, "blueprint string did not import as a single blueprint"
  else
    -- Absolute snapping ties the blueprint to the world grid, so an offset
    -- measured at {0,0} wouldn't hold elsewhere. Placement here is relative.
    pcall(function() stack.blueprint_absolute_snapping = false end)
    ok, a, b, c = pcall(fn, stack)
    if not ok then a = "error: " .. tostring(a) end
  end
  inv.destroy()
  if not ok then return false, a end
  return a, b, c
end

-- -------------------------------------------------------------------------
-- Geometry, measured on the lab surface
-- -------------------------------------------------------------------------

local function get_lab()
  local s = game.surfaces[LAB]
  if s then return s end
  s = game.create_surface(LAB, {
    width = 512, height = 512,
    default_enable_all_autoplace_controls = false,
    autoplace_settings = {
      entity     = {treat_missing_as_default = false, settings = {}},
      tile       = {treat_missing_as_default = false, settings = {}},
      decorative = {treat_missing_as_default = false, settings = {}},
    },
  })
  s.generate_with_lab_tiles = true
  s.always_day = true
  s.request_to_generate_chunks({0, 0}, 8)
  s.force_generate_chunk_requests()
  for _, f in pairs(game.forces) do pcall(function() f.set_surface_hidden(s, true) end) end
  return s
end

-- Entities that can only stand on a specific spot (water edge, oil well) and
-- so can't be ghosted on the lab surface. The first one found becomes the
-- blueprint's anchor: placement lines it up with a real shoreline or well.
local ANCHOR_HALF = {["offshore-pump"] = 1, ["pumpjack"] = 1.5}

local function measure(stack, force)
  local lab = get_lab()
  local ents = stack.get_blueprint_entities() or {}
  if #ents == 0 then return nil, "blueprint has no entities" end
  local by_name = {}
  local anchor, n_pumps, n_jacks = nil, 0, 0
  for _, e in ipairs(ents) do
    by_name[e.name] = by_name[e.name] or {}
    table.insert(by_name[e.name], e)
    if e.name == "offshore-pump" then
      n_pumps = n_pumps + 1
      if not anchor or anchor.name ~= "offshore-pump" then anchor = e end
    elseif e.name == "pumpjack" then
      n_jacks = n_jacks + 1
      anchor = anchor or e
    end
  end

  -- required = ghosts a real placement must produce: everything the lab could
  -- place, every offshore pump, and at least one pumpjack (a multi-well
  -- blueprint rarely lines up with every well).
  local geo = {dirs = {}, required = 0}
  local lab_count = math.huge
  for _, d in ipairs(DIRS) do
    local built = stack.build_blueprint{surface = lab, force = force, position = {0, 0},
                                        direction = d, build_mode = defines.build_mode.forced}
    -- Offset of the blueprint origin: vote over (ghost position - rotated bp position).
    local votes, best, best_n, placed = {}, nil, 0, 0
    local l, t, r, b = math.huge, math.huge, -math.huge, -math.huge
    for _, g in ipairs(built or {}) do
      if g.valid and g.type == "entity-ghost" then
        placed = placed + 1
        for _, e in ipairs(by_name[g.ghost_name] or {}) do
          local rx, ry = rot(d, e.position.x, e.position.y)
          local tx, ty = g.position.x - rx, g.position.y - ry
          local key = string.format("%.1f,%.1f", tx, ty)
          local v = votes[key] or {n = 0, x = tx, y = ty}
          v.n = v.n + 1; votes[key] = v
          if v.n > best_n then best, best_n = v, v.n end
        end
        local bb = g.bounding_box
        l = math.min(l, bb.left_top.x);     t = math.min(t, bb.left_top.y)
        r = math.max(r, bb.right_bottom.x); b = math.max(b, bb.right_bottom.y)
      end
    end
    for _, g in ipairs(built or {}) do if g.valid then g.destroy() end end
    if not best then
      if not anchor then return nil, "nothing in the blueprint could be placed on the lab surface" end
      -- Only anchors (e.g. a lone pumpjack): its bp position is the offset.
      best, best_n, placed, l, t, r, b = {x = 0, y = 0}, 0, 0, 0, 0, 0, 0
    elseif best_n * 2 < placed then
      return nil, "could not work out the blueprint's offset (only " .. best_n .. "/" .. placed .. " ghosts agree)"
    end
    lab_count = math.min(lab_count, placed)
    local g = {tx = best.x, ty = best.y, l = l, t = t, r = r, b = b}
    if anchor then
      local ax, ay = rot(d, anchor.position.x, anchor.position.y)
      local h = ANCHOR_HALF[anchor.name]
      g.anchor = {name = anchor.name, x = best.x + ax, y = best.y + ay,
                  dir = ((anchor.direction or 0) + d) % 16}
      g.l = math.min(g.l, g.anchor.x - h); g.t = math.min(g.t, g.anchor.y - h)
      g.r = math.max(g.r, g.anchor.x + h); g.b = math.max(g.b, g.anchor.y + h)
    end
    geo.dirs[d] = g
  end
  geo.required = lab_count + n_pumps + (n_jacks > 0 and 1 or 0)
  return geo
end

local function get_geometry(name, entry, stack, force)
  local cache = geo_cache()
  if cache[name] and cache[name].required then return cache[name] end
  local geo, err = measure(stack, force)
  if geo then
    cache[name] = geo
    local d = geo.dirs[defines.direction.north]
    AIDebug.event("measure", {name = name, ok = true, required = geo.required,
                              size = d and {w = d.r - d.l, h = d.b - d.t},
                              anchor = d and d.anchor and d.anchor.name})
  end
  return geo, err
end

-- -------------------------------------------------------------------------
-- Spot search
-- -------------------------------------------------------------------------

local function area_at(p, g, margin)
  return {{p.x + g.l - margin, p.y + g.t - margin}, {p.x + g.r + margin, p.y + g.b + margin}}
end

local function generated(surface, a)
  for _, c in ipairs({a[1], a[2], {a[1][1], a[2][2]}, {a[2][1], a[1][2]}}) do
    if not surface.is_chunk_generated({math.floor(c[1] / 32), math.floor(c[2] / 32)}) then
      return false
    end
  end
  return true
end

-- Returns ok, reason (reason names the check that failed, for the debug log).
local function spot_ok(surface, force, p, g, placement, resource, is_tiling)
  local margin = is_tiling and 0 or 1
  local a = area_at(p, g, margin)
  if not generated(surface, a) then return false, "ungenerated" end
  if not is_tiling and surface.count_entities_filtered{area = a, type = NON_BLOCKING, invert = true} > 0 then
    return false, "buildings"
  end
  local water = surface.count_tiles_filtered{area = a, collision_mask = "water_tile"}
  if placement == "near_water" and g.anchor then
    -- Water is fine only right around the offshore pump.
    local ax, ay = p.x + g.anchor.x, p.y + g.anchor.y
    local near = surface.count_tiles_filtered{area = {{ax - 1.5, ay - 1.5}, {ax + 1.5, ay + 1.5}},
                                              collision_mask = "water_tile"}
    if water - near == 0 then return true end
    return false, "water"
  end
  if water > 0 then return false, "water" end
  if placement == "on_ore" then
    local ore = surface.count_entities_filtered{area = a, type = "resource", name = resource}
    -- Oil is a few scattered wells, not a dense patch.
    if resource == "crude-oil" then return ore >= 1, "no_ore" end
    local tiles = (a[2][1] - a[1][1]) * (a[2][2] - a[1][2])
    return ore >= tiles * 0.4, "thin_ore"
  end
  if surface.count_entities_filtered{area = a, type = "resource"} > 0 then return false, "ore" end
  return true
end

-- Candidate origins, nearest to `center` first.
local function spiral(center, max_r, step)
  local out = {{x = math.floor(center.x), y = math.floor(center.y)}}
  for r = step, max_r, step do
    local n = math.max(8, math.floor(r / 2))
    for k = 0, n - 1 do
      local ang = 2 * math.pi * k / n
      out[#out + 1] = {x = math.floor(center.x + r * math.cos(ang)),
                       y = math.floor(center.y + r * math.sin(ang))}
    end
  end
  return out
end

-- (origin, direction) candidates for each placement type.
local function candidates(surface, home, geo, placement, resource, hint)
  local out = {}
  local function add(p, d) if #out < MAX_CANDIDATES then out[#out + 1] = {p = p, d = d} end end

  if hint then
    for _, d in ipairs(DIRS) do add({x = math.floor(hint.x), y = math.floor(hint.y)}, d) end
  end

  if placement == "near_water" then
    local tiles = surface.find_tiles_filtered{position = home, radius = 200,
                                              collision_mask = "water_tile", limit = 4000}
    table.sort(tiles, function(a, b)
      local da = (a.position.x - home.x)^2 + (a.position.y - home.y)^2
      local db = (b.position.x - home.x)^2 + (b.position.y - home.y)^2
      return da < db
    end)
    local seen = {}
    for i = 1, #tiles, 3 do
      local tp = tiles[i].position
      for _, d in ipairs(DIRS) do
        local g = geo.dirs[d]
        if g and g.anchor and g.anchor.name == "offshore-pump" then
          for dx = -1, 1 do for dy = -1, 1 do
            local q = {x = tp.x + 0.5 + dx, y = tp.y + 0.5 + dy}
            if surface.can_place_entity{name = "offshore-pump", position = q, direction = g.anchor.dir} then
              local o = {x = math.floor(q.x - g.anchor.x + 0.5), y = math.floor(q.y - g.anchor.y + 0.5)}
              local key = o.x .. "," .. o.y .. "," .. d
              if not seen[key] then seen[key] = true; add(o, d) end
            end
          end end
        end
      end
      if #out >= MAX_CANDIDATES then break end
    end
  elseif placement == "on_ore" then
    local ores = surface.find_entities_filtered{position = home, radius = 250,
                                                type = "resource", name = resource}
    table.sort(ores, function(a, b)
      local da = (a.position.x - home.x)^2 + (a.position.y - home.y)^2
      local db = (b.position.x - home.x)^2 + (b.position.y - home.y)^2
      return da < db
    end)
    -- Oil wells are sparse: line the blueprint's pumpjack up with each well.
    -- Ore patches are dense: centre the footprint on a sample of ore tiles.
    local oil = resource == "crude-oil"
    for i = 1, #ores, oil and 1 or 7 do
      local op = ores[i].position
      for _, d in ipairs(DIRS) do
        local g = geo.dirs[d]
        if g and oil and g.anchor and g.anchor.name == "pumpjack" then
          add({x = math.floor(op.x - g.anchor.x + 0.5), y = math.floor(op.y - g.anchor.y + 0.5)}, d)
        elseif g and not oil then
          add({x = math.floor(op.x - (g.l + g.r) / 2), y = math.floor(op.y - (g.t + g.b) / 2)}, d)
        end
      end
    end
  else
    for _, p in ipairs(spiral(home, 160, 6)) do add(p, defines.direction.north) end
  end
  return out
end

-- -------------------------------------------------------------------------
-- place(character, name, opts) -> ok, detail
-- -------------------------------------------------------------------------

local function missing_for(ghosts, inv)
  local need = {}
  for _, g in ipairs(ghosts) do
    if g.valid and g.type == "entity-ghost" then
      local proto = prototypes.entity[g.ghost_name]
      local it = proto and proto.items_to_place_this and proto.items_to_place_this[1]
      if it then need[it.name] = (need[it.name] or 0) + (it.count or 1) end
    end
  end
  local parts = {}
  for item, n in pairs(need) do
    local short = n - inv.get_item_count(item)
    if short > 0 then parts[#parts + 1] = short .. "x " .. item end
  end
  table.sort(parts)
  return parts
end

local function log_placed(surface, name, p, d)
  storage.ai_player.placed_blueprints = storage.ai_player.placed_blueprints or {}
  local log = storage.ai_player.placed_blueprints
  log[#log + 1] = {name = name, surface = surface.name, position = {x = p.x, y = p.y},
                   direction = d, tick = game.tick}
  while #log > MAX_PLACED_LOG do table.remove(log, 1) end
end

function AIBlueprints.place(character, name, opts)
  opts = opts or {}
  local entry = lib()[name]
  if not entry then
    local names = {}
    for n in pairs(lib()) do names[#names + 1] = n end
    table.sort(names)
    return false, "place_blueprint: no blueprint named '" .. tostring(name) .. "'. Known: "
      .. (#names > 0 and table.concat(names, ", ") or "(library empty — start the bridge to sync it)")
  end
  local surface = character.surface
  local force = character.force
  local placement = entry.meta.placement or "clear"
  local resource = opts.resource or entry.meta.resource or "iron-ore"
  local home = opts.at or AICharacter.get_home(surface) or character.position

  return with_stack(entry.string, function(stack)
    local geo, err = get_geometry(name, entry, stack, force)
    if not geo then
      AIDebug.event("measure", {name = name, ok = false, error = err})
      return false, "place_blueprint: " .. err
    end

    -- Why spots were turned down, for the debug log and the failure message.
    local rejected, partial = {}, {}
    local cands = candidates(surface, home, geo, placement, resource, opts.position)
    local tries = 0
    local is_tiling = opts.position ~= nil
    for _, c in ipairs(cands) do
      local g = geo.dirs[c.d]
      local fits, why = false, "no_geometry"
      if g then fits, why = spot_ok(surface, force, c.p, g, placement, resource, is_tiling) end
      if not fits then rejected[why or "?"] = (rejected[why or "?"] or 0) + 1 end
      if fits then
        tries = tries + 1
        -- Marks that were already there (e.g. the player's) must survive a rollback.
        local premarked = surface.find_entities_filtered{area = area_at(c.p, g, 1), to_be_deconstructed = true}
        local built = stack.build_blueprint{surface = surface, force = force, position = c.p,
                                            direction = c.d, build_mode = defines.build_mode.forced}
        local n = 0
        for _, e in ipairs(built or {}) do
          if e.valid and e.type == "entity-ghost" then
            n = n + 1
            AIRegistry.register_ghost(e)
          end
        end
        if n >= geo.required then
          log_placed(surface, name, c.p, c.d)
          local need = missing_for(built, character.get_inventory(defines.inventory.character_main))
          local detail = string.format("placed '%s' at {%d,%d}: %d ghost(s) to build", name, c.p.x, c.p.y, n)
          -- A forced build marks trees/rocks in the way; ghosts on them can't be
          -- built until they're cleared.
          local marked = surface.count_entities_filtered{area = area_at(c.p, g, 0), to_be_deconstructed = true}
          local next_step = marked > 0
            and string.format("deconstruct first (%d tree/rock(s) in the way), then build_ghosts", marked)
            or "build_ghosts next"
          if #need > 0 then
            detail = detail .. "; you still need " .. table.concat(need, ", ")
                     .. " (craft_for/gather them), then " .. next_step
          else
            detail = detail .. "; you have everything — " .. next_step
          end
          AIDebug.event("place", {name = name, ok = true, position = c.p, direction = c.d, ghosts = n,
                                  required = geo.required, candidates = #cands, tries = tries,
                                  rejected = rejected, partial = partial, marked = marked})
          return true, detail
        end
        -- Partial fit: undo the ghosts and any tree/rock marks, try the next spot.
        partial[#partial + 1] = n
        for _, e in ipairs(built or {}) do if e.valid then e.destroy() end end
        surface.cancel_deconstruct_area{area = area_at(c.p, g, 1), force = force}
        for _, e in ipairs(premarked) do
          if e.valid then e.order_deconstruction(e.force.name == "neutral" and force or e.force) end
        end
        if tries >= MAX_BUILD_TRIES then break end
      end
    end
    local where = placement == "near_water" and "on a shoreline"
               or placement == "on_ore" and ("on a " .. resource .. " patch")
               or "in a clear area"
    local why = {}
    for k, v in pairs(rejected) do why[#why + 1] = v .. " " .. k end
    table.sort(why)
    AIDebug.event("place", {name = name, ok = false, placement = placement, resource = resource,
                            home = home, candidates = #cands, tries = tries, rejected = rejected,
                            partial = partial, required = geo.required})
    return false, string.format(
      "place_blueprint: no spot found for '%s' %s near home (%d candidate(s), %d build tries%s%s)",
      name, where, #cands, tries,
      #why > 0 and ("; rejected: " .. table.concat(why, ", ")) or "",
      #partial > 0 and ("; best partial " .. math.max(table.unpack(partial)) .. "/" .. geo.required .. " ghosts") or "")
  end)
end

-- Ghosts of the blueprint right next to `player` (no search) — /ai-bp test.
function AIBlueprints.test_place(player, name)
  local entry = lib()[name]
  if not entry then return false, "no blueprint named '" .. tostring(name) .. "'" end
  return with_stack(entry.string, function(stack)
    local pos = player.physical_position
    local built = stack.build_blueprint{surface = player.physical_surface, force = player.force,
                                        position = {x = math.floor(pos.x) + 8, y = math.floor(pos.y)},
                                        build_mode = defines.build_mode.forced}
    return true, string.format("placed %d ghost(s) of '%s' east of you", #(built or {}), name)
  end)
end

-- -------------------------------------------------------------------------
-- In-game export (/ai-bp add): held blueprint or book -> script-output for
-- the bridge to import.
-- -------------------------------------------------------------------------

-- File-safe name: lowercase letters, digits and dashes only (rich text like
-- [item=boiler] dropped), so it can't escape script-output. Same rule as
-- bridge/blueprints.py safe_name. nil if nothing usable is left.
function AIBlueprints.safe_name(s)
  if type(s) ~= "string" then return nil end
  local n = s:lower():gsub("%[[^%]]*%]", ""):gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  n = n:sub(1, 48)
  if n == "" then return nil end
  return n
end

function AIBlueprints.export_held(player, name, category)
  local str, label
  local rec = player.cursor_record
  if rec and rec.valid then
    if rec.type ~= "blueprint" and rec.type ~= "blueprint-book" then
      return false, "hold a blueprint or blueprint book (not a planner)"
    end
    str, label = rec.export_record(), rec.label
  else
    local st = player.cursor_stack
    if not (st and st.valid_for_read and (st.is_blueprint or st.is_blueprint_book)) then
      return false, "hold a blueprint or blueprint book first"
    end
    str, label = st.export_stack(), st.label
  end
  if not str or str == "" then return false, "could not export the held blueprint" end
  name = AIBlueprints.safe_name(name or label) or ("bp-" .. game.tick)
  local body = helpers.table_to_json({name = name, string = str, category = category})
  helpers.write_file("ai-player/blueprints/" .. name .. ".json", body, false, 0)
  return true, name
end

return AIBlueprints
