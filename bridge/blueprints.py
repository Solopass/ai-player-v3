"""
Blueprint library — the bridge owns it, the mod gets a copy over RCON.

Where blueprints live:
  blueprints/*.json         starter set shipped with the repo (committed)
  blueprints/local/*.json   your own and community imports (gitignored)

Each entry is one JSON file: {name, string, hash, category, placement,
resource, label, source, entities, cost, size}. A blueprint book is split into
one entry per blueprint inside it.

Ways to add blueprints:
  1. In game: hold a blueprint or a book and type /ai-bp add <name> or
     /ai-bp book. The mod writes it to script-output/ai-player/blueprints/ and
     the bridge imports it into blueprints/local/ on its next sync.
  2. CLI:  python -m bridge.blueprints import <file | factorioprints URL | string>
           python -m bridge.blueprints list
           python -m bridge.blueprints remove <name>

The bridge pushes the library to the mod at startup and whenever it changes
(content hashes, so nothing loops), in RCON-safe chunks.
"""

import argparse
import base64
import hashlib
import json
import logging
import re
import sys
import urllib.request
import zlib
from collections import Counter
from pathlib import Path

log = logging.getLogger(__name__)

REPO_DIR = Path(__file__).resolve().parent.parent / "blueprints"
LOCAL_DIR = REPO_DIR / "local"

# Blueprint strings live in the save file; community books can be huge.
MAX_STRING_CHARS = 200_000
CHUNK_CHARS = 3000

# Entity name -> item that places it, where they differ (2.x base + Space Age).
_ENTITY_ITEM = {
    "straight-rail": "rail", "curved-rail-a": "rail", "curved-rail-b": "rail",
    "half-diagonal-rail": "rail", "legacy-straight-rail": "rail", "legacy-curved-rail": "rail",
    "elevated-straight-rail": "rail", "elevated-curved-rail-a": "rail",
    "elevated-curved-rail-b": "rail", "elevated-half-diagonal-rail": "rail",
}
_TILE_ITEM = {
    "stone-path": "stone-brick", "concrete": "concrete", "refined-concrete": "refined-concrete",
    "hazard-concrete-left": "hazard-concrete", "hazard-concrete-right": "hazard-concrete",
    "refined-hazard-concrete-left": "refined-hazard-concrete",
    "refined-hazard-concrete-right": "refined-hazard-concrete", "landfill": "landfill",
}
_MINERS = {"burner-mining-drill", "electric-mining-drill", "big-mining-drill"}
_FURNACES = {"stone-furnace", "steel-furnace", "electric-furnace", "foundry"}
_SCIENCE_COLOR = {
    "automation-science-pack": "red", "logistic-science-pack": "green",
    "military-science-pack": "military", "chemical-science-pack": "blue",
    "production-science-pack": "purple", "utility-science-pack": "yellow",
    "space-science-pack": "white",
}
_RESOURCES = ("iron-ore", "copper-ore", "coal", "stone", "uranium-ore")


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

def decode(bp_string: str) -> dict:
    s = "".join(bp_string.split())        # pasted strings often carry line breaks
    if s.startswith("H4sI"):
        raise ValueError("this is a pre-0.15 (2016-era) blueprint string — Factorio 2.x can't import it")
    if not s or s[0] != "0":
        raise ValueError("not a Factorio blueprint string (should start with 0)")
    return json.loads(zlib.decompress(base64.b64decode(s[1:])))


def encode(data: dict) -> str:
    raw = json.dumps(data, separators=(",", ":")).encode()
    return "0" + base64.b64encode(zlib.compress(raw, 9)).decode()


def _hash(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def safe_name(label: str | None, fallback: str) -> str:
    n = re.sub(r"\[[^\]]*\]", "", label or "")          # strip [item=...] rich text
    n = re.sub(r"[^a-z0-9]+", "-", n.lower()).strip("-")[:48]
    return n or fallback


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def analyze(bp: dict) -> dict:
    """Category, placement and cost for one decoded {"blueprint": {...}}."""
    b = bp["blueprint"]
    ents = b.get("entities") or []
    names = Counter(e["name"] for e in ents)
    cost: Counter = Counter()
    for e in ents:
        cost[_ENTITY_ITEM.get(e["name"], e["name"])] += 1
        for it in e.get("items") or []:            # modules / fuel requests (2.x list form)
            iid = (it.get("id") or {}).get("name")
            n = sum(x.get("count", 1) for x in (it.get("items") or {}).get("in_inventory", [])) or 1
            if iid:
                cost[iid] += n
    for t in b.get("tiles") or []:
        item = _TILE_ITEM.get(t["name"])
        if item:
            cost[item] += 1

    xs = [e["position"]["x"] for e in ents] or [0]
    ys = [e["position"]["y"] for e in ents] or [0]
    size = {"w": int(max(xs) - min(xs)) + 2, "h": int(max(ys) - min(ys)) + 2}

    label = (b.get("label") or "").lower()
    resource = next((r for r in _RESOURCES if r.split("-")[0] in label), None)
    recipes = {e.get("recipe") for e in ents if e.get("recipe")}
    science = sorted({_SCIENCE_COLOR[r] for r in recipes if r in _SCIENCE_COLOR})

    if names["offshore-pump"] and (names["boiler"] or names["steam-engine"]):
        category, placement = "power", "near_water"
    elif names["solar-panel"] or names["boiler"] or names["steam-engine"]:
        category, placement = "power", "clear"
    elif names["rocket-silo"]:
        category, placement = "rocket", "clear"
    elif names["pumpjack"]:
        category, placement, resource = "oil", "on_ore", "crude-oil"
    elif names["oil-refinery"] or names["chemical-plant"]:
        category, placement = "oil-processing", "clear"
    elif recipes & {"advanced-circuit", "processing-unit"}:
        category, placement = "circuits", "clear"
    elif names.keys() & _MINERS:
        category, placement = "mining", "on_ore"
    elif science:
        category, placement = "science-" + "-".join(science), "clear"
    elif names.keys() & _FURNACES:
        category, placement = "smelting", "clear"
    elif names["lab"]:
        category, placement = "research", "clear"
    elif names["offshore-pump"]:
        category, placement = "water", "near_water"
    else:
        category, placement = "other", "clear"

    snap = b.get("snap-to-grid")
    tileable = snap is not None or "tileable" in label or "tile" in label

    res = {
        "category": category, "placement": placement, "resource": resource,
        "label": b.get("label") or "", "entities": sum(names.values()),
        "cost": dict(cost.most_common()), "size": size, "recipes": sorted(recipes),
    }
    if tileable:
        res["tileable"] = True
        if snap:
            res["snap_grid"] = snap
        if b.get("absolute-snapping"):
            res["absolute_snapping"] = True
    return res


def split(data: dict, base_name: str) -> list[tuple[str, dict]]:
    """Every blueprint in a decoded string (recursing into books), as
    (name, {"blueprint": ...}). Planners are skipped."""
    out: list[tuple[str, dict]] = []
    seen: set[str] = set()

    def walk(node: dict, prefix: str):
        if "blueprint" in node:
            label = node["blueprint"].get("label")
            name = safe_name(label, f"{prefix}-{len(out) + 1}")
            while name in seen:
                name = f"{name}-{len(out) + 1}"
            seen.add(name)
            out.append((name, {"blueprint": node["blueprint"]}))
        elif "blueprint_book" in node:
            book = node["blueprint_book"]
            sub = safe_name(book.get("label"), prefix)
            for child in book.get("blueprints") or []:
                walk(child, sub)
        # deconstruction_planner / upgrade_planner: not buildable, skip

    walk(data, base_name)
    return out


# ---------------------------------------------------------------------------
# Library on disk
# ---------------------------------------------------------------------------

_PLANETS = ("nauvis", "vulcanus", "fulgora", "gleba", "aquilo")


def _planet_from_name(name: str) -> str | None:
    """Planet a build is for, from its name prefix ("vulcanus-foundry-..."),
    "platform" for space platform builds, None for anywhere."""
    head = name.split("-", 1)[0]
    if head in _PLANETS:
        return head
    if head == "platform":
        return "platform"
    return None


def for_surface(lib: dict[str, dict], perception: dict) -> dict[str, dict]:
    """Library entries usable where the AI is: untagged ones plus those tagged
    for this planet (or 'platform' on a space platform)."""
    surf = perception.get("surface") or {}
    here = "platform" if surf.get("is_platform") else (surf.get("planet") or surf.get("name") or "nauvis")
    return {n: e for n, e in lib.items() if e.get("planet") in (None, here)}


def load_library(include_local: bool = False) -> dict[str, dict]:
    lib: dict[str, dict] = {}
    dirs = (REPO_DIR, LOCAL_DIR) if include_local else (REPO_DIR,)
    for d in dirs:
        if not d.exists():
            continue
        for f in sorted(d.glob("*.json")):
            if f.name == "library.json":
                continue
            try:
                e = json.loads(f.read_text(encoding="utf-8"))
                e.setdefault("hash", _hash(e["string"]))   # hand-written entries
                e.setdefault("planet", _planet_from_name(e["name"]))
                e.setdefault("source", "local" if d == LOCAL_DIR else "repo")
                for k, v in (("category", "other"), ("placement", "clear"), ("entities", 0)):
                    e.setdefault(k, v)
                lib[e["name"]] = e
            except (OSError, ValueError, KeyError) as ex:
                log.warning("Bad blueprint file %s: %s", f, ex)
    return lib


def add_string(bp_string: str, name: str | None = None, category: str | None = None,
               source: str = "import") -> list[str]:
    """Import a blueprint or book string into blueprints/local/. Returns names added."""
    data = decode(bp_string)
    if name:
        name = safe_name(name, "bp")          # names become file names
    base = name or safe_name((data.get("blueprint") or data.get("blueprint_book") or {}).get("label"), "bp")
    entries = split(data, base)
    if len(entries) == 1 and name:
        entries = [(name, entries[0][1])]
    LOCAL_DIR.mkdir(parents=True, exist_ok=True)
    added = []
    for n, bp in entries:
        s = encode(bp)
        if len(s) > MAX_STRING_CHARS:
            log.warning("Skipping %s: %d chars is over the %d cap", n, len(s), MAX_STRING_CHARS)
            continue
        info = analyze(bp)
        if category:
            info["category"] = category
        entry = {"name": n, "string": s, "hash": _hash(s), "source": source, **info}
        (LOCAL_DIR / f"{n}.json").write_text(json.dumps(entry, indent=1), encoding="utf-8")
        added.append(n)
    return added


def _fetch(url: str) -> str:
    m = re.search(r"factorioprints\.com/view/([-\w]+)", url)
    if m:
        # Factorio Prints keeps its data in a public Firebase database.
        api = f"https://facorio-blueprints.firebaseio.com/blueprints/{m.group(1)}.json"
        with urllib.request.urlopen(api, timeout=30) as r:
            data = json.loads(r.read())
        return data["blueprintString"]
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode().strip()


def ingest_from_game(output_dir: Path) -> list[str]:
    """Import blueprints the mod exported (/ai-bp add|book), then delete them."""
    d = output_dir / "blueprints"
    added: list[str] = []
    if not d.exists():
        return added
    for f in sorted(d.glob("*.json")):
        try:
            e = json.loads(f.read_text(encoding="utf-8"))
            if e.get("remove"):                       # /ai-bp remove <name>
                (LOCAL_DIR / f"{safe_name(e['remove'], 'x')}.json").unlink(missing_ok=True)
                f.unlink()
                continue
            name = safe_name(e.get("name"), "") or None
            added += add_string(e["string"], name, e.get("category") or None, source="game")
            f.unlink()
        except Exception as ex:      # one bad file must not block the rest
            log.warning("Could not import %s from game (moved to blueprints/failed/): %s", f.name, ex)
            try:
                (d / "failed").mkdir(exist_ok=True)
                f.replace(d / "failed" / f.name)
            except OSError:
                pass
    return added


# ---------------------------------------------------------------------------
# Sync to the mod
# ---------------------------------------------------------------------------

def _lua_str(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "") + "'"


def sync_to_mod(rcon, lib: dict[str, dict]) -> tuple[int, int]:
    """Push new/changed entries, drop ones no longer in the library.
    Returns (pushed, removed)."""
    raw = rcon.query_lua("rcon.print(helpers.table_to_json(remote.call('ai_player','bp_hashes')))")
    try:
        have = json.loads(raw) if raw else {}
    except ValueError:
        log.warning("Mod did not answer bp_hashes (old mod?): %s", (raw or "")[:120])
        return 0, 0
    if isinstance(have, list):     # an empty Lua table serialises as []
        have = {}
    pushed = removed = 0
    for name, e in lib.items():
        if have.get(name) == e["hash"]:
            continue
        s = e["string"]
        parts = [s[i:i + CHUNK_CHARS] for i in range(0, len(s), CHUNK_CHARS)]
        # items: what the build needs, so the mod can report which blueprints
        # are still locked by research.
        meta = json.dumps({
            **{k: e.get(k) for k in ("category", "placement", "resource", "label", "hash", "tileable", "tile_offset", "snap_grid", "size", "ports") if e.get(k) is not None},
            "items": sorted(e.get("cost") or {})
        })
        ok = True
        for i, part in enumerate(parts, 1):
            res = rcon.query_lua(
                f"rcon.print(remote.call('ai_player','bp_chunk',{_lua_str(name)},{i},{len(parts)},"
                f"{_lua_str(part)},{_lua_str(meta)},{len(s)}))")
            if res is None or (i == len(parts) and res.strip() != "ok"):
                log.warning("Pushing blueprint %s failed at chunk %d/%d: %s", name, i, len(parts), res)
                ok = False
                break
        pushed += ok
    for name in have:
        if name not in lib:
            rcon.query_lua(f"remote.call('ai_player','bp_remove',{_lua_str(name)})")
            removed += 1
    return pushed, removed


# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

def missing_items(entry: dict, inventory: list[dict]) -> dict[str, int]:
    have = {i.get("name"): i.get("count", 0) for i in inventory or []}
    return {k: v - have.get(k, 0) for k, v in entry.get("cost", {}).items() if v > have.get(k, 0)}


def get_tile_target(placed: list[dict], entry: dict) -> dict | None:
    """If entry is tileable and an instance was already placed on this surface,
    compute the adjacent snap coordinate from its tile_offset or snap_grid."""
    if not entry.get("tileable"):
        return None
    name = entry.get("name")
    matching = [p for p in (placed or []) if isinstance(p, dict) and p.get("name") == name and p.get("position")]
    if not matching:
        return None
    last_pos = matching[-1]["position"]
    offset = entry.get("tile_offset") or entry.get("snap_grid") or {}
    dx = offset.get("x", 0)
    dy = offset.get("y", 0)
    if dx == 0 and dy == 0:
        return None
    return {"x": last_pos["x"] + dx, "y": last_pos["y"] + dy}



# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

DIR_DELTAS = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}


def find_ports(bp_data: dict) -> list[dict]:
    """Compute ports (belt_in, belt_out, pipe) for a blueprint."""
    if "blueprint" in bp_data:
        bp = bp_data["blueprint"]
    elif "string" in bp_data:
        bp = decode(bp_data["string"])["blueprint"]
    else:
        return []

    ents = bp.get("entities") or []
    if not ents:
        return []

    # Map all belts
    belts = {}
    for e in ents:
        name = e.get("name", "")
        if "belt" in name and "loader" not in name:
            pos = (round(e["position"]["x"], 2), round(e["position"]["y"], 2))
            belts[pos] = e

    belt_ins = []
    belt_outs = []
    for pos, e in belts.items():
        x, y = pos
        d = e.get("direction", 0)
        dx, dy = DIR_DELTAS.get(d, (0, -1))
        is_ug = "underground-belt" in e.get("name", "")
        ug_type = e.get("type")

        # In port check
        if not (is_ug and ug_type == "output"):
            fed_by_belt = False
            for other_pos, other_e in belts.items():
                if other_pos == pos:
                    continue
                o_d = other_e.get("direction", 0)
                o_dx, o_dy = DIR_DELTAS.get(o_d, (0, -1))
                o_down = (round(other_pos[0] + o_dx, 2), round(other_pos[1] + o_dy, 2))
                if o_down == pos:
                    fed_by_belt = True
                    break
            if not fed_by_belt:
                belt_ins.append({"kind": "belt_in", "x": x, "y": y, "dir": d})

        # Out port check
        if not (is_ug and ug_type == "input"):
            down_pos = (round(x + dx, 2), round(y + dy, 2))
            if down_pos not in belts:
                belt_outs.append({"kind": "belt_out", "x": x, "y": y, "dir": d})

    # Pipe ports
    pipe_ports = []
    for e in ents:
        name = e.get("name", "")
        x = round(e["position"]["x"], 2)
        y = round(e["position"]["y"], 2)
        d = e.get("direction", 0)
        if name == "pipe":
            size_map = {"oil-refinery": (2.5, 2.5), "chemical-plant": (1.5, 1.5), "boiler": (1.5, 1.0)}
            machine_dir = None
            for p_dir, (p_dx, p_dy) in DIR_DELTAS.items():
                adj = (round(x + p_dx, 2), round(y + p_dy, 2))
                for other_e in ents:
                    oname = other_e.get("name", "")
                    if other_e is e or oname == "pipe" or oname not in size_map:
                        continue
                    hw, hh = size_map[oname]
                    ox = other_e["position"]["x"]
                    oy = other_e["position"]["y"]
                    if (ox - hw - 0.1) <= adj[0] <= (ox + hw + 0.1) and (oy - hh - 0.1) <= adj[1] <= (oy + hh + 0.1):
                        machine_dir = p_dir
                        break
                if machine_dir is not None:
                    break
            if machine_dir is not None:
                outward_dir = (machine_dir + 8) % 16
                pipe_ports.append({"kind": "pipe", "x": x, "y": y, "dir": outward_dir})
            else:
                pipe_ports.append({"kind": "pipe", "x": x, "y": y, "dir": 0})
        elif name == "boiler":
            if d in (0, 8):
                pipe_ports.append({"kind": "pipe", "x": round(x - 1.0, 2), "y": y, "dir": 12})
                pipe_ports.append({"kind": "pipe", "x": round(x + 1.0, 2), "y": y, "dir": 4})
            elif d in (4, 12):
                pipe_ports.append({"kind": "pipe", "x": x, "y": round(y - 1.0, 2), "dir": 0})
                pipe_ports.append({"kind": "pipe", "x": x, "y": round(y + 1.0, 2), "dir": 8})

    belt_ins.sort(key=lambda p: (p["y"], p["x"]))
    belt_outs.sort(key=lambda p: (p["y"], p["x"]))
    pipe_ports.sort(key=lambda p: (p["y"], p["x"]))

    ports = []
    for i, p in enumerate(belt_ins, 1):
        ports.append({"name": f"in{i}", **p})
    for i, p in enumerate(belt_outs, 1):
        ports.append({"name": f"out{i}", **p})
    for i, p in enumerate(pipe_ports, 1):
        ports.append({"name": f"pipe{i}", **p})

    old_ports = {p.get("name"): p for p in bp_data.get("ports", []) if isinstance(p, dict)}
    for p in ports:
        old = old_ports.get(p["name"])
        if old and "item" in old:
            p["item"] = old["item"]

    return ports


def main() -> None:
    ap = argparse.ArgumentParser(prog="python -m bridge.blueprints", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("import", help="import a blueprint/book from a file, URL or string")
    p.add_argument("source")
    p.add_argument("--name")
    p.add_argument("--category")
    sub.add_parser("list", help="list the library")
    sub.add_parser("ports", help="compute and write ports into each tileable JSON")
    p = sub.add_parser("remove", help="remove a local blueprint")
    p.add_argument("name")
    args = ap.parse_args()

    if args.cmd == "import":
        src = args.source
        if src.startswith(("http://", "https://")):
            text = _fetch(src)
        elif Path(src).exists():
            text = Path(src).read_text(encoding="utf-8").strip()
        else:
            text = src
        names = add_string(text, args.name, args.category)
        print(f"Imported {len(names)} blueprint(s) into {LOCAL_DIR}:")
        for n in names:
            e = json.loads((LOCAL_DIR / f"{n}.json").read_text(encoding="utf-8"))
            print(f"  {n:40s} {e['category']:18s} {e['placement']:10s} {e['entities']} entities")
    elif args.cmd == "list":
        lib = load_library(include_local=True)
        if not lib:
            print("Library is empty.")
        for n, e in sorted(lib.items()):
            print(f"  {n:40s} {e['category']:18s} {e['placement']:10s} {e['entities']:4d} entities  ({e['source']})")
    elif args.cmd == "remove":
        f = LOCAL_DIR / f"{args.name}.json"
        if not f.exists():
            sys.exit(f"No local blueprint named {args.name}")
        f.unlink()
        print(f"Removed {args.name}")
    elif args.cmd == "ports":
        for f in sorted(REPO_DIR.glob("tileable-*.json")):
            data = json.loads(f.read_text(encoding="utf-8"))
            ports = find_ports(data)
            data["ports"] = ports
            f.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            print(f"{f.stem} ({len(ports)} ports):")
            for pt in ports:
                it = f" [{pt['item']}]" if "item" in pt else ""
                print(f"  {pt['name']:6s} {pt['kind']:10s} ({pt['x']}, {pt['y']}) dir={pt['dir']}{it}")


if __name__ == "__main__":
    main()
