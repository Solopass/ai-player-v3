-- Base coordinate frame and layout geometry (Round 20 Part 1a & 1b)
--
-- Maps between the base frame (u = along bus, v = across bus) and Factorio world coordinates.
--
-- Coordinate mapping table:
-- | bus dir | world x      | world y      |
-- | north   | origin.x + v | origin.y - u |
-- | east    | origin.x + u | origin.y + v |
-- | south   | origin.x - v | origin.y + u |
-- | west    | origin.x - u | origin.y - v |

Base = {}

local DIR_MAP = {
  north = defines.direction.north,
  east  = defines.direction.east,
  south = defines.direction.south,
  west  = defines.direction.west,
}

local DIR_NAME = {
  [defines.direction.north] = "north",
  [defines.direction.east]  = "east",
  [defines.direction.south] = "south",
  [defines.direction.west]  = "west",
}

-- Quarter-turns clockwise from North (16-way Factorio direction integer)
local DIR_OFFSET = {
  north = 0,
  east  = 4,
  south = 8,
  west  = 12,
}

local function normalize_dir(d)
  if type(d) == "number" then
    return DIR_NAME[d] or "north", d
  elseif type(d) == "string" then
    local s = d:lower()
    return s, DIR_MAP[s] or defines.direction.north
  end
  return "north", defines.direction.north
end

--- Convert base frame (u, v) to world coordinates (x, y)
function Base.to_world(base, u, v)
  local origin = base.origin or {x = 0, y = 0}
  local bdir = normalize_dir(base.dir or "east")

  if bdir == "north" then
    return origin.x + v, origin.y - u
  elseif bdir == "east" then
    return origin.x + u, origin.y + v
  elseif bdir == "south" then
    return origin.x - v, origin.y + u
  elseif bdir == "west" then
    return origin.x - u, origin.y - v
  end
  return origin.x + u, origin.y + v
end

--- Convert world coordinates (wx, wy) back to base frame (u, v)
function Base.to_base(base, wx, wy)
  local origin = base.origin or {x = 0, y = 0}
  local bdir = normalize_dir(base.dir or "east")

  if bdir == "north" then
    local v = wx - origin.x
    local u = origin.y - wy
    return u, v
  elseif bdir == "east" then
    local u = wx - origin.x
    local v = wy - origin.y
    return u, v
  elseif bdir == "south" then
    local v = origin.x - wx
    local u = wy - origin.y
    return u, v
  elseif bdir == "west" then
    local u = origin.x - wx
    local v = origin.y - wy
    return u, v
  end
  return wx - origin.x, wy - origin.y
end

--- Rotate direction d by the base orientation.
-- d can be string ("north", "east", "south", "west") or Factorio enum number.
-- Returns both rotated string name and Factorio enum number.
function Base.dir(base, d)
  local bname = normalize_dir(base.dir or "east")
  local boffset = DIR_OFFSET[bname] or 0

  local dname = normalize_dir(d or "north")
  local doffset = DIR_OFFSET[dname] or 0

  local rot_val = (doffset + boffset) % 16
  local rot_name = DIR_NAME[rot_val] or "north"

  if type(d) == "number" then
    return rot_val, rot_name
  else
    return rot_name, rot_val
  end
end

--- Calculate world bounding box for the reserved base corridor
function Base.get_forbidden(base)
  local length = base.length or 60
  local slot_depth = base.slot_depth or 18
  local width = slot_depth + 4 -- total width across v (e.g. 22 tiles)
  local w1x, w1y = Base.to_world(base, 0, -width)
  local w2x, w2y = Base.to_world(base, length, 2)
  local min_x, max_x = math.min(w1x, w2x), math.max(w1x, w2x)
  local min_y, max_y = math.min(w1y, w2y), math.max(w1y, w2y)
  return {{{min_x, min_y}, {max_x, max_y}}}
end

--- Check if world coordinates (x, y) fall inside any forbidden base corridor
function Base.is_forbidden(base, x, y)
  if not (base and base.forbidden) then return false end
  for _, box in ipairs(base.forbidden) do
    local lt, rb = box[1], box[2]
    if x >= lt[1] and x <= rb[1] and y >= lt[2] and y <= rb[2] then
      return true
    end
  end
  return false
end

--- Scan candidate origins at rings from home to find a clear base corridor
function Base.find_site(surface, home, opts)
  home = home or {x = 0, y = 0}
  opts = opts or {}
  local character = opts.character
  local force = opts.force or (character and character.force) or "player"
  local slot_depth = 18
  local total_width = slot_depth + 4 -- 22 tiles across v

  local rings = {24, 40, 56, 72}
  local facings = {"east", "south", "west", "north"}
  local angles = {0, 45, 90, 135, 180, 225, 270, 315}

  local candidate_origins = {}
  for _, r in ipairs(rings) do
    for _, deg in ipairs(angles) do
      local rad = math.rad(deg)
      local cx = math.floor(home.x + r * math.cos(rad) + 0.5)
      local cy = math.floor(home.y + r * math.sin(rad) + 0.5)
      candidate_origins[#candidate_origins + 1] = {x = cx, y = cy, dist2 = r * r}
    end
  end

  local max_origins = math.min(#candidate_origins, 32)
  local clear_candidates = {}

  local function is_corridor_clear(base)
    -- Corridor area: u from 0 to 60, v from -total_width (-22) to +2
    local c1x, c1y = Base.to_world(base, 0, -total_width)
    local c2x, c2y = Base.to_world(base, 60, 2)
    local area = {
      {math.min(c1x, c2x), math.min(c1y, c2y)},
      {math.max(c1x, c2x), math.max(c1y, c2y)}
    }

    if surface.count_tiles_filtered{area = area, collision_mask = "water_tile"} > 0 then return false end
    if surface.count_entities_filtered{area = area, name = "cliff"} > 0 then return false end
    if surface.count_entities_filtered{area = area, type = "resource"} > 0 then return false end

    local ents = surface.find_entities_filtered{area = area, force = force}
    for _, e in ipairs(ents) do
      if e.valid and e.type ~= "character" and e ~= character then
        return false
      end
    end

    -- 6x6 approach area in front of bus head: u from -6 to 0, v from -4 to +2
    local a1x, a1y = Base.to_world(base, -6, -4)
    local a2x, a2y = Base.to_world(base, 0, 2)
    local aarea = {
      {math.min(a1x, a2x), math.min(a1y, a2y)},
      {math.max(a1x, a2x), math.max(a1y, a2y)}
    }

    if surface.count_tiles_filtered{area = aarea, collision_mask = "water_tile"} > 0 then return false end
    if surface.count_entities_filtered{area = aarea, name = "cliff"} > 0 then return false end
    if surface.count_entities_filtered{area = aarea, type = "resource"} > 0 then return false end

    local aents = surface.find_entities_filtered{area = aarea, force = force}
    for _, e in ipairs(aents) do
      if e.valid and e.type ~= "character" and e ~= character then
        return false
      end
    end

    return true
  end

  for i = 1, max_origins do
    local pt = candidate_origins[i]
    for _, facing in ipairs(facings) do
      local cand_base = {origin = {x = pt.x, y = pt.y}, dir = facing, slot_depth = slot_depth}
      if is_corridor_clear(cand_base) then
        clear_candidates[#clear_candidates + 1] = {
          origin = {x = pt.x, y = pt.y},
          dir = facing,
          dist2 = pt.dist2,
        }
        if #clear_candidates >= 12 then
          break
        end
      end
    end
    if #clear_candidates >= 12 then
      break
    end
  end

  if #clear_candidates == 0 then
    return nil, "no clear base corridor found"
  end

  table.sort(clear_candidates, function(a, b) return a.dist2 < b.dist2 end)
  local best = clear_candidates[1]

  local site_base = {
    origin = best.origin,
    dir = best.dir,
    length = 60,
    slot_depth = slot_depth,
    slots = {},
    state = "planned"
  }
  site_base.forbidden = Base.get_forbidden(site_base)
  return site_base
end

return Base
