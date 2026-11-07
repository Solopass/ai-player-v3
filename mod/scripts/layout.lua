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
  local surface, force = character.surface, character.force
  local dir = DIRS[facing or "north"]
  if surface.can_place_entity{name = name, position = {x, y}, direction = dir,
                              force = force, build_check_type = defines.build_check_type.manual} then
    return true
  end
  local tile = surface.get_tile(x, y)
  if tile and tile.collides_with("water_tile") then return false end
  local p = prototypes.entity[name]
  local w, h = p and p.tile_width or 1, p and p.tile_height or 1
  local area = {{x - w / 2 + 0.1, y - h / 2 + 0.1}, {x + w / 2 - 0.1, y + h / 2 - 0.1}}
  local ents = surface.find_entities_filtered{area = area}
  if #ents == 0 then return false end
  for _, e in ipairs(ents) do
    if e.type == "resource" then
      -- natural resource on the ground is fine (skip)
    elseif e.type == "item-entity" then
      -- ground items can be picked up
    elseif e.type == "tree" or (e.type == "simple-entity" and e.prototype.count_as_rock_for_filtered_deconstruction) then
      -- tree or rock can be cleared
    elseif (e.name == "burner-mining-drill" or e.name == "burner-inserter") and AIRegistry.is_owned(e) then
      -- obsolete burner gear can be replaced
    elseif e.type == "entity-ghost" and AIRegistry.is_ai_ghost(e) then
      -- only AI ghosts can be replaced!
    else
      return false
    end
  end
  return true
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
  local target_net = opts.target_network_id
  for _ = 1, opts.max or 24 do
    if dist2(cur.x, cur.y, goal.x, goal.y) <= (reach - 0.2) ^ 2 then
      return poles, true
    end
    local near = surface.find_entities_filtered{type = "electric-pole", position = cur, radius = reach, force = force}
    for _, np in ipairs(near) do
      if dist2(np.position.x, np.position.y, from.x, from.y) > 0.5 then
        if not target_net or np.electric_network_id == target_net then
          return poles, true
        end
      end
    end
    local dx, dy = goal.x - cur.x, goal.y - cur.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return poles, true end
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
local function power_pose(character, px, py, r, pump_already_placed)
  local surface = character.surface
  local pump_out = pipe_conns("offshore-pump", r)[1]
  local ux, uy = unit16(pump_out.dir)
  for pipe_len = 0, 12 do
    local tx, ty = px + ux * (pipe_len + 1), py + uy * (pipe_len + 1)   -- tile boiler's water port sits on
    local want = (pump_out.dir + 8) % 16                                -- ...facing back at pump / pipe
    for rb = 0, 3 do
      local conns = pipe_conns("boiler", rb)
      local steam
      for _, c in ipairs(conns) do if c.fb == 2 then steam = c end end
      for _, c in ipairs(conns) do
        if c.fb == 1 and c.dir == want then
          local bx, by = tx - c.x, ty - c.y
          if can_place(character, "boiler", bx, by, ORIENT[rb]) then
            local pipes_ok = true
            local pipe_boxes = {}
            local pipe_places = {}
            for s = 1, pipe_len do
              local pip_x, pip_y = px + ux * s, py + uy * s
              local existing_p = surface.find_entities_filtered{name = {"pipe", "entity-ghost"}, position = {pip_x, pip_y}, radius = 0.5, limit = 1}[1]
              if existing_p or can_place(character, "pipe", pip_x, pip_y) then
                if not existing_p then
                  pipe_places[#pipe_places + 1] = {name = "pipe", position = {x = pip_x, y = pip_y}, role = "pipe"}
                end
                pipe_boxes[#pipe_boxes + 1] = box(pip_x, pip_y, 1, 1)
              else
                pipes_ok = false
                break
              end
            end
            if pipes_ok then
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
                  for _, pb in ipairs(pipe_boxes) do boxes[#boxes + 1] = pb end
                  if all_free(boxes)
                     and can_place(character, "steam-engine", ex, ey, ORIENT[re])
                     and can_place(character, "steam-engine", e2x, e2y, ORIENT[re]) then
                    local places = {}
                    if not pump_already_placed then
                      places[#places + 1] = {name = "offshore-pump", position = {x = px, y = py}, direction = ORIENT[r], role = "pump"}
                    end
                    for _, pp in ipairs(pipe_places) do places[#places + 1] = pp end
                    places[#places + 1] = {name = "boiler", position = {x = bx, y = by}, direction = ORIENT[rb], role = "boiler"}
                    places[#places + 1] = {name = "steam-engine", position = {x = ex, y = ey}, direction = ORIENT[re], role = "engine"}
                    places[#places + 1] = {name = "steam-engine", position = {x = e2x, y = e2y}, direction = ORIENT[re], role = "engine"}

                    -- Add boiler fuel inserter and fuel belt tile on the side opposite steam connection
                    local opp_sx, opp_sy = unit16((steam.dir + 8) % 16)
                    local ins_x = bx + opp_sx * 1.5
                    local ins_y = by + opp_sy * 1.5
                    local belt_x = bx + opp_sx * 2.5
                    local belt_y = by + opp_sy * 2.5
                    local ins_dir = (steam.dir + 8) % 16
                    local belt_dir = (steam.dir + 4) % 16
                    local ins_orient = ORIENT[math.floor((ins_dir / 4) % 4)]
                    local belt_orient = ORIENT[math.floor((belt_dir / 4) % 4)]
                    local ins_box = box(ins_x, ins_y, 1, 1)
                    local belt_box = box(belt_x, belt_y, 1, 1)

                    local fuel_in, fuel_ins = nil, nil
                    if free(boxes, ins_box) and free(boxes, belt_box)
                       and can_place(character, "inserter", ins_x, ins_y, ins_orient)
                       and can_place(character, "transport-belt", belt_x, belt_y, belt_orient) then
                      places[#places + 1] = {name = "inserter", position = {x = ins_x, y = ins_y}, direction = ins_orient,
                                             role = "boiler_inserter", from = {x = belt_x, y = belt_y}, to = {x = bx, y = by}}
                      places[#places + 1] = {name = "transport-belt", position = {x = belt_x, y = belt_y}, direction = belt_orient,
                                             role = "boiler_fuel_in"}
                      boxes[#boxes + 1] = ins_box
                      boxes[#boxes + 1] = belt_box
                      fuel_in = {x = belt_x, y = belt_y, dir = belt_dir}
                      fuel_ins = {x = ins_x, y = ins_y, dir = ins_dir}
                    end

                    return {
                      place = places,
                      boxes = boxes, engine_box = boxes[3],
                      fuel_in = fuel_in, fuel_inserter = fuel_ins,
                    }
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

-- A steam block on the shore nearest `near` (the AI), with poles back toward `home`.
function AILayout.find_power(character, near, home)
  local surface = character.surface
  home = home or near

  local function build_from_pose(px, py, r, pump_already_placed)
    local plan = power_pose(character, px, py, r, pump_already_placed)
    if not plan then return nil end
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
    if not first then return nil end
    local claimed = {table.unpack(boxes)}
    claimed[#claimed + 1] = box(first.x, first.y, 1, 1)
    local poles, joined = AILayout.pole_chain(character, first, home, claimed)
    if not poles then return nil end
    local out = plan.place
    out[#out + 1] = {name = "small-electric-pole", position = {x = first.x, y = first.y}, role = "pole"}
    if plan.fuel_inserter then
      local fix, fiy = plan.fuel_inserter.x, plan.fuel_inserter.y
      if dist2(first.x, first.y, fix, fiy) > 6.25 then
        for _, off in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, -1}}) do
          local p_x, p_y = fix + off[1], fiy + off[2]
          if free(boxes, box(p_x, p_y, 1, 1)) and can_place(character, "small-electric-pole", p_x, p_y) then
            out[#out + 1] = {name = "small-electric-pole", position = {x = p_x, y = p_y}, role = "pole"}
            boxes[#boxes + 1] = box(p_x, p_y, 1, 1)
            break
          end
        end
      end
    end
    for _, pole in ipairs(poles) do out[#out + 1] = pole end
    return {place = out, joined = joined, facing = ORIENT[r], fuel_in = plan.fuel_in, fuel_inserter = plan.fuel_inserter}
  end

  -- Priority 1: If an offshore pump already exists, connect pipes, boiler, engines and poles to it!
  local existing_pumps = surface.find_entities_filtered{name = "offshore-pump", force = character.force}
  table.sort(existing_pumps, function(a, b)
    return dist2(a.position.x, a.position.y, near.x, near.y) < dist2(b.position.x, b.position.y, near.x, near.y)
  end)
  for _, p in ipairs(existing_pumps) do
    local r = math.floor((p.direction or 0) / 4) % 4
    local plan = build_from_pose(p.position.x, p.position.y, r, true)
    if plan then return plan end
  end

  -- Priority 2: Scan shoreline tiles for new pump spot
  local tiles = surface.find_tiles_filtered{collision_mask = "water_tile", position = near, radius = 40}
  table.sort(tiles, function(a, b)
    return dist2(a.position.x, a.position.y, near.x, near.y) < dist2(b.position.x, b.position.y, near.x, near.y)
  end)
  local tried = 0
  for _, t in ipairs(tiles) do
    for r = 0, 3 do
      local wx, wy = unit16(r * 4)
      local px, py = t.position.x + 0.5 - wx, t.position.y + 0.5 - wy
      local sp = surface.get_tile(px, py)
      if sp and not sp.collides_with("water_tile") then
        tried = tried + 1
        if tried > 300 then return nil end
        if can_place(character, "offshore-pump", px, py, ORIENT[r]) then
          local plan = build_from_pose(px, py, r, false)
          if plan then return plan end
        end
      end
    end
  end
  return nil
end

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

-- Electric drill -> chest on a resource patch (e.g. coal or stone), wired to grid.
function AILayout.find_electric_chest(character, resource, center, opts)
  local surface = character.surface
  local drill = "electric-mining-drill"
  local chest = (opts and opts.chest) or "wooden-chest"
  local dw, dh = footprint(drill)
  local cw, ch = footprint(chest)
  local tried = 0
  for _, c in ipairs(candidates(surface, drill, resource, center, (opts and opts.radius) or 64)) do
    tried = tried + 1
    if tried > 200 then break end
    local dbox = box(c.x, c.y, dw, dh)
    if coverage(surface, drill, c.x, c.y, resource) >= ((opts and opts.min_cover) or 0.6) then
      for _, facing in ipairs(facings({"south", "east", "north", "west"})) do
        if can_place(character, drill, c.x, c.y, facing) then
          local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
          local spot = collector_spot(px, py, cw, ch, dbox)
          if spot then
            local cx, cy = spot[1], spot[2]
            local pole_spot = nil
            for _, pdir in ipairs({{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,-1},{1,-1},{-1,1}}) do
              local test_qx, test_qy = cx + pdir[1], cy + pdir[2]
              if can_place(character, "small-electric-pole", test_qx, test_qy)
                 and not overlaps(box(test_qx, test_qy, 1, 1), dbox)
                 and not overlaps(box(test_qx, test_qy, 1, 1), box(cx, cy, cw, ch)) then
                pole_spot = {x = test_qx, y = test_qy}
                break
              end
            end
            if pole_spot and can_place(character, chest, cx, cy) then
              local grid = AILayout.nearest_pole(character, pole_spot)
              if grid then
                local parts = {dbox, box(cx, cy, cw, ch), box(pole_spot.x, pole_spot.y, 1, 1)}
                local poles, joined = AILayout.pole_chain(character, pole_spot, grid.position, parts)
                if poles then
                  local place = {
                    {name = drill, position = {x = c.x, y = c.y}, direction = facing, role = "drill"},
                    {name = chest, position = {x = cx, y = cy}, role = "chest"},
                    {name = "small-electric-pole", position = pole_spot, role = "pole"},
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

-- Row of electric mining drills (dw=3, dh=3) along an ore patch outputting onto a shared belt.
-- Powered by small electric poles wired back to the nearest power grid pole.
function AILayout.find_electric_row(character, resource, center, opts)
  local surface = character.surface
  local drill = "electric-mining-drill"
  local dw, dh = footprint(drill)
  local n = math.max(2, math.min((opts and opts.count) or 2, 4))
  local chest = (opts and opts.chest) or "wooden-chest"
  local tried = 0
  for _, c in ipairs(candidates(surface, drill, resource, center, (opts and opts.radius) or 64)) do
    tried = tried + 1
    if tried > 150 then break end
    for _, facing in ipairs(facings({"south", "north", "east", "west"})) do
      local fx, fy = FORWARD[facing][1], FORWARD[facing][2]
      local ax, ay = math.abs(fy), math.abs(fx)          -- row axis (perpendicular to drill facing)
      local flow = ax == 1 and "east" or "south"
      local ok, place, boxes = true, {}, {}
      for i = 0, n - 1 do
        local x, y = c.x + ax * dw * i, c.y + ay * dw * i
        if coverage(surface, drill, x, y, resource) < ((opts and opts.min_cover) or 0.5)
           or not can_place(character, drill, x, y, facing) then ok = false; break end
        place[#place + 1] = {name = drill, position = {x = x, y = y}, direction = facing, role = "drill"}
        boxes[#boxes + 1] = box(x, y, dw, dh)
      end
      if ok then
        -- Belt tiles: from the first drill's drop tile along the row to 1 tile past the last drill's edge
        local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
        local bx, by = math.floor(px) + 0.5, math.floor(py) + 0.5
        local last_x = c.x + ax * dw * (n - 1) + ax * dw / 2
        local last_y = c.y + ay * dw * (n - 1) + ay * dw / 2
        local tiles = 0
        local tx, ty = bx, by
        while (ax == 1 and tx <= last_x + 1) or (ay == 1 and ty <= last_y + 1) do
          if not can_place(character, "transport-belt", tx, ty, flow) then ok = false; break end
          place[#place + 1] = {name = "transport-belt", position = {x = tx, y = ty}, direction = flow, role = "belt"}
          boxes[#boxes + 1] = box(tx, ty, 1, 1)
          tiles = tiles + 1
          tx, ty = tx + ax, ty + ay
          if tiles > 2 * n * dw + 4 then ok = false; break end
        end
        if ok then
          -- Place collector chest + inserter at belt exit if chest specified
          local ix, iy = tx, ty
          local cx, cy = tx + ax, ty + ay
          if can_place(character, "inserter", ix, iy, flow) and can_place(character, chest, cx, cy) then
            place[#place + 1] = {name = "inserter", position = {x = ix, y = iy}, direction = flow,
                                 role = "inserter", from = {x = ix - ax, y = iy - ay}, to = {x = cx, y = cy}}
            place[#place + 1] = {name = chest, position = {x = cx, y = cy}, role = "chest"}
            boxes[#boxes + 1] = box(ix, iy, 1, 1)
            boxes[#boxes + 1] = box(cx, cy, 1, 1)
            -- The collector inserter sits past the last drill, out of reach of the poles behind
            -- the drills: its own pole on the drill side of the belt, 1 tile from the belt end.
            local ipx, ipy = ix - fx, iy - fy
            if can_place(character, "small-electric-pole", ipx, ipy) and free(boxes, box(ipx, ipy, 1, 1)) then
              place[#place + 1] = {name = "small-electric-pole", position = {x = ipx, y = ipy}, role = "pole"}
              boxes[#boxes + 1] = box(ipx, ipy, 1, 1)
            end
          end
          -- Place power poles behind the drills to power the entire row
          local pole_spot = nil
          for i = 0, n - 1 do
            local test_px = c.x + ax * dw * i - fx * 2
            local test_py = c.y + ay * dw * i - fy * 2
            if can_place(character, "small-electric-pole", test_px, test_py) then
              place[#place + 1] = {name = "small-electric-pole", position = {x = test_px, y = test_py}, role = "pole"}
              boxes[#boxes + 1] = box(test_px, test_py, 1, 1)
              pole_spot = pole_spot or {x = test_px, y = test_py}
            end
          end
          if pole_spot then
            local grid = AILayout.nearest_pole(character, pole_spot)
            if grid then
              local poles, joined = AILayout.pole_chain(character, pole_spot, grid.position, boxes)
              if poles then
                for _, pole in ipairs(poles) do place[#place + 1] = pole end
                return {facing = facing, flow = flow, place = place, joined = joined}
              end
            end
          end
        end
      end
    end
  end
  return nil
end

function AILayout.field_sizing(plates_per_min)
  local furnaces = math.max(1, math.ceil((plates_per_min or 18.75) / 18.75))
  local drills = math.max(1, math.ceil(furnaces * 18.75 / 30))
  local coal_drills = math.max(1, math.ceil(furnaces / 8))
  return {furnaces = furnaces, drills = drills, coal_drills = coal_drills}
end

function AILayout.field_resource_remaining(surface, bounds, resource)
  local total = 0
  for _, e in ipairs(surface.find_entities_filtered{area = bounds, name = resource}) do
    total = total + (e.amount or 0)
  end
  return total
end

-- Is a w x h entity centred at (x, y) inside the supply area of one of `poles` ({x, y} list)?
local function pole_covers(poles, x, y, w, h)
  local sa = prototypes.entity["small-electric-pole"].get_supply_area_distance()
  for _, p in ipairs(poles) do
    if math.abs(p.x - x) < w / 2 + sa - 0.01 and math.abs(p.y - y) < h / 2 + sa - 0.01 then return true end
  end
  return false
end

-- Extra poles that wire the separate pole groups of a plan (drill poles, furnace-column poles,
-- coal-drill poles) into one network. `nodes` is a {x, y} list (grows with the extra poles);
-- returns the extra poles as plan entries, or nil when two groups can't be joined.
local function join_pole_groups(character, nodes, boxes)
  local reach = prototypes.entity["small-electric-pole"].get_max_wire_distance()
  local extra = {}
  for _ = 1, 8 do
    local comp, ncomp = {}, 0
    for i = 1, #nodes do
      if not comp[i] then
        ncomp = ncomp + 1
        comp[i] = ncomp
        local stack = {i}
        while #stack > 0 do
          local a = table.remove(stack)
          for j = 1, #nodes do
            if not comp[j] and dist2(nodes[a].x, nodes[a].y, nodes[j].x, nodes[j].y) <= (reach - 0.2) ^ 2 then
              comp[j] = ncomp
              stack[#stack + 1] = j
            end
          end
        end
      end
    end
    if ncomp <= 1 then return extra end
    local bi, bj, bd
    for i = 1, #nodes do
      for j = i + 1, #nodes do
        if comp[i] ~= comp[j] then
          local d = dist2(nodes[i].x, nodes[i].y, nodes[j].x, nodes[j].y)
          if not bd or d < bd then bi, bj, bd = i, j, d end
        end
      end
    end
    -- target_network_id -1 never matches: the chain must reach the other group, not any old pole.
    local chain = AILayout.pole_chain(character, nodes[bi], nodes[bj], boxes, {target_network_id = -1, max = 6})
    if not chain then return nil end
    for _, c in ipairs(chain) do
      extra[#extra + 1] = c
      nodes[#nodes + 1] = {x = c.position.x, y = c.position.y}
    end
  end
  return nil
end

-- Share of the wanted resource among every resource tile in a drill's mining area (1 = pure).
local function purity(surface, drill_name, x, y, resource)
  local r = prototypes.entity[drill_name].mining_drill_radius or 0.99
  local area = {{x - r, y - r}, {x + r, y + r}}
  local all = surface.count_entities_filtered{area = area, type = "resource"}
  if all == 0 then return 0 end
  return surface.count_entities_filtered{area = area, type = "resource", name = resource} / all
end

-- Coal for the furnaces: a belt running straight away from the ore belt (towards +f, the side
-- opposite the drills) at the junction tile J, pointing back at it so it SIDE-LOADS onto the ore
-- belt's far lane (the drills fill the near lane). The first coal drill sits at the belt's far
-- end dropping onto its last tile; more drills sit beside the belt on the -axis side, which is
-- clear of the furnace column. Returns {belt, drills, poles} or nil when no coal is in reach.
local function plan_coal_feed(character, jx, jy, f, a, facing, coal_n, boxes)
  local surface = character.surface
  local drill = "electric-mining-drill"
  local fx, fy = f[1], f[2]
  local ax, ay = a[1], a[2]
  local into = OPPOSITE[facing]                       -- the belt points back at the ore belt
  local axis_dir = (ax == 1) and "east" or "south"    -- towards the belt, for drills on the -axis side
  for L = 2, 9 do
    local ex, ey = jx + fx * (L + 2), jy + fy * (L + 2)
    if coverage(surface, drill, ex, ey, "coal") >= 0.3 and purity(surface, drill, ex, ey, "coal") >= 0.9
       and can_place(character, drill, ex, ey, into) and free(boxes, box(ex, ey, 3, 3)) then
      local belt, drills, ok = {}, {{x = ex, y = ey, dir = into}}, true
      local lboxes = {box(ex, ey, 3, 3)}
      for s = 1, L do
        local sx, sy = jx + fx * s, jy + fy * s
        if not (can_place(character, "transport-belt", sx, sy, into) and free(boxes, box(sx, sy, 1, 1))
                and free(lboxes, box(sx, sy, 1, 1))) then
          ok = false; break
        end
        belt[#belt + 1] = {x = sx, y = sy}
        lboxes[#lboxes + 1] = box(sx, sy, 1, 1)
      end
      if ok then
        for k = 2, coal_n do
          local s = L - 2 - 3 * (k - 2)
          if s < 2 then break end
          local sx, sy = jx + fx * s - ax * 2, jy + fy * s - ay * 2
          if coverage(surface, drill, sx, sy, "coal") >= 0.3 and purity(surface, drill, sx, sy, "coal") >= 0.9
             and can_place(character, drill, sx, sy, axis_dir) and free(boxes, box(sx, sy, 3, 3))
             and free(lboxes, box(sx, sy, 3, 3)) then
            drills[#drills + 1] = {x = sx, y = sy, dir = axis_dir}
            lboxes[#lboxes + 1] = box(sx, sy, 3, 3)
          end
        end
        -- A pole beside each coal drill (outside every box).
        local poles = {}
        for _, d in ipairs(drills) do
          local spot
          for _, o in ipairs({{2, 0}, {-2, 0}, {0, 2}, {0, -2}}) do
            local px, py = d.x + o[1], d.y + o[2]
            if not spot and can_place(character, "small-electric-pole", px, py)
               and free(boxes, box(px, py, 1, 1)) and free(lboxes, box(px, py, 1, 1)) then
              spot = {x = px, y = py}
            end
          end
          if not spot then ok = false; break end
          poles[#poles + 1] = spot
          lboxes[#lboxes + 1] = box(spot.x, spot.y, 1, 1)
        end
        if ok then return {belt = belt, drills = drills, poles = poles, boxes = lboxes} end
      end
    end
  end
  return nil
end

-- A mining FIELD, one parametric stamp (all four facings): a straight ore belt with electric
-- drills on one side only, all dropping onto the belt's near lane, poles beside the drills; at the
-- belt's end a smelting column (inserter -> stone furnace -> inserter -> chest per furnace). Coal
-- side-loads onto the far lane (plan_coal_feed); without coal in reach the furnaces rely on the
-- fuel reflex. Returns nil unless EVERY drill and inserter is powered and the poles reach the grid.
-- Depletion watch for the fields the AI built (storage.ai_player.fields, written by build_miner
-- output=field): re-counts the patch under each field's mining area at most every 5 minutes
-- (one bounded area query per field) and reports what's left as a percentage. The planner builds
-- a replacement field below 20%.
local FIELD_CHECK_TICKS = 18000
function AILayout.fields_report(surface)
  local ap = storage.ai_player
  local out = {}
  for _, f in ipairs(ap and ap.fields or {}) do
    if f.surface == surface.name then
      if not f.checked or game.tick - f.checked >= FIELD_CHECK_TICKS then
        f.remaining = AILayout.field_resource_remaining(surface, f.bounds, f.resource)
        f.checked = game.tick
      end
      local pct = (f.initial or 0) > 0 and math.floor(100 * f.remaining / f.initial) or 0
      out[#out + 1] = {resource = f.resource, position = f.position, furnaces = f.furnaces,
                       remaining_pct = math.min(pct, 100)}
    end
  end
  return out
end

function AILayout.find_mining_field(character, resource, center, opts)
  local surface = character.surface
  local size = AILayout.field_sizing((opts and opts.rate) or 37.5)
  local n_furnaces = (opts and opts.furnaces) or size.furnaces
  local n_drills = (opts and opts.drills) or size.drills
  local coal_n = (opts and opts.coal_drills) or size.coal_drills
  local chest = (opts and opts.chest) or "iron-chest"
  local drill = "electric-mining-drill"
  local dw, dh = footprint(drill)
  local tried = 0
  -- The grid link is the costly part (pole searches + A*): no grid near here means no field,
  -- and at most 8 layouts per call get as far as trying it.
  if not AILayout.nearest_pole(character, center) then return nil end
  local links_left = 8

  for _, c in ipairs(candidates(surface, drill, resource, center, (opts and opts.radius) or 64)) do
    tried = tried + 1
    if tried > 150 then break end

    for _, facing in ipairs(facings({"south", "north", "east", "west"})) do
      local fx, fy = FORWARD[facing][1], FORWARD[facing][2]
      local ax, ay = math.abs(fy), math.abs(fx)
      local flow = (ax == 1) and "east" or "south"
      local ok, place, boxes = true, {}, {}
      local poles = {}                    -- {x, y} of every planned pole
      local powered = {}                  -- {x, y, w, h} of everything that needs power

      local min_x, max_x, min_y, max_y = math.huge, -math.huge, math.huge, -math.huge
      for i = 0, n_drills - 1 do
        local dx, dy = c.x + ax * dw * i, c.y + ay * dw * i
        if coverage(surface, drill, dx, dy, resource) < ((opts and opts.min_cover) or 0.3)
           or not can_place(character, drill, dx, dy, facing) then
          ok = false; break
        end
        place[#place + 1] = {name = drill, position = {x = dx, y = dy}, direction = facing, role = "drill"}
        boxes[#boxes + 1] = box(dx, dy, dw, dh)
        powered[#powered + 1] = {x = dx, y = dy, w = dw, h = dh}
        min_x, max_x = math.min(min_x, dx - 2.5), math.max(max_x, dx + 2.5)
        min_y, max_y = math.min(min_y, dy - 2.5), math.max(max_y, dy + 2.5)
      end

      if ok then
        -- Poles behind the drills (away from the belt).
        for i = 0, n_drills - 1 do
          local px = c.x + ax * dw * i - fx * 2
          local py = c.y + ay * dw * i - fy * 2
          if can_place(character, "small-electric-pole", px, py) and free(boxes, box(px, py, 1, 1)) then
            place[#place + 1] = {name = "small-electric-pole", position = {x = px, y = py}, role = "pole"}
            boxes[#boxes + 1] = box(px, py, 1, 1)
            poles[#poles + 1] = {x = px, y = py}
          end
        end

        local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
        local start_belt_x = math.floor(px) + 0.5
        local start_belt_y = math.floor(py) + 0.5
        local total_span = n_drills * dw + 2 + n_furnaces * 2 + 1
        for step = 0, total_span do
          local bx = start_belt_x + ax * step
          local by = start_belt_y + ay * step
          if not can_place(character, "transport-belt", bx, by, flow) or not free(boxes, box(bx, by, 1, 1)) then
            ok = false; break
          end
          place[#place + 1] = {name = "transport-belt", position = {x = bx, y = by}, direction = flow, role = "ore_belt"}
          boxes[#boxes + 1] = box(bx, by, 1, 1)
        end
      end

      -- Coal: junction tile just before the furnace column.
      local coal
      if ok then
        local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
        local sx, sy = math.floor(px) + 0.5, math.floor(py) + 0.5
        local jx, jy = sx + ax * (n_drills * dw), sy + ay * (n_drills * dw)
        coal = plan_coal_feed(character, jx, jy, {fx, fy}, {ax, ay}, facing, coal_n, boxes)
        if coal then
          for _, t in ipairs(coal.belt) do
            place[#place + 1] = {name = "transport-belt", position = {x = t.x, y = t.y}, direction = OPPOSITE[facing], role = "coal_belt"}
          end
          for _, d in ipairs(coal.drills) do
            place[#place + 1] = {name = drill, position = {x = d.x, y = d.y}, direction = d.dir, role = "coal_drill"}
            powered[#powered + 1] = {x = d.x, y = d.y, w = dw, h = dh}
          end
          for _, p in ipairs(coal.poles) do
            place[#place + 1] = {name = "small-electric-pole", position = {x = p.x, y = p.y}, role = "pole"}
            poles[#poles + 1] = {x = p.x, y = p.y}
          end
          for _, b in ipairs(coal.boxes) do boxes[#boxes + 1] = b end
        end
      end

      if ok then
        local px, py = AILayout.drop_point(drill, c.x, c.y, facing)
        local start_belt_x = math.floor(px) + 0.5
        local start_belt_y = math.floor(py) + 0.5
        local col_start = n_drills * dw + 2
        for f_idx = 0, n_furnaces - 1 do
          local step = col_start + f_idx * 2
          local bx = start_belt_x + ax * step
          local by = start_belt_y + ay * step

          local in_x = bx + fx * 1
          local in_y = by + fy * 1
          local fn_x = math.floor(bx + fx * 2.5 + ax * 0.5)
          local fn_y = math.floor(by + fy * 2.5 + ay * 0.5)
          local out_x = bx + fx * 4
          local out_y = by + fy * 4
          local ch_x = bx + fx * 5
          local ch_y = by + fy * 5

          if can_place(character, "inserter", in_x, in_y, facing)
             and can_place(character, "stone-furnace", fn_x, fn_y)
             and can_place(character, "inserter", out_x, out_y, facing)
             and can_place(character, chest, ch_x, ch_y)
             and free(boxes, box(in_x, in_y, 1, 1)) and free(boxes, box(fn_x, fn_y, 2, 2))
             and free(boxes, box(out_x, out_y, 1, 1)) and free(boxes, box(ch_x, ch_y, 1, 1)) then
            place[#place + 1] = {name = "inserter", position = {x = in_x, y = in_y}, direction = facing,
                                 role = "furnace_in", from = {x = bx, y = by}, to = {x = fn_x, y = fn_y}}
            place[#place + 1] = {name = "stone-furnace", position = {x = fn_x, y = fn_y}, role = "furnace"}
            place[#place + 1] = {name = "inserter", position = {x = out_x, y = out_y}, direction = facing,
                                 role = "furnace_out", from = {x = fn_x, y = fn_y}, to = {x = ch_x, y = ch_y}}
            place[#place + 1] = {name = chest, position = {x = ch_x, y = ch_y}, role = "chest"}
            boxes[#boxes + 1] = box(in_x, in_y, 1, 1)
            boxes[#boxes + 1] = box(fn_x, fn_y, 2, 2)
            boxes[#boxes + 1] = box(out_x, out_y, 1, 1)
            boxes[#boxes + 1] = box(ch_x, ch_y, 1, 1)
            powered[#powered + 1] = {x = in_x, y = in_y, w = 1, h = 1}
            powered[#powered + 1] = {x = out_x, y = out_y, w = 1, h = 1}

            -- One pole pair per two furnaces, in the free tile beside the inserters: one by the
            -- input inserter row, one by the output inserter row (a small pole reaches 2.5 tiles).
            if f_idx % 2 == 0 then
              for _, off in ipairs({1, 4}) do
                local cpx, cpy = bx + ax * 1 + fx * off, by + ay * 1 + fy * off
                if can_place(character, "small-electric-pole", cpx, cpy) and free(boxes, box(cpx, cpy, 1, 1)) then
                  place[#place + 1] = {name = "small-electric-pole", position = {x = cpx, y = cpy}, role = "pole"}
                  boxes[#boxes + 1] = box(cpx, cpy, 1, 1)
                  poles[#poles + 1] = {x = cpx, y = cpy}
                end
              end
            end
          else
            ok = false; break
          end
        end
      end

      -- Power: every drill and inserter must be inside a pole's supply area, the pole groups must
      -- form one network, and it must reach the grid. Anything less is no field.
      if ok then
        for _, w in ipairs(powered) do
          if not pole_covers(poles, w.x, w.y, w.w, w.h) then ok = false; break end
        end
      end
      if ok then
        local nodes = {}
        for _, p in ipairs(poles) do nodes[#nodes + 1] = {x = p.x, y = p.y} end
        local extra = join_pole_groups(character, nodes, boxes)
        if not extra then
          ok = false
        else
          for _, p in ipairs(extra) do place[#place + 1] = p end
          local link, grid_pos = nil, nil
          local grid = nil
          if links_left > 0 then
            links_left = links_left - 1
            grid = AILayout.nearest_pole(character, nodes[1])
          end
          if grid then
            -- start the chain from the planned pole closest to the grid
            local from, fd = nodes[1], nil
            for _, nd in ipairs(nodes) do
              local d = dist2(nd.x, nd.y, grid.position.x, grid.position.y)
              if not fd or d < fd then from, fd = nd, d end
            end
            link = AILayout.pole_chain(character, from, grid.position, boxes)
          end
          if not link then
            ok = false
          else
            for _, p in ipairs(link) do place[#place + 1] = p end
          end
        end
      end

      if ok then
        return {
          facing = facing,
          flow = flow,
          place = place,
          boxes = boxes,
          bounds = {{min_x, min_y}, {max_x, max_y}},
          resource = resource,
          drills = n_drills,
          furnaces = n_furnaces,
          coal_drills = coal and #coal.drills or 0,
          coal = coal ~= nil,
        }
      end
    end
  end

  return nil
end

-- Poles that wire an unpowered consumer (a lab placed before the grid reached it, ...):
-- one beside the machine, then a chain to the nearest pole on a network with a
-- generator. Returns a plan {place = poles}, or nil when a pole already covers the
-- machine or no chain fits. `radius` (the doctor reflex) keeps every search local: no
-- surface-wide generator scan, poles within `radius` of the machine only, a short chain.
function AILayout.find_consumer_poles(character, e, radius)
  local surface, force = character.surface, character.force
  local ex, ey = e.position.x, e.position.y
  local w, h = footprint(e.name)
  local live = {}
  if not radius then
    for _, g in ipairs(surface.find_entities_filtered{type = {"generator", "solar-panel", "electric-energy-interface"}, force = force}) do
      if g.electric_network_id then live[g.electric_network_id] = true end
    end
  end
  local search_r = radius or 250
  local nearby_poles = surface.find_entities_filtered{type = "electric-pole", force = force, position = e.position,
                                                      radius = math.max(w, h) / 2 + 2.5}
  for _, pole in ipairs(nearby_poles) do
    if pole.electric_network_id and (next(live) == nil or live[pole.electric_network_id]) then
      return nil                      -- a pole on a live generator network already reaches it
    end
  end
  local goal, gd
  for _, pole in ipairs(surface.find_entities_filtered{type = "electric-pole", force = force, position = e.position,
                                                       radius = search_r}) do
    if next(live) == nil or live[pole.electric_network_id] then
      local d = dist2(pole.position.x, pole.position.y, ex, ey)
      if not gd or d < gd then goal, gd = pole, d end
    end
  end
  if not goal then
    for _, pole in ipairs(surface.find_entities_filtered{type = "electric-pole", force = force, position = e.position, radius = search_r}) do
      local d = dist2(pole.position.x, pole.position.y, ex, ey)
      if not gd or d < gd then goal, gd = pole, d end
    end
  end
  if not goal then return nil end
  local opts = {target_network_id = goal.electric_network_id, max = radius and 6 or nil}
  if #nearby_poles > 0 then
    local p0 = nearby_poles[1]
    local poles, joined = AILayout.pole_chain(character, p0.position, goal.position, {}, opts)
    if poles and joined and #poles > 0 then
      local place = {}
      for _, pole in ipairs(poles) do place[#place + 1] = pole end
      return {place = place}
    end
  end
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
      local poles, joined = AILayout.pole_chain(character, {x = x, y = y}, goal.position, boxes, opts)
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

  local function clear_spot_for_placement(p)
    local proto = prototypes.entity[p.name]
    local w, h = proto and proto.tile_width or 1, proto and proto.tile_height or 1
    local x, y = p.position.x, p.position.y
    local area = {{x - w / 2 + 0.1, y - h / 2 + 0.1}, {x + w / 2 - 0.1, y + h / 2 - 0.1}}
    local ents = surface.find_entities_filtered{area = area}
    if #ents == 0 then return true end

    -- Verify first: confirm the spot is blocked ONLY by clearable entities
    for _, e in ipairs(ents) do
      if e.valid and e.type ~= "resource" then
        local clearable = (e.type == "item-entity")
          or (e.type == "tree")
          or (e.type == "simple-entity" and e.prototype.count_as_rock_for_filtered_deconstruction)
          or ((e.name == "burner-mining-drill" or e.name == "burner-inserter") and AIRegistry.is_owned(e))
          or (e.type == "entity-ghost" and AIRegistry.is_ai_ghost(e))
        if not clearable then return false end
      end
    end

    local inv = character.get_inventory(defines.inventory.character_main)
    for _, e in ipairs(ents) do
      if e.valid and e.type == "item-entity" then
        if inv and e.stack and e.stack.valid_for_read then
          local ins = inv.insert(e.stack)
          if ins >= e.stack.count then e.destroy() else e.stack.count = e.stack.count - ins end
        end
      elseif e.valid and (e.type == "tree" or (e.type == "simple-entity" and e.prototype.count_as_rock_for_filtered_deconstruction)) then
        character.mine_entity(e)
      elseif e.valid and (e.name == "burner-mining-drill" or e.name == "burner-inserter") and AIRegistry.is_owned(e) then
        character.mine_entity(e)
      elseif e.valid and e.type == "entity-ghost" and AIRegistry.is_ai_ghost(e) then
        e.destroy()
      end
    end
    return true
  end

  local placed = {}
  for _, p in ipairs(plan.place) do
    clear_spot_for_placement(p)
    local ok, detail = AIActions.run(character, {action = "place", item = p.name,
                                                 position = p.position, direction = p.direction, type = p.type})
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
      -- The doctor re-applies this if the recipe is ever cleared.
      local ap = storage.ai_player
      if ap and e.unit_number then
        ap.remembered_recipes = ap.remembered_recipes or {}
        ap.remembered_recipes[e.unit_number] = p.recipe
      end
    end
  end

  for _, p in ipairs(plan.place) do
    local e = p.entity
    if (p.role == "drill" or p.role == "coal_drill") and not e.drop_target then
      -- drop_target can lag a tick behind a fresh placement: accept a placed
      -- collector (or belt) that actually covers the drop point.
      local dp = e.drop_position
      local covered = false
      for _, q in ipairs(plan.place) do
        local o = q.entity
        if o ~= e and o.valid and (q.role == "collector" or q.role == "belt" or q.role == "ore_belt" or o.type == "transport-belt") then
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
          if rec.entity.name == "offshore-pump" or rec.entity.name == "pipe" then joined_pump = true end
          if rec.entity.name == "steam-engine" or rec.entity.name == "boiler" then joined_engine = true end
        end
      end
      if (want and not joined_pump) or not joined_engine then
        local why = string.format("layout: %s at {%d,%d} didn't connect to its %s — rolled back", p.name,
          math.floor(e.position.x), math.floor(e.position.y), want and "pump" or "boiler/engine")
        undo(character, placed)
        return false, why
      end
    elseif p.role == "inserter" or p.role == "boiler_inserter" then
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

  if plan.fuel_in and storage.ai_player then
    storage.ai_player.power_fuel_in = plan.fuel_in
  end

  if not plan.skip_flow_check and AIFlow and AIFlow.check then
    local flow_res = AIFlow.check(placed)
    if not flow_res.ok then
      local rep_ok, rep_detail = AIFlow.repair(character, flow_res)
      if not rep_ok then
        undo(character, placed)
        return false, rep_detail
      end
    end
  end

  return true, plan.place
end

AILayout.DIR_NAME = DIR_NAME
return AILayout
