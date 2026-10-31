-- Layout engine: where to put a drill, which way it faces, and where its
-- collector goes, worked out BEFORE anything is placed.
--
--   AILayout.find_drill_spots(character, resource, center, opts) -> plans
--   AILayout.find_drill_row(character, resource, center, opts)   -> plan
--   AILayout.find_power(character, near, home) -> plan   (offshore pump -> boiler -> 2 engines -> poles)
--   AILayout.pole_chain(character, from, goal, boxes) -> poles, joined
--   AILayout.find_assembler_unit(character, recipe, home, claimed, chest) -> plan
--   AILayout.find_electric_pair(character, resource, center, opts) -> plan   (drill -> furnace -> inserter -> chest)
--   AILayout.find_red_cell(character, home, chest, labs) -> plan
--   AILayout.find_consumer_poles(character, entity) -> plan   (poles wiring an unpowered lab/assembler to a live pole)
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

-- Facings to try, in order. The self-test sets only_facing to pin one.
AILayout.only_facing = nil
local function facings(order)
  if AILayout.only_facing then return {AILayout.only_facing} end
  return order
end

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
      for _, facing in ipairs(facings({"south", "east", "north", "west"})) do
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
    for _, facing in ipairs(facings({"south", "north", "east", "west"})) do
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

-- ---------------------------------------------------------------------------
-- Steam power: offshore pump -> boiler -> 2 steam engines in a line, then poles.
--
-- Every offset comes from the prototypes' pipe connections, rotated by hand
-- (get_fluid_box_pipe_connections only works on placed entities). For an
-- orientation r (0..3 = north, east, south, west) a connection sits on the
-- entity's own edge tile at positions[r+1], facing (direction + 4r); the tile
-- it joins is that tile plus one step in that direction.
-- ---------------------------------------------------------------------------
local ORIENT = {[0] = "north", "east", "south", "west"}
local function unit16(dir)
  local d = dir % 16
  if d == 0 then return 0, -1 elseif d == 4 then return 1, 0 elseif d == 8 then return 0, 1 end
  return -1, 0
end

local function pipe_conns(name, r)
  local out = {}
  for i, fb in ipairs(prototypes.entity[name].fluidbox_prototypes) do
    for _, pc in ipairs(fb.pipe_connections) do
      local pos = pc.positions and pc.positions[r + 1] or pc.position
      out[#out + 1] = {x = pos.x or pos[1], y = pos.y or pos[2], dir = (pc.direction + 4 * r) % 16, fb = i}
    end
  end
  return out
end

-- Footprint of `name` turned to orientation r (odd r swaps width and height).
local function oriented_box(name, cx, cy, r)
  local w, h = footprint(name)
  if r % 2 == 1 then w, h = h, w end
  return box(cx, cy, w, h)
end

local function dist2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end

-- Poles from `from` toward `goal`, one every ~6 tiles, until an existing pole
-- of the AI's force is within wire reach (that network is the grid). `boxes`
-- are footprints already claimed by the plan. Returns poles, joined (nil when
-- the chain gets too long or is blocked).
function AILayout.pole_chain(character, from, goal, boxes, opts)
  opts = opts or {}
  local surface, force = character.surface, character.force
  local reach = prototypes.entity["small-electric-pole"].get_max_wire_distance()
  local step = reach - 1.5
  local poles = {}
  local cur = {x = from.x, y = from.y}
  for _ = 1, opts.max or 16 do
    local near = surface.find_entities_filtered{type = "electric-pole", position = cur, radius = reach, force = force}
    if #near > 0 then return poles, true end
    local dx, dy = goal.x - cur.x, goal.y - cur.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 2 then return poles, false end
    local t = math.min(step, d) / d
    local tx, ty = math.floor(cur.x + dx * t) + 0.5, math.floor(cur.y + dy * t) + 0.5
    local best
    for ox = -1, 1 do
      for oy = -1, 1 do
        local x, y = tx + ox, ty + oy
        if dist2(x, y, cur.x, cur.y) <= (reach - 0.3) ^ 2 and free(boxes, box(x, y, 1, 1))
           and can_place(character, "small-electric-pole", x, y) then
          local score = dist2(x, y, goal.x, goal.y)
          if not best or score < best.score then best = {x = x, y = y, score = score} end
        end
      end
    end
    if not best then return nil end
    poles[#poles + 1] = {name = "small-electric-pole", position = {x = best.x, y = best.y}, role = "pole"}
    boxes[#boxes + 1] = box(best.x, best.y, 1, 1)
    cur = {x = best.x, y = best.y}
  end
  return nil
end

local function all_free(boxes)
  for i = 1, #boxes do
    for j = i + 1, #boxes do
      if overlaps(boxes[i], boxes[j]) then return false end
    end
  end
  return true
end

-- Pump, boiler and engines for one shoreline pose: the pump on land tile (px, py)
-- with the water on the side it faces (orientation r). Returns plan pieces or nil.
local function power_pose(character, px, py, r)
  local pump_out = pipe_conns("offshore-pump", r)[1]
  local ux, uy = unit16(pump_out.dir)
  local tx, ty = px + ux, py + uy                   -- tile the boiler's water port must sit on
  local want = (pump_out.dir + 8) % 16              -- ...facing back at the pump
  for rb = 0, 3 do
    local conns = pipe_conns("boiler", rb)
    local steam
    for _, c in ipairs(conns) do if c.fb == 2 then steam = c end end
    for _, c in ipairs(conns) do
      if c.fb == 1 and c.dir == want then
        local bx, by = tx - c.x, ty - c.y
        if can_place(character, "boiler", bx, by, ORIENT[rb]) then
          -- Steam leaves the boiler; the engines continue in a line from there.
          local sx, sy = unit16(steam.dir)
          local stx, sty = bx + steam.x + sx, by + steam.y + sy
          local back = (steam.dir + 8) % 16
          for re = 0, 3 do
            local inlet, outlet
            for _, e in ipairs(pipe_conns("steam-engine", re)) do
              if e.dir == back then inlet = e else outlet = e end
            end
            if inlet and outlet then
              local ex, ey = stx - inlet.x, sty - inlet.y
              local ox, oy = unit16(outlet.dir)
              -- The second engine's inlet sits on the first one's outlet target tile.
              local e2x, e2y = ex + outlet.x + ox - inlet.x, ey + outlet.y + oy - inlet.y
              local boxes = {box(px, py, 1, 1), oriented_box("boiler", bx, by, rb),
                             oriented_box("steam-engine", ex, ey, re), oriented_box("steam-engine", e2x, e2y, re)}
              if all_free(boxes)
                 and can_place(character, "steam-engine", ex, ey, ORIENT[re])
                 and can_place(character, "steam-engine", e2x, e2y, ORIENT[re]) then
                return {
                  place = {
                    {name = "offshore-pump", position = {x = px, y = py}, direction = ORIENT[r], role = "pump"},
                    {name = "boiler", position = {x = bx, y = by}, direction = ORIENT[rb], role = "boiler"},
                    {name = "steam-engine", position = {x = ex, y = ey}, direction = ORIENT[re], role = "engine"},
                    {name = "steam-engine", position = {x = e2x, y = e2y}, direction = ORIENT[re], role = "engine"},
                  },
                  boxes = boxes, engine_box = boxes[3],
                }
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- A steam block on the shore nearest `near` (the AI), with poles back toward `home`.
function AILayout.find_power(character, near, home)
  local surface = character.surface
  home = home or near
  local tiles = surface.find_tiles_filtered{collision_mask = "water_tile", position = near, radius = 40}
  table.sort(tiles, function(a, b)
    return dist2(a.position.x, a.position.y, near.x, near.y) < dist2(b.position.x, b.position.y, near.x, near.y)
  end)
  local tried = 0
  for _, t in ipairs(tiles) do
    for r = 0, 3 do
      -- Pump orientation r has the water on its r-facing side.
      local wx, wy = unit16(r * 4)
      local px, py = t.position.x + 0.5 - wx, t.position.y + 0.5 - wy
      local sp = surface.get_tile(px, py)
      if sp and not sp.collides_with("water_tile") then
        tried = tried + 1
        if tried > 300 then return nil end
        if can_place(character, "offshore-pump", px, py, ORIENT[r]) then
          local plan = power_pose(character, px, py, r)
          if plan then
            -- First pole beside the engines (its supply square must touch one),
            -- then the chain home.
            local boxes, eb = plan.boxes, plan.engine_box
            local cx, cy = (eb[1] + eb[3]) / 2, (eb[2] + eb[4]) / 2
            local first
            for ox = -4, 4 do
              for oy = -4, 4 do
                local x, y = math.floor(cx) + 0.5 + ox, math.floor(cy) + 0.5 + oy
                if overlaps(box(x, y, 5, 5), eb) and free(boxes, box(x, y, 1, 1))
                   and can_place(character, "small-electric-pole", x, y) then
                  local d = dist2(x, y, home.x, home.y)
                  if not first or d < first.d then first = {x = x, y = y, d = d} end
                end
              end
            end
            if first then
              local claimed = {table.unpack(boxes)}
              claimed[#claimed + 1] = box(first.x, first.y, 1, 1)
              local poles, joined = AILayout.pole_chain(character, first, home, claimed)
              if poles then
                local out = plan.place
                out[#out + 1] = {name = "small-electric-pole", position = {x = first.x, y = first.y}, role = "pole"}
                for _, pole in ipairs(poles) do out[#out + 1] = pole end
                return {place = out, joined = joined, facing = ORIENT[r]}
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Assembler cells. A cell is a fixed pattern of entities in tile offsets from an
-- anchor tile; find_stamp tries anchors in rings around home until every piece
-- is placeable and clear of the others, then wires the cell's poles to the
-- nearest existing pole (pole_chain).
--
-- spec fields: name, tx, ty (tile offset of the entity's centre tile), role,
-- direction, recipe, from/to ({tx, ty} tiles an inserter picks from / drops to).
-- ---------------------------------------------------------------------------

local function stamp(character, specs, ox, oy, claimed)
  local place, mine = {}, {}
  for _, sp in ipairs(specs) do
    local x, y = ox + sp.tx + 0.5, oy + sp.ty + 0.5
    local w, h = footprint(sp.name)
    local b = box(x, y, w, h)
    if not free(claimed, b) or not free(mine, b) or not can_place(character, sp.name, x, y, sp.direction) then
      return nil
    end
    mine[#mine + 1] = b
    local e = {name = sp.name, position = {x = x, y = y}, direction = sp.direction, role = sp.role,
               recipe = sp.recipe}
    if sp.from then
      e.from = {x = ox + sp.from[1] + 0.5, y = oy + sp.from[2] + 0.5}
      e.to = {x = ox + sp.to[1] + 0.5, y = oy + sp.to[2] + 0.5}
    end
    place[#place + 1] = e
  end
  return place, mine
end

-- Nearest pole of the AI's force to `pos`, if any.
function AILayout.nearest_pole(character, pos)
  local best, bd
  for _, e in ipairs(character.surface.find_entities_filtered{type = "electric-pole", force = character.force,
                                                              position = pos, radius = 250}) do
    local d = dist2(e.position.x, e.position.y, pos.x, pos.y)
    if not bd or d < bd then best, bd = e, d end
  end
  return best
end

-- Where `specs` fit near `home`; returns {place = ..., joined = bool, boxes = ...} or nil.
-- `claimed` are footprints that must stay clear (cells placed earlier this call).
local function find_stamp(character, specs, home, claimed, start_r)
  local hx, hy = math.floor(home.x), math.floor(home.y)
  local grid = AILayout.nearest_pole(character, home)
  for r = start_r or 8, 56, 4 do
    for k = 0, 11 do
      local a = k * math.pi / 6
      local ox, oy = hx + math.floor(r * math.cos(a)), hy + math.floor(r * math.sin(a))
      local place, mine = stamp(character, specs, ox, oy, claimed)
      if place then
        -- Poles of the cell, then a chain from the one nearest the grid.
        local joined = false
        if grid then
          local from
          for _, p in ipairs(place) do
            if p.role == "pole" then
              local d = dist2(p.position.x, p.position.y, grid.position.x, grid.position.y)
              if not from or d < from.d then from = {x = p.position.x, y = p.position.y, d = d} end
            end
          end
          local all = {}
          for _, b in ipairs(claimed) do all[#all + 1] = b end
          for _, b in ipairs(mine) do all[#all + 1] = b end
          local poles, j = AILayout.pole_chain(character, from, grid.position, all)
          if poles then
            for _, pole in ipairs(poles) do place[#place + 1] = pole end
            joined = j
          else
            place = nil
          end
        end
        if place then return {place = place, boxes = mine, joined = joined, grid = grid ~= nil, anchor = {x = ox, y = oy}} end
      end
    end
  end
  return nil
end

-- One assembler with an input chest and an output chest:
--   chest -> inserter -> assembler -> inserter -> chest, poles under the inserters.
function AILayout.find_assembler_unit(character, recipe, home, claimed, chest, start_r)
  local specs = {
    {name = chest, tx = 0, ty = 1, role = "chest"},
    {name = "inserter", tx = 1, ty = 1, direction = "east", role = "inserter", from = {0, 1}, to = {2, 1}},
    {name = "assembling-machine-1", tx = 3, ty = 1, role = "assembler", recipe = recipe},
    {name = "inserter", tx = 5, ty = 1, direction = "east", role = "inserter", from = {4, 1}, to = {6, 1}},
    {name = chest, tx = 6, ty = 1, role = "chest"},
    {name = "small-electric-pole", tx = 1, ty = 2, role = "pole"},
    {name = "small-electric-pole", tx = 5, ty = 2, role = "pole"},
  }
  return find_stamp(character, specs, home, claimed or {}, start_r)
end

-- Red science: one gear assembler between two science assemblers.
--   copper chest -> SCI1 <- GEAR -> SCI2 <- copper chest, iron chest above GEAR,
--   each science assembler dropping into a lab (or a chest when no lab is left).
function AILayout.find_red_cell(character, home, chest, labs)
  local sci, gear = "automation-science-pack", "iron-gear-wheel"
  local asm = "assembling-machine-1"
  local specs = {
    {name = asm, tx = 0, ty = 0, role = "assembler", recipe = sci},
    {name = asm, tx = 4, ty = 0, role = "assembler", recipe = gear},
    {name = asm, tx = 8, ty = 0, role = "assembler", recipe = sci},
    {name = "inserter", tx = 2, ty = 0, direction = "west", role = "inserter", from = {3, 0}, to = {1, 0}},
    {name = "inserter", tx = 6, ty = 0, direction = "east", role = "inserter", from = {5, 0}, to = {7, 0}},
    {name = chest, tx = -3, ty = 0, role = "chest"},
    {name = "inserter", tx = -2, ty = 0, direction = "east", role = "inserter", from = {-3, 0}, to = {-1, 0}},
    {name = chest, tx = 11, ty = 0, role = "chest"},
    {name = "inserter", tx = 10, ty = 0, direction = "west", role = "inserter", from = {11, 0}, to = {9, 0}},
    {name = chest, tx = 4, ty = -3, role = "chest"},
    {name = "inserter", tx = 4, ty = -2, direction = "south", role = "inserter", from = {4, -3}, to = {4, -1}},
    {name = "inserter", tx = 0, ty = 2, direction = "south", role = "inserter", from = {0, 1}, to = {0, 3}},
    {name = "inserter", tx = 8, ty = 2, direction = "south", role = "inserter", from = {8, 1}, to = {8, 3}},
    {name = "small-electric-pole", tx = 2, ty = 2, role = "pole"},
    {name = "small-electric-pole", tx = 6, ty = 2, role = "pole"},
    {name = "small-electric-pole", tx = -2, ty = 2, role = "pole"},
    {name = "small-electric-pole", tx = 10, ty = 2, role = "pole"},
    {name = "small-electric-pole", tx = 2, ty = -2, role = "pole"},
  }
  if labs >= 1 then
    specs[#specs + 1] = {name = "lab", tx = 0, ty = 4, role = "lab"}
  else
    specs[#specs + 1] = {name = chest, tx = 0, ty = 3, role = "chest"}
  end
  if labs >= 2 then
    specs[#specs + 1] = {name = "lab", tx = 8, ty = 4, role = "lab"}
  else
    specs[#specs + 1] = {name = chest, tx = 8, ty = 3, role = "chest"}
  end
  return find_stamp(character, specs, home, {})
end

-- One electric drill -> stone furnace -> inserter -> chest, with a pole beside the
-- furnace wired to the nearest grid pole. Laid out in the "facing south" frame
-- and rotated: the furnace sits where the drill drops, the inserter and chest
-- continue away from the drill, the pole is on the furnace's side.
function AILayout.find_electric_pair(character, resource, center, opts)
  local surface = character.surface
  local drill = "electric-mining-drill"
  local chest = opts.chest or "wooden-chest"
  local dw, dh = footprint(drill)
  local fw, fh = footprint("stone-furnace")
  local tried = 0
  for _, c in ipairs(candidates(surface, drill, resource, center, opts.radius or 64)) do
    tried = tried + 1
    if tried > 200 then break end
    local dbox = box(c.x, c.y, dw, dh)
    if coverage(surface, drill, c.x, c.y, resource) >= (opts.min_cover or 0.6) then
      for _, facing in ipairs(facings({"south", "east", "north", "west"})) do
        if can_place(character, drill, c.x, c.y, facing) then
          local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
          local spot = collector_spot(px, py, fw, fh, dbox)
          if spot then
            local fx, fy = spot[1], spot[2]
            local function at(ox, oy)
              local rx, ry = rotate(ox, oy, "south")
              rx, ry = rotate(rx, ry, facing)
              return fx + rx, fy + ry
            end
            local ix, iy = at(-0.5, 1.5)
            local kx, ky = at(-0.5, 2.5)
            local qx, qy = at(1.5, -0.5)
            local bx, by = at(-0.5, 0.5)            -- furnace tile the inserter picks from
            local parts = {dbox, box(fx, fy, fw, fh), box(ix, iy, 1, 1), box(kx, ky, 1, 1), box(qx, qy, 1, 1)}
            local ok = true
            for i = 1, #parts do
              for j = i + 1, #parts do if overlaps(parts[i], parts[j]) then ok = false end end
            end
            if ok and can_place(character, "stone-furnace", fx, fy) and can_place(character, "inserter", ix, iy, facing)
               and can_place(character, chest, kx, ky) and can_place(character, "small-electric-pole", qx, qy) then
              local grid = AILayout.nearest_pole(character, {x = qx, y = qy})
              if grid then
                local poles, joined = AILayout.pole_chain(character, {x = qx, y = qy}, grid.position, parts)
                if poles then
                  local place = {
                    {name = drill, position = {x = c.x, y = c.y}, direction = facing, role = "drill"},
                    {name = "stone-furnace", position = {x = fx, y = fy}, role = "collector"},
                    {name = "inserter", position = {x = ix, y = iy}, direction = facing, role = "inserter",
                     from = {x = bx, y = by}, to = {x = kx, y = ky}},
                    {name = chest, position = {x = kx, y = ky}, role = "chest"},
                    {name = "small-electric-pole", position = {x = qx, y = qy}, role = "pole"},
                  }
                  for _, pole in ipairs(poles) do place[#place + 1] = pole end
                  return {facing = facing, place = place, joined = joined}
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

-- Poles that wire an unpowered consumer (a lab placed before the grid reached it, ...):
-- one beside the machine, then a chain to the nearest pole on a network with a
-- generator. Returns a plan {place = poles}, or nil when a pole already covers the
-- machine or no chain fits.
function AILayout.find_consumer_poles(character, e)
  local surface, force = character.surface, character.force
  local ex, ey = e.position.x, e.position.y
  local w, h = footprint(e.name)
  if #surface.find_entities_filtered{type = "electric-pole", force = force, position = e.position,
                                     radius = math.max(w, h) / 2 + 2.5} > 0 then
    return nil                      -- a pole's supply area already reaches it
  end
  local live = {}
  for _, g in ipairs(surface.find_entities_filtered{type = {"generator", "electric-energy-interface"}, force = force}) do
    if g.electric_network_id then live[g.electric_network_id] = true end
  end
  local goal, gd
  for _, pole in ipairs(surface.find_entities_filtered{type = "electric-pole", force = force, position = e.position,
                                                       radius = 250}) do
    if next(live) == nil or live[pole.electric_network_id] then
      local d = dist2(pole.position.x, pole.position.y, ex, ey)
      if not gd or d < gd then goal, gd = pole, d end
    end
  end
  if not goal then return nil end
  local own = box(ex, ey, w, h)
  local spots = {}
  for k = -math.floor(h / 2), math.floor(h / 2) do
    spots[#spots + 1] = {ex - w / 2 - 0.5, ey + k}
    spots[#spots + 1] = {ex + w / 2 + 0.5, ey + k}
  end
  for k = -math.floor(w / 2), math.floor(w / 2) do
    spots[#spots + 1] = {ex + k, ey - h / 2 - 0.5}
    spots[#spots + 1] = {ex + k, ey + h / 2 + 0.5}
  end
  table.sort(spots, function(a, b)
    return dist2(a[1], a[2], goal.position.x, goal.position.y) < dist2(b[1], b[2], goal.position.x, goal.position.y)
  end)
  for _, sp in ipairs(spots) do
    local x, y = math.floor(sp[1]) + 0.5, math.floor(sp[2]) + 0.5
    if can_place(character, "small-electric-pole", x, y) then
      local boxes = {own, box(x, y, 1, 1)}
      local poles, joined = AILayout.pole_chain(character, {x = x, y = y}, goal.position, boxes)
      if poles and joined then
        local place = {{name = "small-electric-pole", position = {x = x, y = y}, role = "pole"}}
        for _, pole in ipairs(poles) do place[#place + 1] = pole end
        return {place = place}
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
  -- Somewhere on land at least 4 tiles from every piece (water-side pieces
  -- such as pumps have collision boxes that reach into the lake).
  local cx, cy, n = 0, 0, #plan.place
  for _, p in ipairs(plan.place) do cx, cy = cx + p.position.x / n, cy + p.position.y / n end
  local away
  for radius = 6, 30, 6 do
    for k = 0, 7 do
      local a = k * math.pi / 4
      local spot = surface.find_non_colliding_position("character",
        {x = cx + radius * math.cos(a), y = cy + radius * math.sin(a)}, 3, 0.5)
      if spot then
        local clear = true
        for _, p in ipairs(plan.place) do
          if dist2(spot.x, spot.y, p.position.x, p.position.y) < 16 then clear = false; break end
        end
        if clear then away = spot; break end
      end
    end
    if away then break end
  end
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
    if p.recipe then
      local rok, rerr = pcall(e.set_recipe, p.recipe)
      local r = rok and e.get_recipe()
      if not (r and r.name == p.recipe) then
        undo(character, placed)
        return false, "layout: couldn't set recipe " .. p.recipe .. " on " .. p.name .. " ("
          .. tostring(rerr):match("^[^\n]*") .. ")"
      end
    end
  end

  for _, p in ipairs(plan.place) do
    local e = p.entity
    if p.role == "drill" and not e.drop_target then
      -- drop_target can lag a tick behind a fresh placement: accept a placed
      -- collector (or belt) that actually covers the drop point.
      local dp = e.drop_position
      local covered = false
      for _, q in ipairs(plan.place) do
        local o = q.entity
        if o ~= e and o.valid and (q.role == "collector" or q.role == "belt") then
          local bb = o.bounding_box
          -- Burner drills drop right on the collision-box edge: allow a little slack.
          if dp.x >= bb.left_top.x - 0.05 and dp.x <= bb.right_bottom.x + 0.05
             and dp.y >= bb.left_top.y - 0.05 and dp.y <= bb.right_bottom.y + 0.05 then covered = true end
        end
      end
      if not covered then
        local why = string.format("layout: drill at {%d,%d} would drop onto the ground — rolled back",
                                  math.floor(e.position.x), math.floor(e.position.y))
        undo(character, placed)
        return false, why
      end
    elseif p.role == "boiler" or p.role == "engine" then
      -- Fluid ports must actually have joined their neighbours (pump -> boiler -> engines).
      local want = p.role == "boiler" and "offshore-pump" or nil
      local joined_pump, joined_engine = false, false
      for i = 1, e.fluids_count do
        for _, rec in ipairs(e.get_fluid_box_neighbours(i) or {}) do
          if rec.entity.name == "offshore-pump" then joined_pump = true end
          if rec.entity.name == "steam-engine" or rec.entity.name == "boiler" then joined_engine = true end
        end
      end
      if (want and not joined_pump) or not joined_engine then
        local why = string.format("layout: %s at {%d,%d} didn't connect to its %s — rolled back", p.name,
          math.floor(e.position.x), math.floor(e.position.y), want and "pump" or "boiler/engine")
        undo(character, placed)
        return false, why
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

  -- Fuel what burns (boilers carry the whole base: more).
  local inv = character.get_inventory(defines.inventory.character_main)
  for _, p in ipairs(plan.place) do
    local fb = p.entity.valid and p.entity.get_fuel_inventory and p.entity.get_fuel_inventory()
    if fb and inv.get_item_count("coal") > 0 then
      local fill = p.role == "boiler" and 20 or p.role == "drill" and 10 or 5
      local ins = fb.insert{name = "coal", count = math.min(fill, inv.get_item_count("coal"))}
      if ins > 0 then inv.remove{name = "coal", count = ins} end
    end
  end
  return true, plan.place
end

AILayout.DIR_NAME = DIR_NAME
return AILayout
