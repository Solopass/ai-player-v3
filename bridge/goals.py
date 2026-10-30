"""
Goal ladder — the long-term plan, so a small model only has to decide the
next step toward ONE clear milestone instead of "beat the game".

Each milestone has a done() check against the perception the mod sends, the
research it needs, and which blueprint categories (bridge/blueprints.py)
build it. describe() picks the first milestone that isn't done and turns it
into a short prompt section, with the best-fitting library blueprints and
what's still missing for each (vs the AI's inventory).

Targets are deliberately modest: the point is a working chain the human can
scale, not a megabase.
"""

from dataclasses import dataclass, field
from typing import Callable

from .blueprints import missing_items


def _by_type(p: dict, name: str) -> int:
    return int(((p.get("factory") or {}).get("by_type") or {}).get(name, 0))


def _per_min(p: dict, item: str) -> int:
    return int((((p.get("production") or {}).get("items") or {}).get(item) or {}).get("per_min", 0))


def _tech(p: dict, name: str) -> bool:
    return name in ((p.get("research") or {}).get("done") or [])


@dataclass
class Milestone:
    id: str
    title: str
    done: Callable[[dict], bool]
    status: Callable[[dict], str]
    hint: str
    categories: list[str] = field(default_factory=list)
    techs: list[str] = field(default_factory=list)


LADDER: list[Milestone] = [
    Milestone(
        "power", "Steam power",
        lambda p: _by_type(p, "boiler") >= 1 and _by_type(p, "steam-engine") >= 1
                  and (p.get("power") or {}).get("has_grid", False),
        lambda p: f"{_by_type(p, 'boiler')} boiler(s), {_by_type(p, 'steam-engine')} steam engine(s)",
        "Offshore pump on a shoreline → boiler (fuel it with coal) → steam engines, then poles to the base.",
        ["power"]),
    Milestone(
        "automation", "Research Automation",
        lambda p: _tech(p, "automation"),
        lambda p: f"current research: {(p.get('research') or {}).get('current')}",
        "Place a lab, hand-craft red science (craft_for automation-science-pack), feed the lab, research automation.",
        ["research"], ["automation"]),
    Milestone(
        "smelting", "Automated iron and copper smelting",
        lambda p: _per_min(p, "iron-plate") >= 30 and _per_min(p, "copper-plate") >= 15,
        lambda p: f"iron {_per_min(p, 'iron-plate')}/min (want 30), copper {_per_min(p, 'copper-plate')}/min (want 15)",
        "Miners on iron and copper ore feeding furnaces; keep coal flowing to them.",
        ["mining", "smelting"]),
    Milestone(
        "red", "Automate red science",
        lambda p: _per_min(p, "automation-science-pack") >= 5,
        lambda p: f"{_per_min(p, 'automation-science-pack')}/min (want 5)",
        "Assemblers making gears and automation-science-pack, fed from the smelters, into labs.",
        ["science-red", "research"], ["automation"]),
    Milestone(
        "green", "Automate green science",
        lambda p: _per_min(p, "logistic-science-pack") >= 5,
        lambda p: f"{_per_min(p, 'logistic-science-pack')}/min (want 5)",
        "Assemblers for inserters, transport belts and logistic-science-pack.",
        ["science-green"], ["logistics", "logistic-science-pack"]),
    Milestone(
        "steel", "Steel",
        lambda p: _tech(p, "steel-processing") and _per_min(p, "steel-plate") >= 1,
        lambda p: f"steel {_per_min(p, 'steel-plate')}/min",
        "Furnaces turning iron plates into steel.",
        ["smelting"], ["steel-processing"]),
    Milestone(
        "oil", "Oil processing",
        lambda p: _by_type(p, "pumpjack") >= 1 and _by_type(p, "oil-refinery") >= 1,
        lambda p: f"{_by_type(p, 'pumpjack')} pumpjack(s), {_by_type(p, 'oil-refinery')} refinery(ies)",
        "Pumpjacks on crude oil, piped to an oil refinery.",
        ["oil", "oil-processing"], ["oil-processing"]),
    Milestone(
        "plastic", "Plastic and sulfur",
        lambda p: _per_min(p, "plastic-bar") >= 5 and _per_min(p, "sulfur") >= 1,
        lambda p: f"plastic {_per_min(p, 'plastic-bar')}/min, sulfur {_per_min(p, 'sulfur')}/min",
        "Chemical plants making plastic bars and sulfur from petroleum gas.",
        ["oil-processing"], ["plastics", "sulfur-processing"]),
    Milestone(
        "red-circuits", "Advanced circuits",
        lambda p: _per_min(p, "advanced-circuit") >= 2,
        lambda p: f"{_per_min(p, 'advanced-circuit')}/min",
        "Assemblers making copper cable, electronic circuits and advanced circuits.",
        ["circuits"], ["advanced-circuit"]),
    Milestone(
        "blue", "Automate blue science",
        lambda p: _per_min(p, "chemical-science-pack") >= 2,
        lambda p: f"{_per_min(p, 'chemical-science-pack')}/min (want 2)",
        "Engines, advanced circuits and sulfur into chemical-science-pack assemblers.",
        ["science-blue"], ["chemical-science-pack"]),
    Milestone(
        "purple-yellow", "Production and utility science",
        lambda p: _per_min(p, "production-science-pack") >= 1 and _per_min(p, "utility-science-pack") >= 1,
        lambda p: f"purple {_per_min(p, 'production-science-pack')}/min, yellow {_per_min(p, 'utility-science-pack')}/min",
        "Production-science-pack and utility-science-pack lines.",
        ["science-purple", "science-yellow"], ["production-science-pack", "utility-science-pack"]),
    Milestone(
        "silo", "Rocket silo",
        lambda p: _tech(p, "rocket-silo") and _by_type(p, "rocket-silo") >= 1,
        lambda p: f"rocket-silo researched: {_tech(p, 'rocket-silo')}, silos: {_by_type(p, 'rocket-silo')}",
        "Research the rocket silo and build it near power.",
        ["rocket"], ["rocket-silo"]),
    Milestone(
        "launch", "Launch a rocket",
        lambda p: int((p.get("production") or {}).get("rockets_launched") or 0) >= 1,
        lambda p: f"rocket parts {_per_min(p, 'rocket-part')}/min",
        "Feed the silo low density structures, rocket fuel and processing units until it launches.",
        ["rocket"]),
]


def _fits(category: str, wanted: list[str]) -> bool:
    """Exact match, or a combined science build ("science-green-red") that
    makes any of the wanted colours."""
    if category in wanted:
        return True
    if category.startswith("science-"):
        colours = set(category.split("-")[1:])
        return any(w.startswith("science-") and w.split("-", 1)[1] in colours for w in wanted)
    return False


def current(p: dict) -> tuple[int, Milestone] | None:
    for i, m in enumerate(LADDER):
        if not m.done(p):
            return i, m
    return None


def describe(p: dict, library: dict[str, dict]) -> str:
    """Prompt section for the current milestone ('' when every goal is met)."""
    cur = current(p)
    if cur is None:
        return "GOAL: every milestone on the ladder is done — keep the factory running and help the player."
    i, m = cur
    lines = [f"CURRENT GOAL ({i + 1}/{len(LADDER)}): {m.title} — {m.status(p)}.", f"How: {m.hint}"]

    done = set((p.get("research") or {}).get("done") or [])
    todo = [t for t in m.techs if t not in done]
    if todo:
        lines.append("Research needed (queue with the research skill): " + ", ".join(todo))

    in_mod = set(p.get("blueprint_library") or [])
    inventory = p.get("inventory") or []
    fits = []
    for name, e in library.items():
        if name in in_mod and _fits(e.get("category") or "", m.categories):
            miss = missing_items(e, inventory)
            fits.append((sum(miss.values()), name, miss))
    fits.sort()

    placed = {b.get("name") for b in (p.get("placed_blueprints") or [])}
    # Fitting blueprints that need research first: a hint about what to unlock.
    locked = p.get("blueprint_locked") or {}
    if not fits:
        # Prefer the goal's main category (a science cell over a lab block).
        waiting = sorted((not _fits(library[n].get("category") or "", m.categories[:1]), len(v), n, v)
                         for n, v in locked.items()
                         if n in library and _fits(library[n].get("category") or "", m.categories))
        if waiting:
            _, _, n, items = waiting[0]
            lines.append(f"Library blueprint {n} fits this goal but is locked — unlock "
                         f"{', '.join(items)} first (research, or the tech's trigger).")

    if fits:
        opts = []
        for _, name, miss in fits[:3]:
            if name in placed:
                opts.append(f"{name} (already placed — make sure it runs: fuel, inputs, power; see factory.attention)")
            elif miss:
                short = ", ".join(f"{n}x {k}" for k, n in list(miss.items())[:6])
                opts.append(f"{name} (missing {short} — craft_for/gather them first)")
            else:
                opts.append(f"{name} (you have everything)")
        lines.append("Blueprints for this goal: " + " | ".join(opts))
        ready = next((n for _, n, miss in fits if not miss and n not in placed), None)
        if ready:
            lines.append(f'Suggested now: {{"skill":"place_blueprint","name":"{ready}"}} then build_ghosts.')
    else:
        lines.append("No library blueprint fits this goal yet — build it piece by piece with place / "
                     "craft_for, or ask the player to add one (/ai-bp add).")
    return "\n".join(lines)
