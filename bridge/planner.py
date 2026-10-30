"""
Next-step planner: a fixed early-game build order turned into ONE concrete
skill entry, so a small model has a sensible move to copy (or the coach has
one to fall back on when the model loops).

next_step(perception, blocked) -> (entry, reason) | None. Rules run in
priority order and skip entries whose key is blocked (bridge/coach.py), so a
step that keeps failing gives way to the next useful one.
"""

from __future__ import annotations

from typing import Iterator

from . import goals

# (resource, drills wanted, output) — the burner bootstrap, coal first so
# everything else has fuel. Thresholds match the bootstrap milestone.
BOOTSTRAP = [("coal", 1, "chest"), ("iron-ore", 2, "furnace"),
             ("copper-ore", 1, "furnace"), ("stone", 1, "chest")]
FAR = 50  # tiles; build_miner only searches 64 around the character


def entry_key(d: dict) -> str:
    """Stable identity of a move, for the sent entry and the mod's result alike.
    Results label skills "skill:<name>" and primitives by name."""
    if d.get("skill"):
        name = "skill:" + str(d["skill"])
    else:
        name = str(d.get("action") or "?")
    parts = [name]
    for k in ("item", "tech", "resource", "recipe", "name", "ore", "output", "count"):
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


def _candidates(p: dict) -> Iterator[tuple[dict, str]]:
    inv = _inv(p)
    factory = p.get("factory") or {}
    needs = p.get("needs") or {}
    research = p.get("research") or {}

    # 0. The player's own intent first (ghosts, deconstruction marks).
    if _count(p.get("ghosts")) > 0:
        yield {"skill": "build_ghosts"}, "the player placed ghosts"
    if _count(p.get("deconstruction")) > 0:
        yield {"skill": "deconstruct"}, "the player marked things for removal"

    # 1. Keep the burner base running.
    stalled = [n for n in needs.get("outputs_full") or [] if n.get("drop") in ("ground", "container", "furnace")]
    if needs.get("burners_low_fuel") or stalled:
        yield {"skill": "tend"}, "burners need fuel or drills/furnaces need emptying"
    if inv.get("coal", 0) < 5:
        if (factory.get("miners_by_resource") or {}).get("coal"):
            yield {"skill": "tend"}, "low on coal — collect it from the coal drill's chest"
        yield {"skill": "gather", "item": "coal", "count": 50}, "low on coal"

    # 2. Burner bootstrap: drills on coal, iron, copper, stone.
    cur = goals.current(p)
    if cur and cur[1].id == "bootstrap":
        miners = factory.get("miners_by_resource") or {}
        for resource, want, output in BOOTSTRAP:
            if miners.get(resource, 0) >= want:
                continue
            lm = _landmark(p, resource)
            if lm and lm.get("distance", 0) > FAR:
                yield ({"skill": "goto", "position": {"x": lm["x"], "y": lm["y"]}},
                       f"nearest {resource} is {lm['distance']} tiles away")
            if inv.get("burner-mining-drill", 0) == 0:
                yield ({"skill": "craft_for", "item": "burner-mining-drill", "count": 1},
                       f"need a drill for {resource}")
                yield {"skill": "tend"}, "collect plates for crafting drills"
                yield ({"skill": "gather", "item": "stone", "count": 20},
                       "drills and furnaces need stone")
            else:
                yield ({"skill": "build_miner", "resource": resource, "output": output},
                       f"{miners.get(resource, 0)}/{want} drill(s) on {resource}")
        yield {"skill": "tend"}, "keep the drills and furnaces fed while iron output builds up"

    # 3. Techs unlocked by doing something (2.x early game).
    for t in research.get("triggers") or []:
        target, n = t.get("target"), int(t.get("count") or 1)
        if not target:
            continue
        if t.get("type") == "craft-item":
            yield ({"skill": "craft_for", "item": target, "count": inv.get(target, 0) + n},
                   f"crafting {n} new {target} unlocks {t.get('tech')}")
        elif t.get("type") == "mine-entity":
            first = str(target).split("/")[0]
            yield ({"skill": "gather", "item": first, "count": n},
                   f"mining {first} unlocks {t.get('tech')}")

    # 4. Research and labs.
    if not research.get("current"):
        yield {"skill": "research"}, "nothing is being researched"
    labs = _labs(p)
    if not _lab_count(p) and inv.get("lab", 0) > 0 and (p.get("home") or {}).get("position"):
        home = p["home"]["position"]
        yield ({"action": "place", "item": "lab", "position": {"x": home["x"] + 4, "y": home["y"] + 4}},
               "place the lab near home")
    if research.get("current") and (factory.get("labs") or {}).get("without_packs") and labs:
        if inv.get("automation-science-pack", 0) > 0:
            yield ({"action": "insert", "item": "automation-science-pack",
                    "count": inv["automation-science-pack"], "position": labs[0]["position"],
                    "inventory": "lab"}, "a lab has no science packs")
        else:
            yield ({"skill": "craft_for", "item": "automation-science-pack", "count": 10},
                   "labs need science packs")


def next_step(p: dict, blocked: frozenset[str] | set[str] = frozenset()) -> tuple[dict, str] | None:
    for entry, reason in _candidates(p):
        if entry_key(entry) not in blocked:
            return entry, reason
    return None
