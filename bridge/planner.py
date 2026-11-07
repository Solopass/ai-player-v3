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

import math
from typing import Iterator

from . import blueprints, goals
from .blueprints import _ENTITY_ITEM
from .goals import demand_targets      # one copy of the plate targets, shared with the ladder

# Electric pair (drill -> stone furnace) yield, plates/min: the furnace is the limit.
PAIR_PLATES_PER_MIN = 18
FURNACE_PLATES_PER_MIN = 18.75         # a stone furnace; a field makes this much per furnace
FIELD_MAX_FURNACES = 6                 # build_miner caps count at 6
FIELD_GATE = 0.8                       # science blocks start at >= 80% of the plate targets
FIELD_DEPLETED_PCT = 20                # a field's patch below this -> build a replacement


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
    ("automation", False), ("electric-mining-drill", False),
    ("logistics", False), ("electronics", False),
    ("logistic-science-pack", False), ("steel-processing", False),
    ("automation-2", True), ("fast-inserter", True),
    ("gun-turret", False), ("military", False), ("stone-wall", False),
    ("physical-projectile-damage-1", False), ("weapon-shooting-speed-1", False),
    ("engine", True), ("electric-energy-distribution-1", True),
    ("toolbelt", True), ("advanced-material-processing", True),
    ("oil-processing", True), ("plastics", True), ("advanced-circuit", True),
    ("sulfur-processing", True), ("chemical-science-pack", True),
    ("robotics", True), ("construction-robotics", True),
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
    for k in ("item", "tech", "resource", "recipe", "name", "ore", "output", "count",
              "from_bp", "from_port", "to_bp", "to_port"):
        # build_miner's count shrinks as drills get built; the move is the same.
        if k == "count" and name == "skill:build_miner":
            continue
        if d.get(k) is not None:
            parts.append(f"{k}={d[k]}")
    if "from" in d and "to" in d and isinstance(d["from"], dict) and isinstance(d["to"], dict):
        parts.append(f"from={d['from'].get('x')},{d['from'].get('y')};to={d['to'].get('x')},{d['to'].get('y')}")
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
    if resource == "water":
        return (p.get("landmarks") or {}).get("water")
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
    if out:
        return out
    threat = p.get("threat") or {}
    near = (threat.get("nearest") or {}).get("distance")
    atk = threat.get("attack") or {}
    has_threat = (near is not None and near <= 150) or (atk and atk.get("seconds_ago", 9999) <= 600)
    if has_threat:
        mil_names = {"gun-turret", "military", "stone-wall", "physical-projectile-damage-1", "weapon-shooting-speed-1"}
        mil = [t for t in RESEARCH_ORDER if t[0] in mil_names]
        other = [t for t in RESEARCH_ORDER if t[0] not in mil_names]
        return mil + other
    return RESEARCH_ORDER


def _reflexes(p: dict) -> bool:
    """True when the mod's reflexes are on: they refuel, empty full furnaces/chests and reload
    turrets by themselves, so the planner doesn't spend moves on those."""
    return bool((p.get("reflex") or {}).get("enabled"))


def _tech(p: dict, name: str) -> bool:
    return name in ((p.get("research") or {}).get("done") or [])


def _ammo_per_turret(p: dict) -> float:
    factory = p.get("factory") or {}
    turret_count = _by_type(p, "ammo-turret")
    if turret_count == 0:
        return 0.0
    by_status = factory.get("by_status") or {}
    if by_status.get("no_ammo", 0) > 0:
        return 0.0
    machines = factory.get("machines") or []
    ammo_total = 0
    found_turrets = 0
    for m in machines:
        if m.get("type") == "ammo-turret":
            found_turrets += 1
            contents = m.get("contents") or {}
            ammo_total += sum(int(v) for v in contents.values())
    if found_turrets > 0:
        return ammo_total / found_turrets
    attention = factory.get("attention") or []
    for a in attention:
        if a.get("type") == "ammo-turret":
            return 0.0
    return 10.0


def _rate(p: dict, item: str) -> int:
    return int((((p.get("production") or {}).get("items") or {}).get(item) or {}).get("per_min", 0))


def _plate_estimate(p: dict, factory: dict, ore: str, plate: str) -> float:
    """Plates/min the base makes of `plate`: the measured rate, or what the electric drills
    already built will make (the measurement lags new builds)."""
    built = int((factory.get("electric_miners") or {}).get(ore, 0))
    return max(_rate(p, plate), built * PAIR_PLATES_PER_MIN)


def _plates_ready(p: dict, factory: dict, field_ores: set) -> bool:
    """True unless a plate is under 80% of its target AND a mining field for it was queued this
    turn, so a new science block waits for the field instead of starving the smelting. Uses the
    built-drill estimate, like _field_moves: when no field can be offered (target met by built
    drills, or the field move is blocked), science never waits on plates it can't get."""
    for ore, (plate, target) in demand_targets(p).items():
        if ore in field_ores and _plate_estimate(p, factory, ore, plate) < FIELD_GATE * target:
            return False
    return True


def _field_moves(p: dict, inv: dict, factory: dict, blocked) -> Iterator[tuple[dict, str, bool]]:
    """Electric mining fields (build_miner output=field: drills + coal + smelting column), right
    after power: a replacement when the patch under every field of an ore is nearly gone, else the
    plate furthest below its target gets the next field."""
    power = p.get("power") or {}
    if not (_tech(p, "electric-mining-drill") and power.get("has_grid")):
        return
    fields = [f for f in (p.get("fields") or []) if isinstance(f, dict)]
    pick = None                                # (ore, furnaces, why)
    for ore in ("iron-ore", "copper-ore"):
        mine = [f for f in fields if f.get("resource") == ore]
        if mine and all(int(f.get("remaining_pct", 100)) < FIELD_DEPLETED_PCT for f in mine):
            furnaces = max(int(f.get("furnaces") or 1) for f in mine)
            pct = min(int(f.get("remaining_pct", 0)) for f in mine)
            pick = (ore, furnaces, f"the {ore} field is down to {pct}% of its patch: build a replacement")
            break
    if pick is None:
        worst = None
        for ore, (plate, target) in demand_targets(p).items():
            have = _plate_estimate(p, factory, ore, plate)
            if have >= target:
                continue
            ratio = have / target
            if worst is None or ratio < worst[0]:
                worst = (ratio, ore, plate, target, have)
        if worst is None:
            return
        _, ore, plate, target, have = worst
        furnaces = math.ceil((target - have) / FURNACE_PLATES_PER_MIN)
        pick = (ore, furnaces, f"{plate} at {have:.0f}/min, want {target:.0f}: next mining field")
    ore, furnaces, why = pick
    furnaces = max(1, min(FIELD_MAX_FURNACES, furnaces))
    entry = {"skill": "build_miner", "resource": ore, "output": "field", "count": furnaces}
    if entry_key(entry) in blocked:
        return                                 # failed twice: the pair rule below takes over
    drills = math.ceil(furnaces * FURNACE_PLATES_PER_MIN / 30) + max(1, math.ceil(furnaces / 8))
    yield from _goto_far(p, _landmark(p, ore), ore)
    yield from _craft(inv, "electric-mining-drill", drills, f"{drills} electric drills for the {ore} field")
    yield from _craft(inv, "stone-furnace", furnaces, f"{furnaces} furnace(s) for the {ore} field")
    yield from _craft(inv, "inserter", 2 * furnaces, f"{2 * furnaces} inserters for the {ore} field")
    yield entry, why, True


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


PORT_LINKS: dict[tuple[str, str], tuple[str, str]] = {
    ("tileable-smelter-stone", "out2"): ("tileable-science-red", "in1"),
    ("tileable-science-red", "out2"): ("tileable-labs", "in1"),
    ("tileable-smelter-stone", "out2"): ("tileable-science-green", "in1"),
    ("tileable-science-green", "out2"): ("tileable-labs", "in1"),
    ("tileable-smelter-stone", "out2"): ("tileable-steel", "in2"),
    ("tileable-steel", "out2"): ("tileable-engine", "in1"),
    ("tileable-plastic", "out1"): ("tileable-red-circuits", "in1"),
    ("tileable-engine", "out1"): ("tileable-science-blue", "in1"),
    ("tileable-science-blue", "out1"): ("tileable-labs", "in1"),
}


def _is_ports_connected(connected: list[dict], from_bp: str, from_port: str, to_bp: str, to_port: str) -> bool:
    for c in connected or []:
        if c.get("from_bp") == from_bp and c.get("from_port") == from_port and c.get("to_bp") == to_bp and c.get("to_port") == to_port:
            return True
        if c.get("from_bp") == to_bp and c.get("from_port") == to_port and c.get("to_bp") == from_bp and c.get("to_port") == from_port:
            return True
    return False


def _get_bp_port(placed_blueprints: list[dict], bp_name: str, port_name: str) -> dict | None:
    for bp in reversed(placed_blueprints or []):
        if isinstance(bp, dict) and bp.get("name") == bp_name:
            for port in bp.get("ports") or []:
                if port.get("name") == port_name:
                    return port
    return None


def _is_connected(connected: list[dict], pt1: dict, pt2: dict) -> bool:
    for c in connected:
        f = c.get("from") or {}
        t = c.get("to") or {}
        if (abs(f.get("x", 0) - pt1["x"]) < 1.5 and abs(f.get("y", 0) - pt1["y"]) < 1.5
           and abs(t.get("x", 0) - pt2["x"]) < 1.5 and abs(t.get("y", 0) - pt2["y"]) < 1.5) or \
           (abs(f.get("x", 0) - pt2["x"]) < 1.5 and abs(f.get("y", 0) - pt2["y"]) < 1.5
           and abs(t.get("x", 0) - pt1["x"]) < 1.5 and abs(t.get("y", 0) - pt1["y"]) < 1.5):
            return True
    return False


def _expand_electric_mining(p: dict, inv: dict, factory: dict, min_targets: dict[str, int]) -> Iterator[tuple[dict, str, bool]]:
    """Ensure sufficient electric mining drill throughput on key resource patches."""
    power = p.get("power") or {}
    if not (_tech(p, "electric-mining-drill") and power.get("has_grid")):
        return
    elec_miners = factory.get("electric_miners") or {}
    for ore, target_count in min_targets.items():
        current_drills = int(elec_miners.get(ore, 0))
        if current_drills < target_count:
            missing = min(2, target_count - current_drills)
            lm = _landmark(p, ore)
            if lm and lm.get("distance", 0) > FAR:
                yield from _goto_far(p, lm, ore, FAR)
            yield from _craft(inv, "electric-mining-drill", missing, f"{missing} electric drill(s) for {ore}")
            out_type = "furnace" if ore in ("iron-ore", "copper-ore") else "chest"
            if out_type == "furnace":
                yield from _craft(inv, "stone-furnace", missing, f"{missing} furnace(s) for {ore}")
                yield from _craft(inv, "inserter", missing, f"{missing} inserter(s) for {ore}")
            else:
                yield from _craft(inv, "wooden-chest", missing, f"{missing} chest(s) for {ore}")
            yield from _craft(inv, "small-electric-pole", 4, "poles to wire electric drill to grid")
            yield ({"skill": "build_miner", "resource": ore, "output": out_type, "count": missing,
                    "drill": "electric"},
                   f"expand electric mining: {current_drills}/{target_count} on {ore}", True)
            break


def _late_game(p: dict, inv: dict, factory: dict, goal_id: str,
               blocked=frozenset()) -> Iterator[tuple[dict, str, bool]]:
    """Build-order rules past the bootstrap: power, automation, smelting, red cell, green cell."""
    power = p.get("power") or {}
    unlocked_bps = set(p.get("blueprint_library") or [])
    placed_bps = p.get("placed_blueprints") or []
    placed_names = {b.get("name") for b in placed_bps if isinstance(b, dict)}

    # If power is missing or destroyed at any point in the game, restore power first
    if not power.get("has_grid") or not _by_type(p, "boiler"):
        water_lm = (p.get("landmarks") or {}).get("water")
        yield from _goto_far(p, water_lm, "water", WATER_NEAR)

        # Split: Build offshore pump and lead pipes first if no pump exists
        if _by_type(p, "offshore-pump") == 0:
            yield from _craft(inv, "offshore-pump", 1, "steam power needs an offshore pump")
            yield from _craft(inv, "pipe", 4, "lead pipes from shoreline onto land")
            yield {"skill": "build_offshore_pump"}, "place offshore pump on shoreline and lay water supply pipes", True

        for item, n in (("boiler", 1), ("steam-engine", 2), ("pipe", 8),
                        ("small-electric-pole", 8)):
            yield from _craft(inv, item, n, f"steam power needs {n} {item}")
        yield {"skill": "build_power"}, "connect boiler and steam engines to water supply pipes", True

    # Automated coal feeding to steam power: connect coal source to boiler fuel input
    power_bp = "tileable-steam-power"
    power_pos = _find_placed(p, power_bp)
    if _by_type(p, "boiler") >= 1:
        fuel_in = power.get("fuel_in_position")
        if not fuel_in:
            power_in = _get_bp_port(placed_bps, power_bp, "in1")
            if power_in:
                fuel_in = {"x": power_in["x"], "y": power_in["y"]}
            elif power_pos:
                fuel_in = {"x": power_pos["x"] + 0.5, "y": power_pos["y"] + 0.5}

        conns = p.get("connected_belts") or []
        boiler_fuel_connected = power.get("boiler_fuel_connected") or (
            fuel_in and any(
                (abs(c.get("to", {}).get("x", 0) - fuel_in["x"]) < 1.5 and abs(c.get("to", {}).get("y", 0) - fuel_in["y"]) < 1.5)
                for c in conns
            )
        )

        if fuel_in and not boiler_fuel_connected:
            miner_positions = factory.get("miner_positions") or {}
            coal_drills = miner_positions.get("coal") or []
            coal_src = coal_drills[0].get("drop_position") if coal_drills else None
            coal_miners_count = int((factory.get("miners_by_resource") or {}).get("coal", 0))

            if not coal_src and coal_miners_count == 0:
                coal_lm = _landmark(p, "coal")
                if _tech(p, "electric-mining-drill") and power.get("has_grid"):
                    yield from _craft(inv, "electric-mining-drill", 1, "drill to feed coal onto steam power fuel belt")
                    yield from _craft(inv, "small-electric-pole", 2, "poles to wire coal drill")
                    yield ({"skill": "build_miner", "resource": "coal", "output": "belt", "drill": "electric", "count": 1},
                           "place electric miner on coal to power boilers", True)
                elif coal_lm:
                    yield from _craft(inv, "burner-mining-drill", 1, "drill to feed coal onto steam power fuel belt")
                    yield ({"skill": "build_miner", "resource": "coal", "output": "chest", "count": 1},
                           "place drill on coal to feed boilers", True)

            if not coal_src:
                coal_lm = _landmark(p, "coal")
                if coal_lm:
                    coal_src = {"x": coal_lm["x"], "y": coal_lm["y"]}

            if coal_src and not _is_connected(conns, coal_src, fuel_in):
                dx = abs(coal_src["x"] - fuel_in["x"])
                dy = abs(coal_src["y"] - fuel_in["y"])
                needed = min(int(dx + dy + 10), 60)
                yield from _craft(inv, "transport-belt", needed, "belts to connect coal to boilers")
                yield ({"skill": "connect_belt", "from": coal_src, "to": fuel_in},
                       "feed automated coal belt to boilers", True)

        # Self-healing: wire unpowered machines back to the power grid
        unpowered_pos = power.get("unpowered_positions") or factory.get("unpowered_positions") or []
        if unpowered_pos and power.get("has_grid"):
            up = unpowered_pos[0]
            yield from _craft(inv, "small-electric-pole", 4, "craft poles to wire unpowered machines")
            yield ({"skill": "connect_power", "to": {"x": up["x"], "y": up["y"]}},
                   f"wire unpowered machine at {{{up['x']},{up['y']}}} to electric grid", True)

    # Scale modular steam power when consumption approaches generation capacity or machines lack power
    prod_kw = power.get("production_kw", 0)
    cons_kw = power.get("consumption_kw", 0)
    if power_bp in unlocked_bps and _by_type(p, "boiler") >= 1:
        if (cons_kw >= prod_kw * 0.75 and cons_kw > 400) or power.get("machines_low_power", 0) > 0:
            if _count(p.get("ghosts")) == 0 and _by_type(p, "boiler") < 10:
                lib = blueprints.load_library()
                bp_entry = lib.get(power_bp, {})
                snap = blueprints.get_tile_target(placed_bps, bp_entry)
                if snap:
                    yield ({"skill": "place_blueprint", "name": power_bp, "position": snap},
                           "scale modular steam power: electric demand is near capacity", True)
                elif power_bp not in placed_names:
                    yield ({"skill": "place_blueprint", "name": power_bp},
                           "stamp modular steam power unit along shoreline", True)

        # Connect steam power to water pipes with an offshore pump
        pipes = p.get("connected_pipes") or []
        water_lm = _landmark(p, "water")
        machines = p.get("factory", {}).get("machines") or []
        pump_pos = None
        for op in (p.get("factory") or {}).get("offshore_pumps") or []:
            if isinstance(op, dict) and op.get("position"):
                pump_pos = op["position"]
                break
        if not pump_pos:
            for m in machines:
                if m.get("type") == "offshore-pump" or m.get("name") == "offshore-pump":
                    pump_pos = m.get("position")
                    break
        if not pump_pos:
            for e in (p.get("nearby_entities") or []):
                if e.get("name") == "offshore-pump":
                    pump_pos = e.get("position")
                    break

        if power_pos and _by_type(p, "offshore-pump") == 0 and not pump_pos:
            yield from _craft(inv, "offshore-pump", 1, "steam power needs an offshore pump")
            if water_lm and water_lm.get("distance", 0) > WATER_NEAR:
                yield from _goto_far(p, water_lm, "water", WATER_NEAR)
            yield {"skill": "build_offshore_pump"}, "place offshore pump on shoreline for steam power", True

        if power_pos:
            power_pipe = _get_bp_port(placed_bps, power_bp, "pipe1")
            power_water_in = {"x": power_pipe["x"], "y": power_pipe["y"]} if power_pipe else {"x": power_pos["x"] + 0.5, "y": power_pos["y"] + 3.0}
            src_pt = pump_pos or ({"x": water_lm["x"], "y": water_lm["y"]} if water_lm else None)
            if src_pt and not _is_connected(pipes, src_pt, power_water_in):
                yield from _craft(inv, "pipe", 15, "pipes to connect offshore pump to steam power")
                yield ({"skill": "connect_pipe", "from": src_pt, "to": power_water_in},
                       "connect steam power to water pipes with an offshore pump", True)

    # Check for unwatered boilers (dry boilers needing water pipe from offshore pump)
    machines = p.get("factory", {}).get("machines") or []
    unwatered = next((m for m in machines if (m.get("type") == "boiler" or m.get("name") == "boiler")
                      and m.get("status") in ("no_input_fluid", "low_input_fluid")), None)
    if unwatered:
        pipes = p.get("connected_pipes") or []
        water_lm = _landmark(p, "water")
        pump_pos = None
        for op in (p.get("factory") or {}).get("offshore_pumps") or []:
            if isinstance(op, dict) and op.get("position"):
                pump_pos = op["position"]
                break
        if not pump_pos:
            for m in machines:
                if m.get("type") == "offshore-pump" or m.get("name") == "offshore-pump":
                    pump_pos = m.get("position")
                    break
        if not pump_pos:
            for e in (p.get("nearby_entities") or []):
                if e.get("name") == "offshore-pump":
                    pump_pos = e.get("position")
                    break
        if _by_type(p, "offshore-pump") == 0 and not pump_pos:
            yield from _craft(inv, "offshore-pump", 1, "boiler missing water: craft offshore pump")
            if water_lm and water_lm.get("distance", 0) > WATER_NEAR:
                yield from _goto_far(p, water_lm, "water", WATER_NEAR)
            yield {"skill": "build_offshore_pump"}, "place offshore pump on shoreline for unwatered boiler", True

        b_pos = unwatered.get("position")
        if b_pos:
            boiler_water_in = {"x": b_pos["x"] - 1.0, "y": b_pos["y"]}
            src_pt = pump_pos or ({"x": water_lm["x"], "y": water_lm["y"]} if water_lm else None)
            if src_pt and not _is_connected(pipes, src_pt, boiler_water_in):
                yield from _craft(inv, "pipe", 15, "craft pipes to feed water to dry boiler")
                yield ({"skill": "connect_pipe", "from": src_pt, "to": boiler_water_in},
                       "connect boiler to water pipes with an offshore pump", True)

    # Electric mining fields come right after power, before any new production block.
    field_ores = set()
    for entry, why, sure in _field_moves(p, inv, factory, blocked):
        if entry.get("output") == "field":
            field_ores.add(entry["resource"])
        yield entry, why, sure
    plates_ok = _plates_ready(p, factory, field_ores)   # science waits while a needed field is queued

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
        if _tech(p, "electric-mining-drill") and power.get("has_grid"):
            for ore, (plate, target) in demand_targets(p).items():
                if ore in field_ores:
                    continue                    # a mining field is already queued for this ore
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
                yield ({"skill": "build_miner", "resource": ore, "output": "furnace", "count": pairs,
                        "drill": "electric"},
                       f"{plate} at {_rate(p, plate)}/min, want {target}", True)
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

                # Connect ore and coal belts to smelter inputs
                conns = p.get("connected_belts") or []
                smelt_in = _get_bp_port(placed_bps, bp_name, "in2") or _get_bp_port(placed_bps, bp_name, "in1")
                if smelt_in:
                    target_pt = {"x": smelt_in["x"], "y": smelt_in["y"]}
                    miner_positions = factory.get("miner_positions") or {}

                    # 1. Connect Iron Ore to Smelter input
                    iron_miners = miner_positions.get("iron-ore") or []
                    iron_src = iron_miners[0].get("drop_position") if iron_miners else None
                    if not iron_src:
                        iron_lm = _landmark(p, "iron-ore")
                        if iron_lm:
                            iron_src = {"x": iron_lm["x"], "y": iron_lm["y"]}
                    if iron_src and not _is_connected(conns, iron_src, target_pt):
                        dx = abs(iron_src["x"] - target_pt["x"])
                        dy = abs(iron_src["y"] - target_pt["y"])
                        yield from _craft(inv, "transport-belt", min(int(dx + dy + 10), 60), "belts to feed iron ore to smelters")
                        yield ({"skill": "connect_belt", "from": iron_src, "to": target_pt},
                               "feed iron ore belt into modular smelter column", True)

                    # 2. Connect Coal to Smelter fuel input
                    coal_miners = miner_positions.get("coal") or []
                    coal_src = coal_miners[0].get("drop_position") if coal_miners else None
                    if not coal_src:
                        coal_lm = _landmark(p, "coal")
                        if coal_lm:
                            coal_src = {"x": coal_lm["x"], "y": coal_lm["y"]}
                    smelt_fuel = _get_bp_port(placed_bps, bp_name, "in1") or smelt_in
                    smelt_fuel_pt = {"x": smelt_fuel["x"], "y": smelt_fuel["y"]}
                    if coal_src and not _is_connected(conns, coal_src, smelt_fuel_pt):
                        dx = abs(coal_src["x"] - smelt_fuel_pt["x"])
                        dy = abs(coal_src["y"] - smelt_fuel_pt["y"])
                        yield from _craft(inv, "transport-belt", min(int(dx + dy + 10), 60), "belts to feed coal to smelters")
                        yield ({"skill": "connect_belt", "from": coal_src, "to": smelt_fuel_pt},
                               "feed coal belt into modular smelter column", True)
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
                if not plates_ok:
                    pass                        # plates under 80% of target: the fields come first
                elif bp_name not in placed_names:
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
                    if not _is_ports_connected(conns, "tileable-smelter-stone", "out2", bp_name, "in1"):
                        yield ({"skill": "connect_ports", "from_bp": "tileable-smelter-stone", "from_port": "out2",
                                "to_bp": bp_name, "to_port": "in1"},
                               "connect smelter output belt to red science input belt", True)

                lab_pos = _find_placed(p, lab_bp)
                if red_pos and lab_pos:
                    if not _is_ports_connected(conns, bp_name, "out2", lab_bp, "in1"):
                        yield ({"skill": "connect_ports", "from_bp": bp_name, "from_port": "out2",
                                "to_bp": lab_bp, "to_port": "in1"},
                               "connect red science output belt to lab input belt", True)
            else:
                cells = [a for a in (factory.get("assemblers") or [])
                         if isinstance(a, dict) and a.get("recipe") == "automation-science-pack"]
                if not cells and plates_ok:
                    for item, n in (("assembling-machine-1", 3), ("inserter", 7), ("iron-chest", 4),
                                    ("small-electric-pole", 6)):
                        yield from _craft(inv, item, n, f"the red cell needs {n} {item}")
                    yield {"skill": "build_red_cell"}, "automate red science", True
                yield {"skill": "tend"}, "haul plates into the cell and packs into the lab", True
        yield from _expand_electric_mining(p, inv, factory, {"iron-ore": 6, "copper-ore": 4, "coal": 3, "stone": 2})
    elif goal_id == "green":
        yield from _expand_electric_mining(p, inv, factory, {"iron-ore": 8, "copper-ore": 5, "coal": 3, "stone": 2})
        if _tech(p, "logistic-science-pack"):
            bp_name = "tileable-science-green"
            if bp_name in unlocked_bps:
                lib = blueprints.load_library()
                bp_entry = lib.get(bp_name, {})
                if not plates_ok:
                    pass                        # plates under 80% of target: the fields come first
                elif bp_name not in placed_names:
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
                    if not _is_ports_connected(conns, "tileable-smelter-stone", "out2", bp_name, "in1"):
                        yield ({"skill": "connect_ports", "from_bp": "tileable-smelter-stone", "from_port": "out2",
                                "to_bp": bp_name, "to_port": "in1"},
                               "connect smelter output belt to green science input belt", True)

                lab_pos = _find_placed(p, "tileable-labs")
                if green_pos and lab_pos:
                    if not _is_ports_connected(conns, bp_name, "out2", "tileable-labs", "in1"):
                        yield ({"skill": "connect_ports", "from_bp": bp_name, "from_port": "out2",
                                "to_bp": "tileable-labs", "to_port": "in1"},
                               "side-load green science onto lab dual-science bus", True)
            else:
                have = [a.get("recipe") for a in (factory.get("assemblers") or []) if isinstance(a, dict)]
                missing = []
                for recipe in GREEN_UNITS:
                    if recipe in have:
                        have.remove(recipe)
                    else:
                        missing.append(recipe)
                if missing and plates_ok:
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
                    if not _is_ports_connected(conns, "tileable-smelter-stone", "out2", bp_name, "in2"):
                        yield ({"skill": "connect_ports", "from_bp": "tileable-smelter-stone", "from_port": "out2",
                                "to_bp": bp_name, "to_port": "in2"},
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
    elif goal_id == "engines":
        if _tech(p, "engine"):
            eng_bp = "tileable-engine"
            if eng_bp in unlocked_bps and eng_bp not in placed_names:
                yield {"skill": "place_blueprint", "name": eng_bp}, "stamp modular engine unit plant", True

            # Connect steel belt from steel smelter to engine plant
            conns = p.get("connected_belts") or []
            steel_pos = _find_placed(p, "tileable-steel")
            eng_pos = _find_placed(p, eng_bp)
            if steel_pos and eng_pos:
                if not _is_ports_connected(conns, "tileable-steel", "out2", eng_bp, "in1"):
                    yield ({"skill": "connect_ports", "from_bp": "tileable-steel", "from_port": "out2",
                            "to_bp": eng_bp, "to_port": "in1"},
                           "feed steel plates to engine plant", True)
            yield {"skill": "tend"}, "maintain engine assemblers and feed steel", True
    elif goal_id == "red-circuits":
        if _tech(p, "advanced-circuit"):
            red_bp = "tileable-red-circuits"
            if red_bp in unlocked_bps and red_bp not in placed_names:
                yield {"skill": "place_blueprint", "name": red_bp}, "stamp modular advanced circuit plant", True

            conns = p.get("connected_belts") or []
            plas_pos = _find_placed(p, "tileable-plastic")
            red_pos = _find_placed(p, red_bp)
            if plas_pos and red_pos:
                if not _is_ports_connected(conns, "tileable-plastic", "out1", red_bp, "in1"):
                    yield ({"skill": "connect_ports", "from_bp": "tileable-plastic", "from_port": "out1",
                            "to_bp": red_bp, "to_port": "in1"},
                           "feed plastic into advanced circuit plant", True)
            yield {"skill": "tend"}, "maintain advanced circuit assemblers", True
    elif goal_id == "blue":
        if _tech(p, "chemical-science-pack"):
            blue_bp = "tileable-science-blue"
            if blue_bp in unlocked_bps and blue_bp not in placed_names:
                yield {"skill": "place_blueprint", "name": blue_bp}, "stamp modular chemical science plant", True

            conns = p.get("connected_belts") or []
            eng_pos = _find_placed(p, "tileable-engine")
            blue_pos = _find_placed(p, blue_bp)
            if eng_pos and blue_pos:
                if not _is_ports_connected(conns, "tileable-engine", "out1", blue_bp, "in1"):
                    yield ({"skill": "connect_ports", "from_bp": "tileable-engine", "from_port": "out1",
                            "to_bp": blue_bp, "to_port": "in1"},
                           "feed engine units to chemical science plant", True)

            lab_pos = _find_placed(p, "tileable-labs")
            if lab_pos and blue_pos:
                if not _is_ports_connected(conns, blue_bp, "out1", "tileable-labs", "in1"):
                    yield ({"skill": "connect_ports", "from_bp": blue_bp, "from_port": "out1",
                            "to_bp": "tileable-labs", "to_port": "in1"},
                           "sideload chemical science into lab line", True)
            yield {"skill": "tend"}, "feed chemical science packs into labs", True
    elif goal_id == "robotics":
        if _tech(p, "construction-robotics"):
            rob_bp = "tileable-robotics"
            if rob_bp in unlocked_bps and rob_bp not in placed_names:
                yield {"skill": "place_blueprint", "name": rob_bp}, "stamp modular construction robotics hub", True
            yield from _craft(inv, "flying-robot-frame", 5, "craft flying robot frames for construction bots")
            yield from _craft(inv, "construction-robot", 10, "craft construction robots")
            yield {"skill": "tend"}, "maintain construction robotics hub and deploy bots", True


def _candidates(p: dict, blocked=frozenset()) -> Iterator[tuple[dict, str, bool]]:
    inv = _inv(p)
    factory = p.get("factory") or {}
    needs = p.get("needs") or {}
    research = p.get("research") or {}

    # 0. The player's own intent first (ghosts, deconstruction marks).
    if _count(p.get("ghosts")) > 0:
        ghost_list = (p.get("ghosts") if isinstance(p.get("ghosts"), dict) else {}).get("list") or []
        any_buildable = any(g.get("have_item") for g in ghost_list) if ghost_list else True
        needed: dict[str, int] = {}
        for g in ghost_list:
            gname = g.get("ghost_name")
            if gname and not g.get("have_item"):
                item = _ENTITY_ITEM.get(gname, gname)
                needed[item] = needed.get(item, 0) + 1
        if any_buildable:
            yield {"skill": "build_ghosts"}, "the player placed ghosts", True
            for item, count in sorted(needed.items()):
                if inv.get(item, 0) < count:
                    yield {"skill": "craft_for", "item": item, "count": count}, f"craft {count} {item} for blueprint ghosts", True
        else:
            if inv.get("iron-plate", 0) < 30 or inv.get("copper-plate", 0) < 15:
                yield {"skill": "tend"}, "collect plates to craft items for ghosts", True
            for item, count in sorted(needed.items()):
                if inv.get(item, 0) < count:
                    yield {"skill": "craft_for", "item": item, "count": count}, f"craft {count} {item} for blueprint ghosts", True
            yield {"skill": "build_ghosts"}, "build the ghosts once items are crafted", True
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

    # Tier 0 self-healing: Wire unpowered machines with connect_power
    unpowered_positions = power.get("unpowered_positions") or factory.get("unpowered_positions") or []
    if unpowered_positions and power.get("has_grid"):
        up = unpowered_positions[0]
        yield from _craft(inv, "small-electric-pole", 4, "craft poles to wire unpowered machines")
        yield ({"skill": "connect_power", "to": {"x": up["x"], "y": up["y"]}},
               f"wire unpowered machine at {{{up['x']},{up['y']}}} to electric grid", True)

    # Tier 1 self-healing: Fix broken flows, dead ends, or reversed inserters
    flow_faults = factory.get("flow_faults") or []
    if flow_faults:
        yield {"skill": "fix_flow"}, "auto-repair detected flow faults, dead ends, or reversed inserters", True

    depleted = factory.get("depleted_miners") or []
    if depleted:
        dpos = depleted[0]
        yield ({"skill": "deconstruct", "position": {"x": dpos["x"], "y": dpos["y"]}, "radius": 2},
               "remove depleted miner whose ore has run out", True)

    if unpowered_machines > 0 or (boiler_needs_fuel and not power.get("boiler_fuel_connected") and not power.get("has_grid")):
        yield {"skill": "tend"}, "power needs attention: boilers need fuel or machines need wiring", True
    elif (needs.get("burners_low_fuel") and not reflexes) or stalled:
        yield {"skill": "tend"}, "burners need fuel or drills/furnaces need emptying", True

    # 1b. Enemies near home or an attack on the AI's things: gun turrets with ammo.
    threat = p.get("threat") or {}
    nest = threat.get("nearest") or {}
    attack = threat.get("attack") or {}
    attacked_power = attack.get("name") in ("boiler", "steam-engine", "offshore-pump")
    if (nest and nest.get("distance", 1e9) <= DEFENSE_RANGE) or threat.get("attack"):
        turret_count = _by_type(p, "ammo-turret")
        if turret_count < DEFENSE_TURRETS or _ammo_per_turret(p) < 10.0:
            if not _tech(p, "gun-turret"):
                if research.get("current") != "gun-turret" and _lab_count(p):
                    yield {"skill": "research", "tech": "gun-turret"}, "enemies are near: gun turrets need research", True
            else:
                need = DEFENSE_TURRETS - turret_count
                if need > 0:
                    yield from _craft(inv, "gun-turret", need, f"{need} gun turret(s) against the nearby enemies")
                ammo_item = "piercing-rounds-magazine" if _tech(p, "military-2") else "firearm-magazine"
                yield from _craft(inv, ammo_item, 10 * max(1, need), f"{ammo_item} for the turrets")
                if need > 0:
                    defense_entry = {"skill": "build_defense", "count": DEFENSE_TURRETS}
                    if attacked_power:
                        defense_entry["site"] = "power"
                    yield defense_entry, f"enemies near {'power' if attacked_power else 'home'}: turrets toward them", True
                else:
                    yield {"skill": "tend"}, "restock ammo in standing turrets", True

    # 2. Burner bootstrap: drills on coal, iron, copper, stone.
    # Phased out entirely once electric mining drill is researched and power grid is up.
    cur = goals.current(p)
    goal_id = cur[1].id if cur else ""
    electric_mining_era = _tech(p, "electric-mining-drill") and (p.get("power") or {}).get("has_grid", False)
    if goal_id == "bootstrap" and not electric_mining_era:
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
    elif goal_id or electric_mining_era:
        yield from _late_game(p, inv, factory, goal_id or "smelting", blocked)

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
