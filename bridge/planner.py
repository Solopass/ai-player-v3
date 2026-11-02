"""
Next-step planner: a fixed early-game build order turned into ONE concrete
skill entry, so a small model has a sensible move to copy (or the coach has
one to fall back on when the model loops).

next_steps(perception, blocked) -> up to 4 (entry, reason) moves for one turn
(the mod runs them in order and waits for hand-crafting in between). Rules run
in priority order and skip entries whose key is blocked (bridge/coach.py), so a
move that keeps failing gives way to the next useful one.

Each move also carries a `sure` flag: True for fixed build-order steps (the
burner bootstrap, tend/refuel, power, the red cell...), False for guesses
(trigger crafts, research picks). The hybrid autopilot (bridge/agent.py) skips
the model when the first move is sure; next_plan() exposes the flag.
"""

from __future__ import annotations

from typing import Iterator

from . import blueprints, goals
from .blueprints import _ENTITY_ITEM

# Electric pair (drill -> stone furnace) yield, plates/min: the furnace is the limit.
PAIR_PLATES_PER_MIN = 18
SMELT_TARGET = {"iron-ore": ("iron-plate", 30), "copper-ore": ("copper-plate", 15)}

# (resource, drills wanted, output) — the burner bootstrap, coal first so
# everything else has fuel. Thresholds match the bootstrap milestone.
BOOTSTRAP = [("coal", 1, "chest"), ("iron-ore", 2, "furnace"),
             ("copper-ore", 1, "furnace"), ("stone", 1, "chest")]
FAR = 50  # tiles; build_miner only searches 64 around the character
WATER_NEAR = 35  # tiles; build_power refuses water farther than 40
DEFENSE_RANGE = 150   # tiles: an enemy nest this close to home (or any attack) means turrets
DEFENSE_TURRETS = 3
GATHER_NEAR = 35  # tiles; gather only searches 40 around the character


# Techs to queue, in order, whenever nothing is being researched: the ladder's own
# needs first (automation -> logistics -> green science), then defence and quality of
# life. (tech, needs_green): green-pack techs wait until green science is made.
# The mod owns this list now (skills.lua RESEARCH_ORDER, reported as perception.research.order,
# which its reflexes also use); this copy is the fallback for a mod that doesn't report it.
RESEARCH_ORDER = [
    ("automation", False), ("logistics", False), ("logistic-science-pack", False),
    ("gun-turret", False), ("military", False), ("steel-processing", False),
    ("fast-inserter", False), ("stone-wall", False),
    ("physical-projectile-damage-1", False), ("weapon-shooting-speed-1", False),
    ("automation-2", True), ("engine", True), ("electric-energy-distribution-1", True),
    ("toolbelt", True), ("advanced-material-processing", True),
]


# Assembler units of the green cell (mod skills.lua GREEN_UNITS): gears, cable, circuits,
# inserters, belts and two science assemblers.
GREEN_UNITS = ["iron-gear-wheel", "copper-cable", "electronic-circuit", "inserter", "transport-belt",
               "logistic-science-pack", "logistic-science-pack"]


def entry_key(d: dict) -> str:
    """Stable identity of a move, for the sent entry and the mod's result alike.
    Results label skills "skill:<name>" and primitives by name."""
    if d.get("skill"):
        name = "skill:" + str(d["skill"])
    else:
        name = str(d.get("action") or "?")
    parts = [name]
    for k in ("item", "tech", "resource", "recipe", "name", "ore", "output", "count"):
        # build_miner's count shrinks as drills get built; the move is the same.
        if k == "count" and name == "skill:build_miner":
            continue
        if d.get(k) is not None:
            parts.append(f"{k}={d[k]}")
    return "|".join(parts)


def _inv(p: dict) -> dict[str, int]:
    out: dict[str, int] = {}
    for it in p.get("inventory") or []:
        if isinstance(it, dict) and it.get("name"):
            out[it["name"]] = out.get(it["name"], 0) + int(it.get("count") or 0)
    return out


def _count(v) -> int:
    if isinstance(v, dict):
        return int(v.get("count") or 0)
    return int(v or 0)


def _landmark(p: dict, resource: str) -> dict | None:
    for r in ((p.get("landmarks") or {}).get("resources") or []):
        if r.get("name") == resource:
            return r
    return None


def _lab_count(p: dict) -> int:
    # factory.labs counts every lab; factory.machines disappears on big bases.
    return int(((p.get("factory") or {}).get("labs") or {}).get("count", 0))


def _labs(p: dict) -> list[dict]:
    machines = (p.get("factory") or {}).get("machines") or []
    return [m for m in machines if isinstance(m, dict) and m.get("type") == "lab"]


def _by_type(p: dict, name: str) -> int:
    return int(((p.get("factory") or {}).get("by_type") or {}).get(name, 0))


def research_order(p: dict) -> list[tuple[str, bool]]:
    """The mod's queue order (perception.research.order), else the built-in copy."""
    order = (p.get("research") or {}).get("order") or []
    out = [(str(o["tech"]), bool(o.get("green"))) for o in order if isinstance(o, dict) and o.get("tech")]
    return out or RESEARCH_ORDER


def _reflexes(p: dict) -> bool:
    """True when the mod's reflexes are on: they refuel, empty full furnaces/chests and reload
    turrets by themselves, so the planner doesn't spend moves on those."""
    return bool((p.get("reflex") or {}).get("enabled"))


def _tech(p: dict, name: str) -> bool:
    return name in ((p.get("research") or {}).get("done") or [])


def _rate(p: dict, item: str) -> int:
    return int((((p.get("production") or {}).get("items") or {}).get(item) or {}).get("per_min", 0))


def _craft(inv: dict, item: str, want: int, why: str) -> Iterator[tuple[dict, str, bool]]:
    """craft_for until `want` are held (the bootstrap's pattern), if short."""
    if inv.get(item, 0) < want:
        yield {"skill": "craft_for", "item": item, "count": want}, why, True


def _goto_far(p: dict, lm: dict | None, what: str,
              limit: int = FAR) -> Iterator[tuple[dict, str, bool]]:
    if lm and lm.get("distance", 0) > limit:
        yield ({"skill": "goto", "position": {"x": lm["x"], "y": lm["y"]}},
               f"nearest {what} is {lm['distance']} tiles away", True)


def _find_placed(p: dict, bp_name: str) -> dict | None:
    for b in p.get("placed_blueprints") or []:
        if isinstance(b, dict) and b.get("name") == bp_name and b.get("position"):
            return b.get("position")
    return None


def _is_connected(connected: list[dict], pt1: dict, pt2: dict) -> bool:
    for c in connected:
        f = c.get("from") or {}
        t = c.get("to") or {}
        if abs(f.get("x", 0) - pt1["x"]) < 1.0 and abs(f.get("y", 0) - pt1["y"]) < 1.0 \
           and abs(t.get("x", 0) - pt2["x"]) < 1.0 and abs(t.get("y", 0) - pt2["y"]) < 1.0:
            return True
    return False


def _late_game(p: dict, inv: dict, factory: dict, goal_id: str) -> Iterator[tuple[dict, str, bool]]:
    """Build-order rules past the bootstrap: power, automation, smelting, red cell, green cell."""
    power = p.get("power") or {}
    unlocked_bps = set(p.get("blueprint_library") or [])
    placed_bps = p.get("placed_blueprints") or []
    placed_names = {b.get("name") for b in placed_bps if isinstance(b, dict)}

    # If power is missing or destroyed at any point in the game, restore power first
    if not power.get("has_grid") or not _by_type(p, "boiler"):
        yield from _goto_far(p, (p.get("landmarks") or {}).get("water"), "water",
                             WATER_NEAR)
        for item, n in (("offshore-pump", 1), ("boiler", 1), ("steam-engine", 2), ("pipe", 5),
                        ("small-electric-pole", 6)):
            yield from _craft(inv, item, n, f"steam power needs {n} {item}")
        yield {"skill": "build_power"}, "no electric grid: pump, boiler, engines and poles", True

    if goal_id == "power":
        pass
    elif goal_id == "automation":
        # Red packs unlock by a trigger first; until it's done, research can't start.
        # Once it's the current research, stop asking: re-queuing it every turn
        # would make the mod pick some other tech instead.
        research = p.get("research") or {}
        if (not _tech(p, "automation") and not research.get("triggers")
                and research.get("current") != "automation"):
            yield {"skill": "research", "tech": "automation"}, "automation unlocks assemblers", True
    elif goal_id == "smelting":
        bp_name = "tileable-smelter-stone"
        if bp_name in unlocked_bps and power.get("has_grid"):
            lib = blueprints.load_library()
            bp_entry = lib.get(bp_name, {})
            if bp_name not in placed_names:
                yield {"skill": "place_blueprint", "name": bp_name}, "stamp modular stone smelter column", True
            else:
                if (_rate(p, "iron-plate") < 30 or _rate(p, "copper-plate") < 15) and _count(p.get("ghosts")) == 0 and _rate(p, "iron-plate") > 0:
                    snap = blueprints.get_tile_target(placed_bps, bp_entry)
                    if snap:
                        yield ({"skill": "place_blueprint", "name": bp_name, "position": snap},
                               "tile modular stone smelter column for more plates", True)
                yield {"skill": "tend"}, "keep smelters fed with coal and ore", True
        elif _tech(p, "electric-mining-drill") and power.get("has_grid"):
            for ore, (plate, target) in SMELT_TARGET.items():
                # Pairs already built count at their full rate: the measured rate lags new builds.
                built = int((factory.get("electric_miners") or {}).get(ore, 0))
                deficit = target - max(_rate(p, plate), built * PAIR_PLATES_PER_MIN)
                pairs = -(-deficit // PAIR_PLATES_PER_MIN) if deficit > 0 else 0
                if pairs <= 0:
                    continue
                pairs = min(pairs, 2)
                yield from _goto_far(p, _landmark(p, ore), ore)
                yield from _craft(inv, "electric-mining-drill", pairs, f"{pairs} electric drill(s) for {ore}")
                yield from _craft(inv, "stone-furnace", pairs, f"{pairs} furnace(s) for {ore}")
                yield from _craft(inv, "inserter", pairs, f"{pairs} inserter(s) for {ore}")
                # drill=electric: fail instead of quietly building burner drills, which
                # never count as electric_miners and would re-fire this rule forever.
                yield ({"skill": "build_miner", "resource": ore, "output": "furnace", "count": pairs,
                        "drill": "electric"},
                       f"{plate} at {_rate(p, plate)}/min, want {target}", True)
    elif goal_id == "red":
        if _tech(p, "automation"):
            bp_name = "tileable-science-red"
            lab_bp = "tileable-labs"
            lib = blueprints.load_library()
            if lab_bp in unlocked_bps and power.get("has_grid"):
                lab_entry = lib.get(lab_bp, {})
                if lab_bp not in placed_names and _lab_count(p) < 2:
                    yield {"skill": "place_blueprint", "name": lab_bp}, "stamp modular tileable lab array", True
                elif lab_bp in placed_names and _lab_count(p) < 6 and _rate(p, "automation-science-pack") >= 10 and _count(p.get("ghosts")) == 0:
                    snap = blueprints.get_tile_target(placed_bps, lab_entry)
                    if snap:
                        yield ({"skill": "place_blueprint", "name": lab_bp, "position": snap},
                               "tile modular lab array for faster research", True)

            if bp_name in unlocked_bps:
                bp_entry = lib.get(bp_name, {})
                if bp_name not in placed_names:
                    yield {"skill": "place_blueprint", "name": bp_name}, "stamp modular red science unit", True
                elif _rate(p, "automation-science-pack") < 5 and _count(p.get("ghosts")) == 0 and _rate(p, "automation-science-pack") > 0:
                    snap = blueprints.get_tile_target(placed_bps, bp_entry)
                    if snap:
                        yield ({"skill": "place_blueprint", "name": bp_name, "position": snap},
                               "tile modular red science for higher output", True)

                # Connect belts between modular units if placed and not yet connected
                conns = p.get("connected_belts") or []
                red_pos = _find_placed(p, bp_name)
                smelt_pos = _find_placed(p, "tileable-smelter-stone")
                if smelt_pos and red_pos:
                    smelt_out = {"x": smelt_pos["x"] + 5.0, "y": smelt_pos["y"] + 0.5}
                    red_in = {"x": red_pos["x"] + 0.5, "y": red_pos["y"] + 5.5}
                    if not _is_connected(conns, smelt_out, red_in):
                        yield ({"skill": "connect_belt", "from": smelt_out, "to": red_in},
                               "connect smelter output belt to red science input belt", True)

                lab_pos = _find_placed(p, lab_bp)
                if red_pos and lab_pos:
                    red_out = {"x": red_pos["x"] + 6.0, "y": red_pos["y"] + 0.5}
                    lab_in = {"x": lab_pos["x"] + 0.5, "y": lab_pos["y"] + 0.5}
                    if not _is_connected(conns, red_out, lab_in):
                        yield ({"skill": "connect_belt", "from": red_out, "to": lab_in},
                               "connect red science output belt to lab input belt", True)

                yield {"skill": "tend"}, "haul plates into the cell and packs into the lab", True
            else:
                cells = [a for a in (factory.get("assemblers") or [])
                         if isinstance(a, dict) and a.get("recipe") == "automation-science-pack"]
                if not cells:
                    for item, n in (("assembling-machine-1", 3), ("inserter", 7), ("iron-chest", 4),
                                    ("small-electric-pole", 6)):
                        yield from _craft(inv, item, n, f"the red cell needs {n} {item}")
                    yield {"skill": "build_red_cell"}, "automate red science", True
                yield {"skill": "tend"}, "haul plates into the cell and packs into the lab", True
    elif goal_id == "green":
        if _tech(p, "logistic-science-pack"):
            bp_name = "tileable-science-green"
            if bp_name in unlocked_bps:
                lib = blueprints.load_library()
                bp_entry = lib.get(bp_name, {})
                if bp_name not in placed_names:
                    yield {"skill": "place_blueprint", "name": bp_name}, "stamp modular green science unit", True
                elif _rate(p, "logistic-science-pack") < 5 and _count(p.get("ghosts")) == 0:
                    snap = blueprints.get_tile_target(placed_bps, bp_entry)
                    if snap and _rate(p, "logistic-science-pack") > 0:
                        yield ({"skill": "place_blueprint", "name": bp_name, "position": snap},
                               "tile modular green science for higher output", True)

                # Connect belts: smelter -> green science, and green science -> lab bus (side-load)
                conns = p.get("connected_belts") or []
                green_pos = _find_placed(p, bp_name)
                smelt_pos = _find_placed(p, "tileable-smelter-stone")
                if smelt_pos and green_pos:
                    smelt_out = {"x": smelt_pos["x"] + 5.0, "y": smelt_pos["y"] + 0.5}
                    green_in = {"x": green_pos["x"] + 0.5, "y": green_pos["y"] + 5.5}
                    if not _is_connected(conns, smelt_out, green_in):
                        yield ({"skill": "connect_belt", "from": smelt_out, "to": green_in},
                               "connect smelter output belt to green science input belt", True)

                lab_pos = _find_placed(p, "tileable-labs")
                if green_pos and lab_pos:
                    green_out = {"x": green_pos["x"] + 6.0, "y": green_pos["y"] + 0.5}
                    lab_side_in = {"x": lab_pos["x"] + 1.5, "y": lab_pos["y"] + 0.5}
                    if not _is_connected(conns, green_out, lab_side_in):
                        yield ({"skill": "connect_belt", "from": green_out, "to": lab_side_in},
                               "side-load green science onto lab dual-science bus", True)

                yield {"skill": "tend"}, "haul plates and intermediates through the green cell, packs to the labs", True
            else:
                have = [a.get("recipe") for a in (factory.get("assemblers") or []) if isinstance(a, dict)]
                missing = []
                for recipe in GREEN_UNITS:
                    if recipe in have:
                        have.remove(recipe)
                    else:
                        missing.append(recipe)
                if missing:
                    if inv.get("iron-plate", 0) < 60:
                        yield {"skill": "tend"}, "collect plates for the green-science parts", True
                    n = min(3, len(missing))
                    yield from _craft(inv, "assembling-machine-1", n, f"{n} more green-science unit(s) need assemblers")
                    yield from _craft(inv, "inserter", 2 * n, f"{n} more green-science unit(s) need inserters")
                    yield {"skill": "build_green_cell"}, f"{len(missing)} green-science unit(s) still to build", True
                yield {"skill": "tend"}, "haul plates and intermediates through the green cell, packs to the labs", True
    elif goal_id == "steel":
        if _tech(p, "steel-processing"):
            bp_name = "tileable-steel"
            if bp_name in unlocked_bps:
                lib = blueprints.load_library()
                bp_entry = lib.get(bp_name, {})
                if bp_name not in placed_names:
                    yield {"skill": "place_blueprint", "name": bp_name}, "stamp modular steel smelter column", True
                elif _rate(p, "steel-plate") < 5 and _count(p.get("ghosts")) == 0:
                    snap = blueprints.get_tile_target(placed_bps, bp_entry)
                    if snap and _rate(p, "steel-plate") > 0:
                        yield ({"skill": "place_blueprint", "name": bp_name, "position": snap},
                               "tile modular steel column for more steel output", True)

                # Connect belts: smelter iron plate output -> steel smelter input
                conns = p.get("connected_belts") or []
                steel_pos = _find_placed(p, bp_name)
                smelt_pos = _find_placed(p, "tileable-smelter-stone")
                if smelt_pos and steel_pos:
                    smelt_out = {"x": smelt_pos["x"] + 5.0, "y": smelt_pos["y"] + 0.5}
                    steel_in = {"x": steel_pos["x"] + 0.5, "y": steel_pos["y"] + 5.5}
                    if not _is_connected(conns, smelt_out, steel_in):
                        yield ({"skill": "connect_belt", "from": smelt_out, "to": steel_in},
                               "connect iron plate belt to steel smelter input belt", True)

                yield {"skill": "tend"}, "keep steel smelters fueled and fed with iron plates", True
    elif goal_id == "oil":
        if _tech(p, "oil-processing"):
            crude = _landmark(p, "crude-oil")
            if not crude and _by_type(p, "radar") == 0:
                yield {"skill": "build_radar"}, "survey surrounding territory to locate crude oil", True
            if _by_type(p, "pumpjack") == 0:
                if crude and crude.get("distance", 0) > FAR:
                    yield ({"skill": "goto", "position": {"x": crude["x"], "y": crude["y"]}},
                           f"crude oil is {crude['distance']} tiles away", True)
                yield {"skill": "build_pumpjack"}, "extract crude oil with a pumpjack", True
            bp_name = "tileable-oil-basic"
            if bp_name in unlocked_bps and _by_type(p, "oil-refinery") == 0:
                yield {"skill": "place_blueprint", "name": bp_name}, "stamp modular basic oil refinery", True
            pipes = p.get("connected_pipes") or []
            ref_pos = _find_placed(p, bp_name)
            if ref_pos and crude:
                crude_pt = {"x": crude["x"], "y": crude["y"]}
                ref_in = {"x": ref_pos["x"] + 2.0, "y": ref_pos["y"]}
                if not _is_connected(pipes, crude_pt, ref_in):
                    yield ({"skill": "connect_pipe", "from": crude_pt, "to": ref_in},
                           "pipe crude oil from pumpjack to refinery", True)
            yield {"skill": "tend"}, "maintain power and upkeep around oil operations", True
    elif goal_id == "plastic":
        if _tech(p, "plastics"):
            plas_bp = "tileable-plastic"
            if plas_bp in unlocked_bps and plas_bp not in placed_names:
                yield {"skill": "place_blueprint", "name": plas_bp}, "stamp modular plastic plant", True
            sulf_bp = "tileable-sulfur"
            if _tech(p, "sulfur-processing") and sulf_bp in unlocked_bps and sulf_bp not in placed_names:
                yield {"skill": "place_blueprint", "name": sulf_bp}, "stamp modular sulfur plant", True

            pipes = p.get("connected_pipes") or []
            conns = p.get("connected_belts") or []
            ref_pos = _find_placed(p, "tileable-oil-basic")
            plas_pos = _find_placed(p, plas_bp)
            if ref_pos and plas_pos:
                petro_out = {"x": ref_pos["x"] + 3.0, "y": ref_pos["y"] + 6.0}
                plas_petro_in = {"x": plas_pos["x"] + 1.5, "y": plas_pos["y"] + 0.5}
                if not _is_connected(pipes, petro_out, plas_petro_in):
                    yield ({"skill": "connect_pipe", "from": petro_out, "to": plas_petro_in},
                           "pipe petroleum gas from refinery to plastic plant", True)

            coal_lm = _landmark(p, "coal")
            if coal_lm and plas_pos:
                coal_pt = {"x": coal_lm["x"], "y": coal_lm["y"]}
                plas_coal_in = {"x": plas_pos["x"] - 0.5, "y": plas_pos["y"] + 2.5}
                if not _is_connected(conns, coal_pt, plas_coal_in):
                    yield ({"skill": "connect_belt", "from": coal_pt, "to": plas_coal_in},
                           "belt coal into plastic plant", True)

            sulf_pos = _find_placed(p, sulf_bp)
            if ref_pos and sulf_pos:
                petro_out = {"x": ref_pos["x"] + 3.0, "y": ref_pos["y"] + 6.0}
                sulf_petro_in = {"x": sulf_pos["x"] + 1.5, "y": sulf_pos["y"] + 0.5}
                if not _is_connected(pipes, petro_out, sulf_petro_in):
                    yield ({"skill": "connect_pipe", "from": petro_out, "to": sulf_petro_in},
                           "pipe petroleum gas to sulfur plant", True)
            water = (p.get("landmarks") or {}).get("water")
            if water and sulf_pos:
                water_pt = {"x": water["x"], "y": water["y"]}
                sulf_water_in = {"x": sulf_pos["x"] + 3.5, "y": sulf_pos["y"] + 0.5}
                if not _is_connected(pipes, water_pt, sulf_water_in):
                    yield ({"skill": "connect_pipe", "from": water_pt, "to": sulf_water_in},
                           "pipe water to sulfur plant", True)

            yield {"skill": "tend"}, "maintain chemical plants and petrochemical feeds", True


def _candidates(p: dict, blocked=frozenset()) -> Iterator[tuple[dict, str, bool]]:
    inv = _inv(p)
    factory = p.get("factory") or {}
    needs = p.get("needs") or {}
    research = p.get("research") or {}

    # 0. The player's own intent first (ghosts, deconstruction marks).
    if _count(p.get("ghosts")) > 0:
        yield {"skill": "build_ghosts"}, "the player placed ghosts", True
        ghost_list = (p.get("ghosts") if isinstance(p.get("ghosts"), dict) else {}).get("list") or []
        needed: dict[str, int] = {}
        for g in ghost_list:
            gname = g.get("ghost_name")
            if gname and not g.get("have_item"):
                item = _ENTITY_ITEM.get(gname, gname)
                needed[item] = needed.get(item, 0) + 1
        for item, count in sorted(needed.items()):
            if inv.get(item, 0) < count:
                yield {"skill": "craft_for", "item": item, "count": count}, f"craft {count} {item} for blueprint ghosts", True
    if _count(p.get("deconstruction")) > 0:
        yield {"skill": "deconstruct"}, "the player marked things for removal", True

    # 1. Keep the burner base running. With the mod's reflexes on, refuelling and emptying
    # furnaces/chests happen on their own; tend stays for what they don't do (a drill spilling
    # onto the ground needs a collector placed).
    reflexes = _reflexes(p)
    drops = ("ground",) if reflexes else ("ground", "container", "furnace")
    stalled = [n for n in needs.get("outputs_full") or [] if n.get("drop") in drops]
    power = p.get("power") or {}
    unpowered_machines = power.get("machines_no_power", 0)
    has_boiler = _by_type(p, "boiler") > 0
    burners_val = needs.get("burners_low_fuel")
    boiler_needs_fuel = False
    if isinstance(burners_val, list):
        boiler_needs_fuel = any(isinstance(b, dict) and b.get("name") == "boiler" for b in burners_val)
    elif isinstance(burners_val, int) and burners_val > 0 and has_boiler:
        boiler_needs_fuel = True

    if inv.get("coal", 0) < (20 if has_boiler else 5):
        if (factory.get("miners_by_resource") or {}).get("coal") and not reflexes:
            yield {"skill": "tend"}, "low on coal — collect it from the coal drill's chest", True
        yield from _goto_far(p, _landmark(p, "coal"), "coal", GATHER_NEAR)
        yield {"skill": "gather", "item": "coal", "count": 50}, "low on coal", True

    if unpowered_machines > 0 or boiler_needs_fuel:
        yield {"skill": "tend"}, "power needs attention: boilers need fuel or machines need wiring", True
    elif (needs.get("burners_low_fuel") and not reflexes) or stalled:
        yield {"skill": "tend"}, "burners need fuel or drills/furnaces need emptying", True

    # 1b. Enemies near home or an attack on the AI's things: gun turrets with ammo.
    threat = p.get("threat") or {}
    nest = threat.get("nearest") or {}
    attack = threat.get("attack") or {}
    attacked_power = attack.get("name") in ("boiler", "steam-engine", "offshore-pump")
    if (nest and nest.get("distance", 1e9) <= DEFENSE_RANGE) or threat.get("attack"):
        if _by_type(p, "ammo-turret") < DEFENSE_TURRETS:
            if not _tech(p, "gun-turret"):
                if research.get("current") != "gun-turret" and _lab_count(p):
                    yield {"skill": "research", "tech": "gun-turret"}, "enemies are near: gun turrets need research", True
            else:
                need = DEFENSE_TURRETS - _by_type(p, "ammo-turret")
                yield from _craft(inv, "gun-turret", need, f"{need} gun turret(s) against the nearby enemies")
                ammo_item = "piercing-rounds-magazine" if _tech(p, "military-2") else "firearm-magazine"
                yield from _craft(inv, ammo_item, 10 * need, f"{ammo_item} for the turrets")
                defense_entry = {"skill": "build_defense", "count": DEFENSE_TURRETS}
                if attacked_power:
                    defense_entry["site"] = "power"
                yield defense_entry, f"enemies near {'power' if attacked_power else 'home'}: turrets toward them", True

    # 2. Burner bootstrap: drills on coal, iron, copper, stone.
    cur = goals.current(p)
    goal_id = cur[1].id if cur else ""
    if goal_id == "bootstrap":
        miners = factory.get("miners_by_resource") or {}
        for resource, want, output in BOOTSTRAP:
            if miners.get(resource, 0) >= want:
                continue
            lm = _landmark(p, resource)
            if lm and lm.get("distance", 0) > FAR:
                yield ({"skill": "goto", "position": {"x": lm["x"], "y": lm["y"]}},
                       f"nearest {resource} is {lm['distance']} tiles away", True)
            missing = want - miners.get(resource, 0)
            if inv.get("burner-mining-drill", 0) == 0:
                # One turn: collect plates, craft drills, build once they're done.
                yield {"skill": "tend"}, "collect plates for crafting drills", True
                yield ({"skill": "craft_for", "item": "burner-mining-drill", "count": missing},
                       f"need {missing} drill(s) for {resource}", True)
            yield ({"skill": "build_miner", "resource": resource, "output": output, "count": missing},
                   f"{miners.get(resource, 0)}/{want} drill(s) on {resource}", True)
            if inv.get("burner-mining-drill", 0) == 0:
                yield from _goto_far(p, _landmark(p, "stone"), "stone", GATHER_NEAR)
                yield ({"skill": "gather", "item": "stone", "count": 20},
                       "drills and furnaces need stone", True)
        yield {"skill": "tend"}, "keep the drills and furnaces fed while iron output builds up", True
    elif goal_id:
        yield from _late_game(p, inv, factory, goal_id)

    # 3. Techs unlocked by doing something (2.x early game). Guesses.
    for t in research.get("triggers") or []:
        target, n = t.get("target"), int(t.get("count") or 1)
        if not target:
            continue
        if t.get("type") == "craft-item" and str(target).endswith(("-plate", "-brick")):
            continue                # made by furnaces, not by hand: the base's smelting covers these
        if t.get("type") == "craft-item":
            yield ({"skill": "craft_for", "item": target, "count": inv.get(target, 0) + n},
                   f"crafting {n} new {target} unlocks {t.get('tech')}", False)
        elif t.get("type") == "mine-entity":
            first = str(target).split("/")[0]
            yield ({"skill": "gather", "item": first, "count": n},
                   f"mining {first} unlocks {t.get('tech')}", False)

    # 4. Research and labs.
    labs = _labs(p)
    if not research.get("current"):
        # Only with a lab standing: queuing earlier would just sit there. Trigger techs
        # (research.triggers) can't be queued; the loop above is how those get unlocked.
        pending = {t.get("tech") for t in research.get("triggers") or []}
        queued = False
        if _lab_count(p):
            for tech, needs_green in research_order(p):
                if _tech(p, tech) or tech in pending or (needs_green and not _rate(p, "logistic-science-pack")):
                    continue
                entry = {"skill": "research", "tech": tech}
                if entry_key(entry) in blocked:
                    continue                # failed twice: take the next tech instead
                yield entry, f"nothing is being researched — {tech} is next", True
                queued = True
                break
        if not queued and goal_id != "automation":
            yield {"skill": "research"}, "nothing is being researched", False
    if not _lab_count(p) and inv.get("lab", 0) > 0 and (p.get("home") or {}).get("position"):
        home = p["home"]["position"]
        yield ({"action": "place", "item": "lab", "position": {"x": home["x"] + 4, "y": home["y"] + 4}},
               "place the lab near home", True)
    if research.get("current") and (factory.get("labs") or {}).get("without_packs") and labs:
        cell = any(isinstance(a, dict) and a.get("recipe") == "automation-science-pack"
                   for a in factory.get("assemblers") or [])
        if inv.get("automation-science-pack", 0) > 0:
            yield ({"action": "insert", "item": "automation-science-pack",
                    "count": inv["automation-science-pack"], "position": labs[0]["position"],
                    "inventory": "lab"}, "a lab has no science packs", True)
        elif cell:
            yield {"skill": "tend"}, "the red cell makes the packs: haul plates into it", True
        else:
            if inv.get("iron-plate", 0) < 20 or inv.get("copper-plate", 0) < 10:
                yield {"skill": "tend"}, "collect plates for hand-crafting science packs", True
            yield ({"skill": "craft_for", "item": "automation-science-pack", "count": 10},
                   "labs need science packs", True)


MAX_MOVES = 4  # the schema allows 4 entries per reply


def next_plan(p: dict, blocked: frozenset[str] | set[str] = frozenset(),
              limit: int = MAX_MOVES) -> list[tuple[dict, str, bool]]:
    """The first `limit` distinct, unblocked moves as (entry, reason, sure)."""
    out, keys = [], set()
    has_tend = False
    for entry, reason, sure in _candidates(p, blocked):
        k = entry_key(entry)
        if k in blocked or k in keys:
            continue
        # If tend is already in this plan batch, suppress redundant manual pack insert
        if has_tend and entry.get("action") == "insert" and str(entry.get("item", "")).endswith("-science-pack"):
            continue
        keys.add(k)
        if entry.get("skill") == "tend":
            has_tend = True
        out.append((entry, reason, sure))
        if len(out) >= limit:
            break
    return out


def next_steps(p: dict, blocked: frozenset[str] | set[str] = frozenset(),
               limit: int = MAX_MOVES) -> list[tuple[dict, str]]:
    """The first `limit` distinct, unblocked moves, in order."""
    return [(e, r) for e, r, _ in next_plan(p, blocked, limit)]


def next_step(p: dict, blocked: frozenset[str] | set[str] = frozenset()) -> tuple[dict, str] | None:
    steps = next_steps(p, blocked, 1)
    return steps[0] if steps else None


def sure_prefix(plan: list[tuple[dict, str, bool]]) -> list[tuple[dict, str]]:
    """The leading run of sure moves (what the autopilot may send unasked)."""
    out = []
    for entry, reason, sure in plan:
        if not sure:
            break
        out.append((entry, reason))
    return out
