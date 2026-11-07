-- Standardized Tested Stamps for Base Frame (Round 20 Part 2)
--
-- Each stamp is defined in base coordinates (u along bus, v across bus):
--   entities: list of {name, u, v, dir, type?, recipe?, role?}
--   ports: named connection points {in_fe, in_cu, out_fe, out_cu, tap_fe, tap_cu, in_science, out_science, ...}
--
-- Coordinate conventions in base frame:
--   "north" = +u (along the bus downstream)
--   "south" = -u (upstream)
--   "east"  = +v (to the right of the bus)
--   "west"  = -v (to the left of the bus / into slots)
--
-- NOTE ON INSERTERS:
--   In Factorio, an inserter's `direction` is the side it PICKS UP from.
--   It drops to the opposite side (direction + 8).
--
-- Grid centers:
--   1x1 entities (belts, inserters, poles): half-integers in both u and v.
--   3x3 entities (assemblers, labs): half-integers in both u and v.
--   2x1 entities (splitters):
--     when dir is north/south: u is half-integer (1 tile), v is integer (2 tiles).
--
-- Rotation goes through Base.to_world and Base.dir ONLY.

local Base = require("scripts.baseplan")

Stamps = {}
Stamps.DEFINITIONS = {}

-- ---------------------------------------------------------------------------
-- 1. bus_segment: Fe belt at v=-1.5, Cu belt at v=-0.5, poles at v=0.5 (length 14)
-- ---------------------------------------------------------------------------
local bus_seg_ents = {}
for u = 0, 13 do
  bus_seg_ents[#bus_seg_ents + 1] = {name = "transport-belt", u = u + 0.5, v = -1.5, dir = "north", role = "bus_fe"}
  bus_seg_ents[#bus_seg_ents + 1] = {name = "transport-belt", u = u + 0.5, v = -0.5, dir = "north", role = "bus_cu"}
end
bus_seg_ents[#bus_seg_ents + 1] = {name = "small-electric-pole", u = 0.5,  v = 0.5, role = "bus_pole"}
bus_seg_ents[#bus_seg_ents + 1] = {name = "small-electric-pole", u = 6.5,  v = 0.5, role = "bus_pole"}
bus_seg_ents[#bus_seg_ents + 1] = {name = "small-electric-pole", u = 13.5, v = 0.5, role = "bus_pole"}

Stamps.DEFINITIONS["bus_segment"] = {
  length = 14,
  entities = bus_seg_ents,
  ports = {
    in_fe  = {u = 0.5,  v = -1.5, dir = "north"},
    in_cu  = {u = 0.5,  v = -0.5, dir = "north"},
    out_fe = {u = 13.5, v = -1.5, dir = "north"},
    out_cu = {u = 13.5, v = -0.5, dir = "north"},
  }
}

-- ---------------------------------------------------------------------------
-- 2. bus_head: 2 head ports (Fe, Cu) where trunks join, start of bus belts
-- ---------------------------------------------------------------------------
local bus_head_ents = {}
for u = 0, 3 do
  bus_head_ents[#bus_head_ents + 1] = {name = "transport-belt", u = u + 0.5, v = -1.5, dir = "north", role = "bus_fe"}
  bus_head_ents[#bus_head_ents + 1] = {name = "transport-belt", u = u + 0.5, v = -0.5, dir = "north", role = "bus_cu"}
end
bus_head_ents[#bus_head_ents + 1] = {name = "small-electric-pole", u = 0.5, v = 0.5, role = "bus_pole"}
bus_head_ents[#bus_head_ents + 1] = {name = "small-electric-pole", u = 3.5, v = 0.5, role = "bus_pole"}

Stamps.DEFINITIONS["bus_head"] = {
  length = 4,
  entities = bus_head_ents,
  ports = {
    in_fe  = {u = 0.5, v = -1.5, dir = "north"},
    in_cu  = {u = 0.5, v = -0.5, dir = "north"},
    out_fe = {u = 3.5, v = -1.5, dir = "north"},
    out_cu = {u = 3.5, v = -0.5, dir = "north"},
  }
}

-- ---------------------------------------------------------------------------
-- 3. tap_outer (Fe): splitter on Fe belt at v=-2.0 (spans v=-1.5 and v=-2.5),
--    branch at v=-2.5 turns outward into the slot's input.
-- ---------------------------------------------------------------------------
local tap_outer_ents = {
  -- Splitter spanning v = -1.5 (Fe bus) and v = -2.5 (tap lane). Center v = -2.0.
  {name = "splitter", u = 0.5, v = -2.0, dir = "north", role = "tap_fe_splitter"},
  -- Fe bus through-line continues at u=1.5, v=-1.5
  {name = "transport-belt", u = 1.5, v = -1.5, dir = "north", role = "bus_fe"},
  -- Tapped Fe turns outward towards v < 0 (dir = "west")
  {name = "transport-belt", u = 1.5, v = -2.5, dir = "west", role = "tap_fe_branch"},
  {name = "transport-belt", u = 1.5, v = -3.5, dir = "west", role = "tap_fe_out"},
  -- Cu bus continues undisturbed
  {name = "transport-belt", u = 0.5, v = -0.5, dir = "north", role = "bus_cu"},
  {name = "transport-belt", u = 1.5, v = -0.5, dir = "north", role = "bus_cu"},
  -- Bus pole
  {name = "small-electric-pole", u = 0.5, v = 0.5, role = "bus_pole"},
}

Stamps.DEFINITIONS["tap_outer"] = {
  length = 2,
  entities = tap_outer_ents,
  ports = {
    in_fe  = {u = 0.5, v = -1.5, dir = "north"},
    in_cu  = {u = 0.5, v = -0.5, dir = "north"},
    out_fe = {u = 1.5, v = -1.5, dir = "north"},
    out_cu = {u = 1.5, v = -0.5, dir = "north"},
    tap_fe = {u = 1.5, v = -3.5, dir = "west"},
  }
}

-- ---------------------------------------------------------------------------
-- 4. tap_inner (Cu): Fe belt dives underground u=0.5..3.5; Cu splitter sits at
--    v=-1.0 (spans v=-0.5 and v=-1.5), branch turns outward over buried Fe
-- ---------------------------------------------------------------------------
local tap_inner_ents = {
  -- Fe belt underground dive from u=0.5 to u=3.5 (underground span = 2 clear tiles at u=1.5, 2.5)
  {name = "underground-belt", u = 0.5, v = -1.5, dir = "north", type = "input", role = "fe_ug_in"},
  {name = "underground-belt", u = 3.5, v = -1.5, dir = "north", type = "output", role = "fe_ug_out"},

  -- Cu bus lead-in
  {name = "transport-belt", u = 0.5, v = -0.5, dir = "north", role = "bus_cu"},

  -- Cu splitter at u=1.5 spanning v=-0.5 and v=-1.5 (center v=-1.0)
  {name = "splitter", u = 1.5, v = -1.0, dir = "north", role = "tap_cu_splitter"},

  -- Tapped Cu output at v=-1.5 turns outward over buried Fe belt
  {name = "transport-belt", u = 2.5, v = -1.5, dir = "west", role = "tap_cu_branch"},
  {name = "transport-belt", u = 2.5, v = -2.5, dir = "west", role = "tap_cu_branch"},
  {name = "transport-belt", u = 2.5, v = -3.5, dir = "west", role = "tap_cu_out"},

  -- Cu bus through-line continues at u=2.5 and u=3.5 at v=-0.5
  {name = "transport-belt", u = 2.5, v = -0.5, dir = "north", role = "bus_cu"},
  {name = "transport-belt", u = 3.5, v = -0.5, dir = "north", role = "bus_cu"},

  -- Bus poles
  {name = "small-electric-pole", u = 0.5, v = 0.5, role = "bus_pole"},
  {name = "small-electric-pole", u = 3.5, v = 0.5, role = "bus_pole"},
}

Stamps.DEFINITIONS["tap_inner"] = {
  length = 4,
  entities = tap_inner_ents,
  ports = {
    in_fe  = {u = 0.5, v = -1.5, dir = "north"},
    in_cu  = {u = 0.5, v = -0.5, dir = "north"},
    out_fe = {u = 3.5, v = -1.5, dir = "north"},
    out_cu = {u = 3.5, v = -0.5, dir = "north"},
    tap_cu = {u = 2.5, v = -3.5, dir = "west"},
  }
}

-- ---------------------------------------------------------------------------
-- 5. gear_red: Red science slot module
--    2 × [Red Asm (3x3) | Inserter | Gear Asm (3x3) | Inserter | Red Asm (3x3)]
--    Total 4 Red Assemblers, 2 Gear Assemblers.
--    Dual-lane Fe/Cu feed belt enters at v=-4.5, snakes past Row 1 and Row 2.
--    Common Science output belt at v=-10.5 along +u.
-- ---------------------------------------------------------------------------
local gear_red_ents = {
  -- Row 1 Feed Belt along +u at v = -4.5
  {name = "transport-belt", u = 0.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 1.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 2.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 3.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 4.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 5.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 6.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 7.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 8.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 9.5,  v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 10.5, v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 11.5, v = -4.5, dir = "north", role = "input_fe_cu"},
  {name = "transport-belt", u = 12.5, v = -4.5, dir = "north", role = "input_fe_cu"},

  -- Loop snake around u = 13.5 down to Row 2
  {name = "transport-belt", u = 13.5, v = -4.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -5.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -6.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -7.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -8.5, dir = "west", role = "feed_snake"},
  -- Underground dive under Common Science Belt (at v=-10.5)
  {name = "underground-belt", u = 13.5, v = -9.5,  dir = "west", type = "input",  role = "feed_ug_in"},
  {name = "underground-belt", u = 13.5, v = -11.5, dir = "west", type = "output", role = "feed_ug_out"},
  {name = "transport-belt", u = 13.5, v = -12.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -13.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -14.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -15.5, dir = "west", role = "feed_snake"},
  {name = "transport-belt", u = 13.5, v = -16.5, dir = "south", role = "feed_snake"},

  -- Row 2 Feed Belt along -u at v = -16.5
  {name = "transport-belt", u = 12.5, v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 11.5, v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 10.5, v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 9.5,  v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 8.5,  v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 7.5,  v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 6.5,  v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 5.5,  v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 4.5,  v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 3.5,  v = -16.5, dir = "south", role = "feed_row2"},
  {name = "transport-belt", u = 2.5,  v = -16.5, dir = "south", role = "feed_row2"},

  -- ==========================================
  -- Row 1: Assemblers at v = -7.5
  -- ==========================================
  -- Input inserters: pick up from feed belt at v=-4.5 (+v -> dir="east"), drop into assembler at v=-6.5 (-v)
  {name = "inserter", u = 2.5,  v = -5.5, dir = "east", role = "ins_r1_red1_in"},
  {name = "inserter", u = 6.5,  v = -5.5, dir = "east", role = "ins_r1_gear_in"},
  {name = "inserter", u = 10.5, v = -5.5, dir = "east", role = "ins_r1_red2_in"},

  -- Assemblers & direct insertion
  {name = "assembling-machine-1", u = 2.5,  v = -7.5, dir = "north", recipe = "automation-science-pack", role = "r1_red_asm1"},
  -- Inserter picks up from Gear Asm at u=6.5 (+u -> dir="north"), drops into Red Asm 1 at u=2.5 (-u)
  {name = "inserter",             u = 4.5,  v = -7.5, dir = "north", role = "r1_gear_to_red1"},
  {name = "assembling-machine-1", u = 6.5,  v = -7.5, dir = "north", recipe = "iron-gear-wheel", role = "r1_gear_asm"},
  -- Inserter picks up from Gear Asm at u=6.5 (-u -> dir="south"), drops into Red Asm 2 at u=10.5 (+u)
  {name = "inserter",             u = 8.5,  v = -7.5, dir = "south", role = "r1_gear_to_red2"},
  {name = "assembling-machine-1", u = 10.5, v = -7.5, dir = "north", recipe = "automation-science-pack", role = "r1_red_asm2"},

  -- Output inserters: pick up from Red Asm at v=-8.5 (+v -> dir="east"), drop onto science belt at v=-10.5 (-v)
  {name = "inserter", u = 2.5,  v = -9.5, dir = "east", role = "ins_r1_red1_out"},
  {name = "inserter", u = 10.5, v = -9.5, dir = "east", role = "ins_r1_red2_out"},

  -- ==========================================
  -- Common Science Belt at v = -10.5 along +u
  -- ==========================================
  {name = "transport-belt", u = 1.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 2.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 3.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 4.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 5.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 6.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 7.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 8.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 9.5,  v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 10.5, v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 11.5, v = -10.5, dir = "north", role = "science_belt"},
  {name = "transport-belt", u = 12.5, v = -10.5, dir = "north", role = "science_belt"},

  -- ==========================================
  -- Row 2: Assemblers at v = -13.5
  -- ==========================================
  -- Output inserters: pick up from Red Asm at v=-12.5 (-v -> dir="west"), drop onto science belt at v=-10.5 (+v)
  {name = "inserter", u = 2.5,  v = -11.5, dir = "west", role = "ins_r2_red1_out"},
  {name = "inserter", u = 10.5, v = -11.5, dir = "west", role = "ins_r2_red2_out"},

  -- Assemblers & direct insertion
  {name = "assembling-machine-1", u = 2.5,  v = -13.5, dir = "north", recipe = "automation-science-pack", role = "r2_red_asm1"},
  -- Inserter picks up from Gear Asm 2 at u=6.5 (+u -> dir="north"), drops into Red Asm 3 at u=2.5 (-u)
  {name = "inserter",             u = 4.5,  v = -13.5, dir = "north", role = "r2_gear_to_red1"},
  {name = "assembling-machine-1", u = 6.5,  v = -13.5, dir = "north", recipe = "iron-gear-wheel", role = "r2_gear_asm"},
  -- Inserter picks up from Gear Asm 2 at u=6.5 (-u -> dir="south"), drops into Red Asm 4 at u=10.5 (+u)
  {name = "inserter",             u = 8.5,  v = -13.5, dir = "south", role = "r2_gear_to_red2"},
  {name = "assembling-machine-1", u = 10.5, v = -13.5, dir = "north", recipe = "automation-science-pack", role = "r2_red_asm2"},

  -- Input inserters: pick up from feed belt 2 at v=-16.5 (-v -> dir="west"), drop into assembler at v=-14.5 (+v)
  {name = "inserter", u = 2.5,  v = -15.5, dir = "west", role = "ins_r2_red1_in"},
  {name = "inserter", u = 6.5,  v = -15.5, dir = "west", role = "ins_r2_gear_in"},
  {name = "inserter", u = 10.5, v = -15.5, dir = "west", role = "ins_r2_red2_in"},

  -- Power poles covering entire slot and connecting back to bus
  {name = "small-electric-pole", u = 6.5, v = -2.5, role = "slot_feeder_pole"},
  {name = "small-electric-pole", u = 4.5, v = -5.5, role = "r1_pole"},
  {name = "small-electric-pole", u = 8.5, v = -5.5, role = "r1_pole"},
  {name = "small-electric-pole", u = 4.5, v = -9.5, role = "r1_out_pole"},
  {name = "small-electric-pole", u = 8.5, v = -9.5, role = "r1_out_pole"},
  {name = "small-electric-pole", u = 4.5, v = -11.5, role = "r2_out_pole"},
  {name = "small-electric-pole", u = 8.5, v = -11.5, role = "r2_out_pole"},
  {name = "small-electric-pole", u = 4.5, v = -15.5, role = "r2_pole"},
  {name = "small-electric-pole", u = 8.5, v = -15.5, role = "r2_pole"},
}

Stamps.DEFINITIONS["gear_red"] = {
  length = 14,
  depth = 18,
  entities = gear_red_ents,
  ports = {
    in_fe_cu    = {u = 0.5,  v = -4.5,  dir = "north"},
    out_science = {u = 12.5, v = -10.5, dir = "north"},
  }
}

-- ---------------------------------------------------------------------------
-- 6. lab_row: 6 labs along the science belt with inserters lab-to-lab
-- ---------------------------------------------------------------------------
local lab_row_ents = {
  -- Science belt coming in at v = -10.5
  {name = "transport-belt", u = 0.5, v = -10.5, dir = "north", role = "science_in"},
  {name = "transport-belt", u = 1.5, v = -10.5, dir = "north", role = "science_in"},

  -- Inserter from science belt (v=-10.5) into Lab 1 (v=-13.5).
  -- Picks up from belt at v=-10.5 (+v -> dir="east"), drops into Lab 1 at v=-12.5 (-v)
  {name = "inserter", u = 1.5, v = -11.5, dir = "east", role = "belt_to_lab1"},

  -- 6 Labs in a line along u at v = -13.5 (spanning v in [-12.0, -15.0])
  -- Lab 1
  {name = "lab", u = 1.5, v = -13.5, dir = "north", role = "lab_1"},
  -- Inserter Lab 1 -> Lab 2: picks up from Lab 1 at u=2.5 (-u -> dir="south"), drops into Lab 2 at u=4.5 (+u)
  {name = "inserter", u = 3.5, v = -13.5, dir = "south", role = "lab1_to_lab2"},
  -- Lab 2
  {name = "lab", u = 5.5, v = -13.5, dir = "north", role = "lab_2"},
  -- Inserter Lab 2 -> Lab 3: picks up from Lab 2 (-u -> dir="south"), drops into Lab 3 (+u)
  {name = "inserter", u = 7.5, v = -13.5, dir = "south", role = "lab2_to_lab3"},
  -- Lab 3
  {name = "lab", u = 9.5, v = -13.5, dir = "north", role = "lab_3"},
  -- Inserter Lab 3 -> Lab 4: picks up from Lab 3 (-u -> dir="south"), drops into Lab 4 (+u)
  {name = "inserter", u = 11.5, v = -13.5, dir = "south", role = "lab3_to_lab4"},
  -- Lab 4
  {name = "lab", u = 13.5, v = -13.5, dir = "north", role = "lab_4"},
  -- Inserter Lab 4 -> Lab 5: picks up from Lab 4 (-u -> dir="south"), drops into Lab 5 (+u)
  {name = "inserter", u = 15.5, v = -13.5, dir = "south", role = "lab4_to_lab5"},
  -- Lab 5
  {name = "lab", u = 17.5, v = -13.5, dir = "north", role = "lab_5"},
  -- Inserter Lab 5 -> Lab 6: picks up from Lab 5 (-u -> dir="south"), drops into Lab 6 (+u)
  {name = "inserter", u = 19.5, v = -13.5, dir = "south", role = "lab5_to_lab6"},
  -- Lab 6
  {name = "lab", u = 21.5, v = -13.5, dir = "north", role = "lab_6"},

  -- Electric poles powering labs and inserters
  {name = "small-electric-pole", u = 3.5,  v = -11.5, role = "lab_pole"},
  {name = "small-electric-pole", u = 9.5,  v = -11.5, role = "lab_pole"},
  {name = "small-electric-pole", u = 15.5, v = -11.5, role = "lab_pole"},
  {name = "small-electric-pole", u = 21.5, v = -11.5, role = "lab_pole"},
}

Stamps.DEFINITIONS["lab_row"] = {
  length = 24,
  depth = 16,
  entities = lab_row_ents,
  ports = {
    in_science = {u = 0.5, v = -10.5, dir = "north"},
  }
}

-- ---------------------------------------------------------------------------
-- Stamp placement API
-- ---------------------------------------------------------------------------
function Stamps.plan(base, name, at_u, side)
  local def = Stamps.DEFINITIONS[name]
  if not def then return nil, "unknown stamp: " .. tostring(name) end

  at_u = at_u or 0
  side = side or "left"

  local places = {}
  for _, e in ipairs(def.entities) do
    local u = at_u + e.u
    local v = (side == "right" and -e.v) or e.v
    local wx, wy = Base.to_world(base, u, v)
    local wdir_name, wdir_val = Base.dir(base, e.dir or "north")

    places[#places + 1] = {
      name = e.name,
      position = {x = wx, y = wy},
      direction = wdir_name,
      direction_val = wdir_val,
      recipe = e.recipe,
      role = e.role,
      type = e.type, -- for underground-belt input/output
    }
  end

  local ports = {}
  for pname, p in pairs(def.ports or {}) do
    local u = at_u + p.u
    local v = (side == "right" and -p.v) or p.v
    local wx, wy = Base.to_world(base, u, v)
    local pdir_name, pdir_val = Base.dir(base, p.dir or "north")
    ports[pname] = {
      position = {x = wx, y = wy},
      direction = pdir_name,
      direction_val = pdir_val,
    }
  end

  return {
    name = name,
    place = places,
    ports = ports,
    length = def.length,
    depth = def.depth,
    skip_flow_check = true,
  }
end

--- Place stamp entities using AILayout.build
function Stamps.place(character, base, name, at_u, side)
  local plan, err = Stamps.plan(base, name, at_u, side)
  if not plan then return false, err end
  return AILayout.build(character, plan)
end

return Stamps
