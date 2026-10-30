-- Layout engine: where to put a drill, which way it faces, and where its
-- collector goes, worked out BEFORE anything is placed.
--
--   AILayout.find_drill_spots(character, resource, center, opts) -> plans
--   AILayout.find_drill_row(character, resource, center, opts)   -> plan
--   AILayout.build(character, plan) -> ok, detail   (verifies, rolls back on failure)
--
-- A plan is a list of {name, position, direction} placements plus checks to
-- run after building. Placement goes through the place primitive, so the
-- usual legality rules and AI ownership (last_user nil) still apply.

AILayout = {}

local DIRS = {north = defines.direction.north, east = defines.direction.east,
              south = defines.direction.south, west = defines.direction.west}
local DIR_NAME = {}
for name, d in pairs(DIRS) do DIR_NAME[d] = name end
local OPPOSITE = {north = "south", south = "north", east = "west", west = "east"}
-- Unit step "forward" for each facing (y grows southward).
local FORWARD = {north = {0, -1}, south = {0, 1}, east = {1, 0}, west = {-1, 0}}

local function vec(v)
  if not v then return 0, 0 end
  return v.x or v[1] or 0, v.y or v[2] or 0
end

-- Rotate a vector given for "north" to the facing (clockwise quarter turns).
local function rotate(x, y, facing)
  if facing == "east" then return -y, x end
  if facing == "south" then return -x, -y end
  if facing == "west" then return y, -x end
  return x, y
end

local function footprint(name)
  local p = prototypes.entity[name]
  return p and p.tile_width or 1, p and p.tile_height or 1
end

local function box(cx, cy, w, h)
  return {cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2}
end

local function overlaps(a, b)
  return a[1] < b[3] - 0.01 and b[1] < a[3] - 0.01 and a[2] < b[4] - 0.01 and b[2] < a[4] - 0.01
end

local function free(boxes, b)
  for _, o in ipairs(boxes) do
    if overlaps(o, b) then return false end
  end
  return true
end

local function can_place(character, name, x, y, facing)
  return character.surface.can_place_entity{name = name, position = {x, y},
    direction = DIRS[facing or "north"], force = character.force,
    build_check_type = defines.build_check_type.manual}
end

-- Where a drill facing `facing` at (x, y) drops its output.
function AILayout.drop_point(drill_name, x, y, facing)
  local vx, vy = vec(prototypes.entity[drill_name].vector_to_place_result)
  local dx, dy = rotate(vx, vy, facing)
  return x + dx, y + dy
end

-- Centre for an entity of size w×h that covers point (px, py) but stays out
-- of `avoid` (the drill's own box): nearest legal grid position first.
local function collector_spot(px, py, w, h, avoid)
  local function axis(p, size)
    local out = {}
    local half = size / 2
    local start = size % 2 == 0 and math.ceil(p - half) or math.floor(p - half) + 0.5
    for c = start, p + half, 1 do
      if c - half <= p and p <= c + half then out[#out + 1] = c end
    end
    return out
  end
  local best, bd
  for _, cx in ipairs(axis(px, w)) do
    for _, cy in ipairs(axis(py, h)) do
      local b = box(cx, cy, w, h)
      if not overlaps(b, avoid) then
        local d = (cx - px) ^ 2 + (cy - py) ^ 2
        if not bd or d < bd then best, bd = {cx, cy}, d end
      end
    end
  end
  return best
end

-- Where to put `name` so an already-built drill drops into it.
function AILayout.collector_position(drill, name)
  local w, h = footprint(drill.name)
  local cw, ch = footprint(name)
  local dp = drill.drop_position
  local spot = collector_spot(dp.x, dp.y, cw, ch, box(drill.position.x, drill.position.y, w, h))
  return spot and {x = spot[1], y = spot[2]} or nil
end

-- Share of a drill's mining area that is the wanted ore (0..1).
local function coverage(surface, drill_name, x, y, resource)
  local r = prototypes.entity[drill_name].mining_drill_radius or 0.99
  local n = surface.count_entities_filtered{area = {{x - r, y - r}, {x + r, y + r}},
                                            type = "resource", name = resource}
  local tiles = math.max(1, math.floor((2 * r + 0.02) ^ 2 + 0.5))
  return n / tiles
end

-- Drill centres to try: one per ore tile near `center`, snapped to the drill's
-- grid, nearest first.
local function candidates(surface, drill_name, resource, center, radius)
  local w = footprint(drill_name)
  local seen, out = {}, {}
  for _, ore in ipairs(surface.find_entities_filtered{name = resource, type = "resource",
                                                      position = center, radius = radius}) do
    local x, y = ore.position.x, ore.position.y
    if w % 2 == 0 then x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    else x, y = math.floor(x) + 0.5, math.floor(y) + 0.5 end
    local k = x .. "," .. y
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = {x = x, y = y, d = (x - center.x) ^ 2 + (y - center.y) ^ 2}
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  return out
end

-- Up to opts.count drill + collector pairs on `resource`.
--   opts: drill (default burner-mining-drill), collector (item to place at the
--   drop), count, radius (64), min_cover (0.75)
function AILayout.find_drill_spots(character, resource, center, opts)
  local surface = character.surface
  local drill = opts.drill or "burner-mining-drill"
  local dw, dh = footprint(drill)
  local cw, ch = footprint(opts.collector)
  local want = opts.count or 1
  local boxes, plans = {}, {}
  local cands = candidates(surface, drill, resource, center, opts.radius or 64)
  local tried = 0
  for _, c in ipairs(cands) do
    if #plans >= want or tried > 400 then break end
    tried = tried + 1
    local dbox = box(c.x, c.y, dw, dh)
    if free(boxes, dbox) and coverage(surface, drill, c.x, c.y, resource) >= (opts.min_cover or 0.75) then
      for _, facing in ipairs({"south", "east", "north", "west"}) do
        if can_place(character, drill, c.x, c.y, facing) then
          local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
          local spot = collector_spot(px, py, cw, ch, dbox)
          if spot then
            local cbox = box(spot[1], spot[2], cw, ch)
            if free(boxes, cbox) and can_place(character, opts.collector, spot[1], spot[2]) then
              boxes[#boxes + 1] = dbox
              boxes[#boxes + 1] = cbox
              plans[#plans + 1] = {
                facing = facing,
                place = {
                  {name = drill, position = {x = c.x, y = c.y}, direction = facing, role = "drill"},
                  {name = opts.collector, position = {x = spot[1], y = spot[2]}, role = "collector"},
                },
              }
              break
            end
          end
        end
      end
    end
  end
  return plans
end

-- A row of `count` drills all facing one way, dropping onto one belt that
-- runs past the row's end into a burner inserter and a chest.
function AILayout.find_drill_row(character, resource, center, opts)
  local surface = character.surface
  local drill = opts.drill or "burner-mining-drill"
  local dw = footprint(drill)
  local n = opts.count or 2
  local chest = opts.chest or "wooden-chest"
  local tried = 0
  for _, c in ipairs(candidates(surface, drill, resource, center, opts.radius or 64)) do
    tried = tried + 1
    if tried > 150 then break end      -- 4 facings x N drills each: keep one tick cheap
    for _, facing in ipairs({"south", "north", "east", "west"}) do
      -- Row runs sideways to the facing; the belt flows along the row.
      local fx, fy = FORWARD[facing][1], FORWARD[facing][2]
      local ax, ay = math.abs(fy), math.abs(fx)          -- row axis (east or south)
      local flow = ax == 1 and "east" or "south"
      local ok, place, boxes = true, {}, {}
      for i = 0, n - 1 do
        local x, y = c.x + ax * dw * i, c.y + ay * dw * i
        if coverage(surface, drill, x, y, resource) < (opts.min_cover or 0.5)
           or not can_place(character, drill, x, y, facing) then ok = false; break end
        place[#place + 1] = {name = drill, position = {x = x, y = y}, direction = facing, role = "drill"}
        boxes[#boxes + 1] = box(x, y, dw, dw)
      end
      if ok then
        -- Belt tiles: from the first drill's drop tile along the row to one tile
        -- past the last drill's edge, then the inserter, then the chest.
        local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
        local bx, by = math.floor(px) + 0.5, math.floor(py) + 0.5
        local last_x = c.x + ax * dw * (n - 1) + ax * dw / 2
        local last_y = c.y + ay * dw * (n - 1) + ay * dw / 2
        local tiles = 0
        local tx, ty = bx, by
        while (ax == 1 and tx < last_x + 1) or (ay == 1 and ty < last_y + 1) do
          if not can_place(character, "transport-belt", tx, ty, flow) then ok = false; break end
          place[#place + 1] = {name = "transport-belt", position = {x = tx, y = ty}, direction = flow, role = "belt"}
          tiles = tiles + 1
          tx, ty = tx + ax, ty + ay
          if tiles > 2 * n * dw + 4 then ok = false; break end
        end
        if ok then
          local ix, iy = tx, ty
          local cx, cy = tx + ax, ty + ay
          if can_place(character, "burner-inserter", ix, iy, flow) and can_place(character, chest, cx, cy) then
            place[#place + 1] = {name = "burner-inserter", position = {x = ix, y = iy}, direction = flow,
                                 role = "inserter", from = {x = ix - ax, y = iy - ay}, to = {x = cx, y = cy}}
            place[#place + 1] = {name = chest, position = {x = cx, y = cy}, role = "chest"}
            return {facing = facing, flow = flow, place = place}
          end
        end
      end
    end
  end
  return nil
end

-- Items a plan uses, by name.
function AILayout.items(plans)
  local need = {}
  for _, plan in ipairs(plans) do
    for _, p in ipairs(plan.place) do
      local proto = prototypes.entity[p.name]
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
      local iname = item and (item.name or item) or p.name
      need[iname] = (need[iname] or 0) + 1
    end
  end
  return need
end

local function undo(character, placed)
  local inv = character.get_inventory(defines.inventory.character_main)
  for i = #placed, 1, -1 do
    local e = placed[i]
    if e.valid then
      local name, surface, pos = e.name, e.surface, e.position
      e.destroy{raise_destroy = true}       -- keeps the machine registry in step
      if inv.insert{name = name, count = 1} == 0 then
        surface.spill_item_stack{position = pos, stack = {name = name, count = 1}}
      end
    end
  end
end

local function find_placed(surface, p)
  return surface.find_entities_filtered{name = p.name, position = p.position, radius = 0.6, limit = 1}[1]
end

-- Place a plan, check that every drill feeds what it should, roll it all back
-- if anything is off. Returns ok, detail.
function AILayout.build(character, plan)
  local surface = character.surface
  -- The AI standing in the footprint would block its own placement.
  local first = plan.place[1].position
  local away = surface.find_non_colliding_position("character", {first.x + 6, first.y + 6}, 10, 1)
  if away then character.teleport(away) end

  local placed = {}
  for _, p in ipairs(plan.place) do
    local ok, detail = AIActions.run(character, {action = "place", item = p.name,
                                                 position = p.position, direction = p.direction})
    local e = ok and find_placed(surface, p)
    if not e then
      undo(character, placed)
      return false, "layout: " .. (detail or ("couldn't place " .. p.name))
    end
    p.entity = e
    placed[#placed + 1] = e
  end

  for _, p in ipairs(plan.place) do
    local e = p.entity
    if p.role == "drill" and not e.drop_target then
      -- A belt under the drop point counts as a target only if one is there.
      local dp = e.drop_position
      if surface.count_entities_filtered{type = "transport-belt", position = dp, radius = 0.5} == 0 then
        undo(character, placed)
        return false, string.format("layout: drill at {%d,%d} would drop onto the ground — rolled back",
                                    math.floor(e.position.x), math.floor(e.position.y))
      end
    elseif p.role == "inserter" then
      -- Which side an inserter picks from is easy to get backwards; check and flip.
      local function right()
        local pt, dt = e.pickup_position, e.drop_position
        return math.abs(pt.x - p.from.x) < 0.6 and math.abs(pt.y - p.from.y) < 0.6
           and math.abs(dt.x - p.to.x) < 0.8 and math.abs(dt.y - p.to.y) < 0.8
      end
      if not right() then
        e.direction = DIRS[OPPOSITE[p.direction]]
        if not right() then
          undo(character, placed)
          return false, "layout: inserter couldn't be turned to move belt → chest — rolled back"
        end
      end
    end
  end

  -- Fuel what burns.
  local inv = character.get_inventory(defines.inventory.character_main)
  for _, p in ipairs(plan.place) do
    local fb = p.entity.valid and p.entity.get_fuel_inventory and p.entity.get_fuel_inventory()
    if fb and inv.get_item_count("coal") > 0 then
      local ins = fb.insert{name = "coal", count = math.min(p.role == "drill" and 10 or 5, inv.get_item_count("coal"))}
      if ins > 0 then inv.remove{name = "coal", count = ins} end
    end
  end
  return true, plan.place
end

AILayout.DIR_NAME = DIR_NAME
return AILayout
