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

--- Scan the 4 cardinal directions from home to find the clearest base corridor
function Base.find_site(surface, home, opts)
  home = home or {x = 0, y = 0}
  opts = opts or {}
  local facings = {"east", "south", "west", "north"}
  local best_dir, best_len, best_score = nil, 0, -1

  local slot_depth = 18
  local total_width = slot_depth + 4 -- 22 tiles across v
  local max_len = 120

  for _, facing in ipairs(facings) do
    local base = {origin = home, dir = facing, slot_depth = slot_depth}
    local valid_len = 0
    local free_chunks = 0

    -- Scan in 10-tile chunks along u from 0 to 120
    for chunk_u = 0, max_len - 10, 10 do
      local w1x, w1y = Base.to_world(base, chunk_u, -total_width)
      local w2x, w2y = Base.to_world(base, chunk_u + 10, 2)
      local min_x, max_x = math.min(w1x, w2x), math.max(w1x, w2x)
      local min_y, max_y = math.min(w1y, w2y), math.max(w1y, w2y)
      local area = {{min_x, min_y}, {max_x, max_y}}

      local water = surface.count_tiles_filtered{area = area, collision_mask = "water_tile"}
      local cliffs = surface.count_entities_filtered{area = area, name = "cliff"}
      local player_ents = surface.count_entities_filtered{area = area, force = "player"}

      -- Block chunk if water or cliffs present, or more than character in the area
      if water > 0 or cliffs > 0 or player_ents > 2 then
        break
      else
        valid_len = chunk_u + 10
        free_chunks = free_chunks + 1
      end
    end

    if valid_len >= 60 and free_chunks > best_score then
      best_score = free_chunks
      best_dir = facing
      best_len = valid_len
    end
  end

  if not best_dir then
    best_dir = "east"
    best_len = 60
  end

  local site_base = {
    origin = home,
    dir = best_dir,
    length = best_len,
    slot_depth = slot_depth,
    slots = {},
    state = "planned"
  }
  site_base.forbidden = Base.get_forbidden(site_base)
  return site_base
end

return Base
