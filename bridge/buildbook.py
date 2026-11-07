"""
bridge/buildbook.py: Deterministic Build Book State Machine behind ai-buildbook.

Implements the Round 20 modular factory progression:
1. Bootstrap: burner phase (drills on coal, iron, copper, stone).
2. Power: steam power on shoreline (build_power).
3. Research bootstrap: automation, then electric-mining-drill.
4. Mining fields: electric iron field, then electric copper field.
5. Base frame: base site corridor, bus head, 2 bus segments.
6. Resource trunks: iron to bus in_fe, copper to bus in_cu.
7. Cells & Lab row: tap_outer, tap_inner, gear_red in L1, lab_row in L2, science busing.
8. Research logistics & green science.
9. Expansion loop.
"""

from __future__ import annotations

import os
from typing import Any, Callable, Iterator

from . import goals


def is_enabled(p: dict) -> bool:
    """Check if the Build Book state machine is active."""
    env = os.environ.get("AI_BUILDBOOK", "").strip().lower()
    if env in ("1", "true", "yes", "on"):
        return True
    return bool(p.get("buildbook_enabled"))


# ---------------------------------------------------------------------------
# Perception helpers
# ---------------------------------------------------------------------------

def _tech(p: dict, name: str) -> bool:
    res = p.get("research") or {}
    done = res.get("done") or {}
    if isinstance(done, dict):
        return bool(done.get(name))
    elif isinstance(done, list):
        return name in done
    return False


def _by_type(p: dict, typ: str) -> int:
    return int((p.get("factory") or {}).get("by_type", {}).get(typ, 0))


def _lab_count(p: dict) -> int:
    return _by_type(p, "lab")


def _inv(p: dict) -> dict[str, int]:
    return (p.get("inventory") or {}).get("main") or {}


def _fields(p: dict) -> list[dict]:
    return p.get("fields") or []


def _has_field(p: dict, resource: str) -> bool:
    for f in _fields(p):
        if f.get("resource") == resource or f.get("name") == resource:
            return True
    # Also check miners_by_resource
    miners = (p.get("factory") or {}).get("miners_by_resource") or {}
    needed = 3 if resource == "iron-ore" else 2
    return miners.get(resource, 0) >= needed


def _placed_stamps(p: dict) -> list[dict]:
    return p.get("placed_stamps") or []


def _has_stamp(p: dict, name: str, at_u: int | None = None) -> bool:
    for s in _placed_stamps(p):
        if s.get("name") == name:
            if at_u is None or s.get("at_u") == at_u:
                return True
    # Also check base.slots
    base = p.get("base") or {}
    slots = base.get("slots") or {}
    if at_u is not None:
        slot = slots.get(at_u) or slots.get(str(at_u))
        if slot and slot.get("name") == name:
            return True
    return False


def _connected_belts(p: dict) -> list[dict]:
    return p.get("connected_belts") or []


def _has_trunk(p: dict, to_port: str) -> bool:
    for c in _connected_belts(p):
        if c.get("to_port") == to_port:
            return True
        if c.get("to_bp") == "base" and c.get("to_port") == to_port:
            return True
    return False


def _has_feed(p: dict, from_bp: str, to_bp: str) -> bool:
    for c in _connected_belts(p):
        if c.get("from_bp") == from_bp and c.get("to_bp") == to_bp:
            return True
    return False


# ---------------------------------------------------------------------------
# Step definitions
# ---------------------------------------------------------------------------

BOOTSTRAP_WANT = [
    ("coal", 1, "chest"),
    ("iron-ore", 2, "furnace"),
    ("copper-ore", 1, "furnace"),
    ("stone", 1, "chest"),
]


def _step_bootstrap_done(p: dict) -> bool:
    cur = goals.current(p)
    if cur and cur[1].id != "bootstrap":
        return True
    miners = (p.get("factory") or {}).get("miners_by_resource") or {}
    for res, want, _ in BOOTSTRAP_WANT:
        if miners.get(res, 0) < want:
            return False
    return True


def _step_bootstrap_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    inv = _inv(p)
    factory = p.get("factory") or {}
    miners = factory.get("miners_by_resource") or {}

    for resource, want, output in BOOTSTRAP_WANT:
        if miners.get(resource, 0) >= want:
            continue
        if inv.get("burner-mining-drill", 0) == 0:
            if inv.get("iron-plate", 0) < 9:
                yield {"skill": "tend"}, "collect plates for crafting drills", True
            yield ({"skill": "craft_for", "item": "burner-mining-drill", "count": 1},
                   f"craft burner drill for {resource}", True)
        if inv.get("stone", 0) < 5 and output == "furnace":
            yield {"skill": "gather", "item": "stone", "count": 20}, "stone for furnace", True
        yield ({"skill": "build_miner", "resource": resource, "output": output},
               f"place burner drill on {resource}", True)
    yield {"skill": "tend"}, "keep drills and furnaces fed", True


def _step_power_done(p: dict) -> bool:
    power = p.get("power") or {}
    return bool(power.get("has_grid") and _by_type(p, "boiler") >= 1 and _by_type(p, "generator") >= 2)


def _step_power_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    water_lm = (p.get("landmarks") or {}).get("water")
    if water_lm and water_lm.get("distance", 0) > 35:
        yield ({"skill": "goto", "position": {"x": water_lm["x"], "y": water_lm["y"]}},
               f"water is {water_lm['distance']} tiles away", True)
    yield {"skill": "build_power"}, "build steam power on shoreline", True


def _step_research_bootstrap_done(p: dict) -> bool:
    return _tech(p, "automation") and _tech(p, "electric-mining-drill")


def _step_research_bootstrap_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    inv = _inv(p)
    research = p.get("research") or {}

    if _lab_count(p) == 0:
        if inv.get("lab", 0) > 0 and (p.get("home") or {}).get("position"):
            home = p["home"]["position"]
            yield ({"action": "place", "item": "lab", "position": {"x": home["x"] + 4, "y": home["y"] + 4}},
                   "place lab near home", True)
        else:
            yield {"skill": "craft_for", "item": "lab", "count": 1}, "craft a lab for research", True

    if not _tech(p, "automation"):
        if research.get("current") != "automation":
            yield {"skill": "research", "tech": "automation"}, "research automation", True
    elif not _tech(p, "electric-mining-drill"):
        if research.get("current") != "electric-mining-drill":
            yield {"skill": "research", "tech": "electric-mining-drill"}, "research electric-mining-drill", True

    if inv.get("automation-science-pack", 0) < 10:
        yield ({"skill": "craft_for", "item": "automation-science-pack", "count": 10},
               "craft red science packs for research", True)
    yield {"skill": "tend"}, "feed science packs to labs", True


def _step_fields_done(p: dict) -> bool:
    return _has_field(p, "iron-ore") and _has_field(p, "copper-ore")


def _step_fields_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    if not _has_field(p, "iron-ore"):
        yield ({"skill": "build_miner", "resource": "iron-ore", "output": "field"},
               "build electric iron mining field with smelting", True)
    elif not _has_field(p, "copper-ore"):
        yield ({"skill": "build_miner", "resource": "copper-ore", "output": "field"},
               "build electric copper mining field with smelting", True)


def _step_base_frame_done(p: dict) -> bool:
    return (
        p.get("base") is not None
        and _has_stamp(p, "bus_head", 0)
        and _has_stamp(p, "tap_inner", 4)
        and _has_stamp(p, "tap_outer", 8)
        and _has_stamp(p, "bus_segment", 10)
        and _has_stamp(p, "bus_segment", 24)
    )


def _step_base_frame_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    if not p.get("base"):
        yield {"skill": "build_base"}, "establish base frame site and bus corridor", True
        return
    if not _has_stamp(p, "bus_head", 0):
        yield ({"skill": "place_stamp", "stamp": "bus_head", "at_u": 0, "side": "left"},
               "place bus head stamp at u=0", True)
        return
    if not _has_stamp(p, "tap_inner", 4):
        yield ({"skill": "place_stamp", "stamp": "tap_inner", "at_u": 4, "side": "left"},
               "place tap_inner at u=4", True)
        return
    if not _has_stamp(p, "tap_outer", 8):
        yield ({"skill": "place_stamp", "stamp": "tap_outer", "at_u": 8, "side": "left"},
               "place tap_outer at u=8", True)
        return
    if not _has_stamp(p, "bus_segment", 10):
        yield ({"skill": "place_stamp", "stamp": "bus_segment", "at_u": 10, "side": "left"},
               "place bus segment 1 at u=10", True)
        return
    if not _has_stamp(p, "bus_segment", 24):
        yield ({"skill": "place_stamp", "stamp": "bus_segment", "at_u": 24, "side": "left"},
               "place bus segment 2 at u=24", True)
        return


def _step_trunks_done(p: dict) -> bool:
    return _has_trunk(p, "in_fe") and _has_trunk(p, "in_cu")


def _step_trunks_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    if not _has_trunk(p, "in_fe"):
        yield ({"skill": "connect_ports", "from_bp": "field:1", "from_port": "plate_output",
                "to_bp": "base", "to_port": "in_fe", "underground": True},
               "route iron trunk into bus head in_fe", True)
    elif not _has_trunk(p, "in_cu"):
        yield ({"skill": "connect_ports", "from_bp": "field:2", "from_port": "plate_output",
                "to_bp": "base", "to_port": "in_cu", "underground": True},
               "route copper trunk into bus head in_cu", True)


def _step_red_and_lab_done(p: dict) -> bool:
    return (
        _has_stamp(p, "gear_red", 9)
        and _has_stamp(p, "red_feed", 6)
        and _has_stamp(p, "lab_row", 23)
        and _has_feed(p, "gear_red", "lab_row")
    )


def _step_red_and_lab_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    if not _has_stamp(p, "gear_red", 9):
        yield ({"skill": "place_stamp", "stamp": "gear_red", "at_u": 9, "side": "left"},
               "place gear_red stamp in L1 at u=9", True)
        return
    if not _has_stamp(p, "red_feed", 6):
        yield ({"skill": "place_stamp", "stamp": "red_feed", "at_u": 6, "side": "left"},
               "place red_feed stamp at u=6", True)
        return
    if not _has_stamp(p, "lab_row", 23):
        yield ({"skill": "place_stamp", "stamp": "lab_row", "at_u": 23, "side": "left"},
               "place lab_row stamp in L2 at u=23", True)
        return
    if not _has_feed(p, "gear_red", "lab_row"):
        yield ({"skill": "connect_ports", "from_bp": "gear_red", "from_port": "out_science",
                "to_bp": "lab_row", "to_port": "in_science"},
               "connect science output to lab row", True)
        return


def _step_logistics_and_green_done(p: dict) -> bool:
    return _tech(p, "logistic-science-pack") and _by_type(p, "assembling-machine") >= 8


def _step_logistics_and_green_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    research = p.get("research") or {}
    if not _tech(p, "logistics"):
        if research.get("current") != "logistics":
            yield {"skill": "research", "tech": "logistics"}, "research logistics", True
    elif not _tech(p, "logistic-science-pack"):
        if research.get("current") != "logistic-science-pack":
            yield {"skill": "research", "tech": "logistic-science-pack"}, "research logistic-science-pack", True
    else:
        yield {"skill": "build_green_cell"}, "build green science cell", True


def _step_expansion_moves(p: dict) -> Iterator[tuple[dict, str, bool]]:
    research = p.get("research") or {}
    if not research.get("current"):
        for tech in ["steel-processing", "military", "optics", "electronics", "fast-inserter"]:
            if not _tech(p, tech):
                yield {"skill": "research", "tech": tech}, f"expansion research: {tech}", True
                break
    yield {"skill": "tend"}, "maintain factory expansion and bus throughput", True


# ---------------------------------------------------------------------------
# Ordered Build Book Sequence
# ---------------------------------------------------------------------------

STEPS: list[dict[str, Any]] = [
    {
        "id": "bootstrap",
        "prereqs": [],
        "done": _step_bootstrap_done,
        "moves": _step_bootstrap_moves,
    },
    {
        "id": "power",
        "prereqs": ["bootstrap"],
        "done": _step_power_done,
        "moves": _step_power_moves,
    },
    {
        "id": "research_bootstrap",
        "prereqs": ["power"],
        "done": _step_research_bootstrap_done,
        "moves": _step_research_bootstrap_moves,
    },
    {
        "id": "mining_fields",
        "prereqs": ["research_bootstrap"],
        "done": _step_fields_done,
        "moves": _step_fields_moves,
    },
    {
        "id": "base_frame",
        "prereqs": ["mining_fields"],
        "done": _step_base_frame_done,
        "moves": _step_base_frame_moves,
    },
    {
        "id": "resource_trunks",
        "prereqs": ["base_frame"],
        "done": _step_trunks_done,
        "moves": _step_trunks_moves,
    },
    {
        "id": "red_and_lab",
        "prereqs": ["resource_trunks"],
        "done": _step_red_and_lab_done,
        "moves": _step_red_and_lab_moves,
    },
    {
        "id": "logistics_and_green",
        "prereqs": ["red_and_lab"],
        "done": _step_logistics_and_green_done,
        "moves": _step_logistics_and_green_moves,
    },
    {
        "id": "expansion",
        "prereqs": ["logistics_and_green"],
        "done": lambda p: False,
        "moves": _step_expansion_moves,
    },
]


def candidates(p: dict, blocked=frozenset()) -> Iterator[tuple[dict, str, bool]]:
    """Yield candidates from the first not-done step whose prerequisites are done."""
    done_ids: set[str] = set()

    for step in STEPS:
        sid = step["id"]
        is_done = step["done"](p)
        if is_done:
            done_ids.add(sid)
            continue

        # Check prerequisites
        prereqs_met = all(pr in done_ids for pr in step["prereqs"])
        if not prereqs_met:
            continue

        # Yield moves for this active step
        yield from step["moves"](p)
        return
