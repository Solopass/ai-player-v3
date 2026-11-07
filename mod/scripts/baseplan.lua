-- Base coordinate frame and layout geometry (Round 20 Part 1a)
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

return Base
