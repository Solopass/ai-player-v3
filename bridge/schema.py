"""
JSON schema for the model's reply, for servers that support constrained
decoding (llama.cpp / LM Studio / vLLM `response_format: json_schema`).

With a schema the server can only emit a JSON array of known skills/actions,
so a small model can't wrap the reply in markdown, add prose, or invent a
skill name. llama.cpp drops any field the schema doesn't name, so every
parameter a skill or action reads has to be listed here (OPTIONAL below) —
otherwise the model's `item`, `count`, `position` etc. silently disappear.

Required fields come from factorio.api (ACTIONS / SKILLS), so the two tables
can't drift apart on what is mandatory.
"""

from .factorio.api import (
    ACTIONS,
    SKILLS,
    VALID_DIRECTIONS,
    actions_for_model,
    skills_for_model,
)

_POSITION = {
    "type": "object",
    "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
    "required": ["x", "y"],
    "additionalProperties": False,
}
_STR = {"type": "string"}
_INT = {"type": "integer"}
_BOOL = {"type": "boolean"}

FIELD_TYPES: dict[str, dict] = {
    "position": _POSITION, "from": _POSITION, "to": _POSITION,
    "count": _INT, "radius": _INT, "distance": _INT, "index": _INT, "keep": _INT,
    "direction": {"type": "string", "enum": sorted(VALID_DIRECTIONS)},
    "items": {"type": "array", "items": _STR, "maxItems": 20},
    "stamp": _STR,
    "at_u": _INT,
    "side": {"type": "string", "enum": ["left", "right"]},
    "plate_belt": _BOOL,
}

# Optional params each entry may carry, on top of its required ones — every
# field the mod's handler reads (skills.lua p.*, primitives.lua action.*).
# Anything missing here is stripped by the server, so keep this in sync.
OPTIONAL: dict[str, list[str]] = {
    # skills
    "gather": ["count"],
    "build_miner": ["resource", "output", "item", "count", "drill", "plate_belt"],
    "build_smelter": ["ore", "count", "item"],
    "build_assembler": ["count", "item"],
    "build_defense": ["count"],
    "research": ["tech"],
    "deconstruct": ["radius"],
    "loot_chests": ["radius", "items"],
    "deposit_to_chest": ["radius", "keep"],
    "place_blueprint": ["position", "resource"],
    "craft_for": ["count"],
    "connect_belt": [],
    "connect_pipe": [],
    "connect_ports": [],
    "connect_power": [],
    "fix_flow": ["radius"],
    "build_base": [],
    "place_stamp": ["at_u", "side", "name", "u"],
    # actions
    "move": ["distance"],
    "mine": ["name", "type", "position"],
    "place": ["direction"],
    "insert": ["inventory", "slot"],
    "take": ["inventory", "slot"],
    "pickup": ["position", "radius"],
}

# loot_chests takes items as "iron-plate,coal"; create_todo as a list.
_PER_ENTRY_TYPES: dict[str, dict[str, dict]] = {
    "loot_chests": {"items": _STR},
    # field = the electric mining field stamp (planner.py _field_moves)
    "build_miner": {"output": {"type": "string", "enum": ["chest", "furnace", "belt", "field"]}},
    "craft_for": {"item": {"type": "string", "enum": [
        "advanced-circuit", "assembling-machine-1", "assembling-machine-2",
        "automation-science-pack", "big-electric-pole", "boiler", "burner-inserter",
        "burner-mining-drill", "chemical-science-pack", "copper-cable",
        "electric-mining-drill", "electronic-circuit", "fast-inserter",
        "firearm-magazine", "gun-turret", "inserter", "iron-chest",
        "iron-gear-wheel", "iron-stick", "lab", "logistic-science-pack",
        "long-handed-inserter", "medium-electric-pole", "military-science-pack",
        "offshore-pump", "piercing-rounds-magazine", "pipe", "pipe-to-ground",
        "radar", "repair-pack", "small-electric-pole", "splitter", "steel-chest",
        "steel-furnace", "stone-furnace", "stone-wall", "transport-belt",
        "underground-belt", "wooden-chest",
    ]}},
}


def _entry(kind: str, name: str, required: list[str]) -> dict:
    fields = list(dict.fromkeys(required + OPTIONAL.get(name, [])))
    props = {kind: {"const": name}}
    for f in fields:
        props[f] = _PER_ENTRY_TYPES.get(name, {}).get(f) or FIELD_TYPES.get(f, _STR)
    return {
        "type": "object",
        "properties": props,
        "required": [kind] + required,
        "additionalProperties": False,
    }


def action_schema(max_items: int = 4, blueprint_names: list[str] | None = None,
                  llm_layout: bool = False, ghosts: int = 1) -> dict:
    """blueprint_names: the library the mod holds. place_blueprint's name is
    restricted to it, and the skill is left out entirely when it's empty."""
    variants = []
    skills = skills_for_model(llm_layout)
    actions = actions_for_model(llm_layout)
    for n, req in sorted(skills.items()):
        if n == "build_ghosts" and ghosts <= 0:
            continue
        if n == "place_blueprint":
            if not blueprint_names:
                continue
            v = _entry("skill", n, req)
            v["properties"]["name"] = {"type": "string", "enum": sorted(blueprint_names)}
            variants.append(v)
        else:
            variants.append(_entry("skill", n, req))
    variants += [_entry("action", n, req) for n, req in sorted(actions.items())]
    return {
        "type": "array",
        "minItems": 1,
        "maxItems": max_items,
        "items": {"anyOf": variants},
    }


def response_format(max_items: int = 4, blueprint_names: list[str] | None = None,
                    llm_layout: bool = False, ghosts: int = 1) -> dict:
    return {
        "type": "json_schema",
        "json_schema": {"name": "actions", "strict": True,
                        "schema": action_schema(max_items, blueprint_names, llm_layout=llm_layout, ghosts=ghosts)},
    }
