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

from .factorio.api import ACTIONS, SKILLS, VALID_DIRECTIONS

_POSITION = {
    "type": "object",
    "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
    "required": ["x", "y"],
    "additionalProperties": False,
}
_STR = {"type": "string"}
_INT = {"type": "integer"}

FIELD_TYPES: dict[str, dict] = {
    "position": _POSITION, "from": _POSITION, "to": _POSITION,
    "count": _INT, "radius": _INT, "distance": _INT, "index": _INT, "keep": _INT,
    "direction": {"type": "string", "enum": sorted(VALID_DIRECTIONS)},
    "items": {"type": "array", "items": _STR, "maxItems": 20},
}

# Optional params each entry may carry, on top of its required ones — every
# field the mod's handler reads (skills.lua p.*, primitives.lua action.*).
# Anything missing here is stripped by the server, so keep this in sync.
OPTIONAL: dict[str, list[str]] = {
    # skills
    "gather": ["count"],
    "build_miner": ["resource", "output", "item", "count", "drill"],
    "build_smelter": ["ore", "count", "item"],
    "build_assembler": ["count", "item"],
    "build_defense": ["count"],
    "research": ["tech"],
    "deconstruct": ["radius"],
    "loot_chests": ["radius", "items"],
    "deposit_to_chest": ["radius", "keep"],
    "place_blueprint": ["position", "resource"],
    "craft_for": ["count"],
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


def action_schema(max_items: int = 4, blueprint_names: list[str] | None = None) -> dict:
    """blueprint_names: the library the mod holds. place_blueprint's name is
    restricted to it, and the skill is left out entirely when it's empty."""
    variants = []
    for n, req in sorted(SKILLS.items()):
        if n == "place_blueprint":
            if not blueprint_names:
                continue
            v = _entry("skill", n, req)
            v["properties"]["name"] = {"type": "string", "enum": sorted(blueprint_names)}
            variants.append(v)
        else:
            variants.append(_entry("skill", n, req))
    variants += [_entry("action", n, req) for n, req in sorted(ACTIONS.items())]
    return {
        "type": "array",
        "minItems": 1,
        "maxItems": max_items,
        "items": {"anyOf": variants},
    }


def response_format(max_items: int = 4, blueprint_names: list[str] | None = None) -> dict:
    return {
        "type": "json_schema",
        "json_schema": {"name": "actions", "strict": True,
                        "schema": action_schema(max_items, blueprint_names)},
    }
