r"""Headless soak test: the AI plays a normal generated map from the start.

    .venv/Scripts/python tests/ingame/run_soak.py [--no-llm | --llm] [--minutes 60]
        [--speed 4] [--seed 424242] [--enemies] [--keep] [--out DIR] [--label NAME]
        [--combat defend|hunt] [--kill-bridge-at MINUTE] [--raids] [--mediums] [--nests N] [--nests-at MINUTE]

Like run_selftest.py (temp write-data, temp mods folder, loopback RCON with a random
password, refuses to start while any factorio.exe runs, never touches saves) but on a
real map: a headless server on a map made from --map-gen-settings, the AI spawned
over RCON, and the bridge run as a child process with its own throwaway env file
(BRIDGE_ENV_FILE), so bridge/.env is never read. Every game minute it samples the
mod's snapshot and, at the end, writes soak-report.md/.json plus copies of the logs.

  --no-llm (default)  AI_PROVIDER=stub: every decision is the autopilot or the planner.
  --llm               the real router model; game speed is forced to 1.
  --combat hunt       switch the AI to hunt mode (clears nests near home) after it spawns.
  --raids             every 10 game minutes send a few small biters at home (more each time).
  --mediums           with --raids: add medium biters (1 per raid from minute 20, 2 from 40).
  --nests N           put N small nests 90 tiles from home (the soak maps have none within 150
                      tiles), for the hunt mode; --nests-at MINUTE delays that (default: the start;
                      early nests wreck a 10-minute-old base). The AI is given a submachine gun and 100
                      magazines with the nests: the soak economy has no iron to craft them.
  --kill-bridge-at N  kill the bridge process at game minute N and play on: the reflexes
                      (guard, light tend, auto-research) must carry the AI without it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1]))

import run_selftest as rs                                    # noqa: E402
from bridge import goals                                     # noqa: E402

SEEDS = [424242, 2476103329, 1873625901, 3598211047]                   # must match SEEDS in selftest.lua
DEFAULT_OUT = HERE / "soak-out"            # git-ignored
ROUTER = "http://127.0.0.1:11440/v1"
LLM_MODEL = "sol-fast"
BASE_TIMEOUT = 240            # bridge AI_TIMEOUT at speed 1 (seconds)
TICKS_PER_MIN = 3600
PYTHON = str(rs.REPO / ".venv" / "Scripts" / "python.exe")


def router_up() -> bool:
    try:
        with urllib.request.urlopen(ROUTER + "/models", timeout=4) as r:
            return r.status == 200
    except Exception:
        return False


def make_map_settings(seed: int, enemies: bool) -> dict:
    s = json.loads((rs.FACTORIO_DIR / "data" / "map-gen-settings.example.json").read_text(encoding="utf8"))
    s["seed"] = seed
    ctl = s.setdefault("autoplace_controls", {})
    ctl["enemy-base"] = {"frequency": 1, "size": 1 if enemies else 0, "richness": 1}
    return s


def write_env(path: Path, out_dir: Path, rport: int, password: str, llm: bool, speed: float) -> None:
    lines = {
        "FACTORIO_OUTPUT_DIR": str(out_dir),
        "FACTORIO_RCON_HOST": "127.0.0.1", "FACTORIO_RCON_PORT": str(rport),
        "FACTORIO_RCON_PASSWORD": password,
        "AI_PROVIDER": "lmstudio" if llm else "stub",
        # Request expiry counts game ticks: at speed N the same game time passes N times
        # faster, so give the mod N times the seconds.
        "AI_TIMEOUT": str(int((60 if llm else BASE_TIMEOUT) * max(speed, 1))),
        "BRIDGE_VERBOSE": "0",
    }
    if llm:
        lines.update(AI_MODEL=LLM_MODEL, LM_STUDIO_URL=ROUTER, AI_ENABLE_THINKING="false")
    path.write_text("\n".join(f"{k}={v}" for k, v in lines.items()) + "\n", encoding="utf8")


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf8"))
    except (OSError, ValueError):
        return None


def tail(path: Path, n: int = 40) -> list[str]:
    try:
        return path.read_text(encoding="utf8", errors="replace").splitlines()[-n:]
    except OSError:
        return []


def norm(detail: str) -> str:
    """Failure text without numbers/coordinates, so repeats group together."""
    d = re.sub(r"-?\d+(\.\d+)?", "#", str(detail))
    return re.sub(r"\s+", " ", d)[:160]


# --- sampling -----------------------------------------------------------------

def sample_from(snap: dict) -> dict | None:
    p = snap.get("perception")
    if not p:
        return None
    done = [m.id for m in goals.LADDER if m.done(p)]
    cur = goals.current(p)
    prod = (p.get("production") or {}).get("items") or {}
    rate = lambda k: int((prod.get(k) or {}).get("per_min", 0))     # noqa: E731
    fac = p.get("factory") or {}
    return {
        "tick": snap["tick"], "minute": round(snap["tick"] / TICKS_PER_MIN, 1),
        "goal": cur[1].id if cur else "done", "milestones": done,
        "iron_per_min": rate("iron-plate"), "copper_per_min": rate("copper-plate"),
        "red_per_min": rate("automation-science-pack"), "green_per_min": rate("logistic-science-pack"),
        "techs": int((p.get("production") or {}).get("techs_researched") or 0),
        "researched": sorted((p.get("research") or {}).get("done") or []),
        "research_current": (p.get("research") or {}).get("current"),
        "factory_total": int(fac.get("total") or 0), "by_type": fac.get("by_type") or {},
        "miners": fac.get("miners_by_resource") or {},
        "assembler_recipes": sorted({a.get("recipe") for a in fac.get("assemblers") or [] if a.get("recipe")}),
        "has_grid": bool((p.get("power") or {}).get("has_grid")),
        "assemblers": [f"{a.get('recipe')}:{a.get('status')}" for a in fac.get("assemblers") or [] if isinstance(a, dict)],
        "labs": [m.get("status") for m in fac.get("machines") or [] if isinstance(m, dict) and m.get("type") == "lab"],
        "attention": [f"{a.get('name')}:{a.get('status')}@{(a.get('position') or {}).get('x')},{(a.get('position') or {}).get('y')}"
                      for a in (fac.get("attention") or [])[:8] if isinstance(a, dict)],
        "health_pct": (p.get("character") or {}).get("health_pct"),
        "position": (p.get("character") or {}).get("position"),
        "assembler_products": snap.get("assembler_products") or {},
        "enemies_seen": snap.get("enemies_seen"), "lost": snap.get("lost") or {},
        "spawners_home": snap.get("spawners_home"), "reflex": snap.get("reflex") or {},
        "kills": snap.get("kills_in"), "kills_out": snap.get("kills_out"), "magazines": snap.get("magazines"),
        "unfuelled": snap.get("furnaces_unfuelled"), "combat_mode": snap.get("combat_mode"),
        "hand_hauls_last_30m": snap.get("hand_hauls_last_30m", 0),
        "flow_faults_last_30m": snap.get("flow_faults_last_30m", 0),
        "bus_head_fed": bool((p.get("base") or {}).get("head_fed")),
        "inventory": {i["name"]: i["count"] for i in (p.get("inventory") or [])[:40]
                      if isinstance(i, dict) and i.get("name")},
    }


def milestone_times(samples: list[dict]) -> dict[str, float | None]:
    """Game minute each ladder step (and a few extras) was first seen done."""
    out: dict[str, float | None] = {m.id: None for m in goals.LADDER[:8]}
    out["automation-researched"] = None
    out["electric-mining-drill-researched"] = None
    out["first-mining-field"] = None
    out["bus-head-fed"] = None
    out["red-producing"] = None
    out["lab-row-consuming"] = None
    out["green-producing"] = None
    out["red-cell-built"] = None
    out["red-cell-produced"] = None
    for s in samples:
        for mid in s["milestones"]:
            if mid in out and out[mid] is None:
                out[mid] = s["minute"]
        if out["automation-researched"] is None and "automation" in s["researched"]:
            out["automation-researched"] = s["minute"]
        if out["electric-mining-drill-researched"] is None and "electric-mining-drill" in s["researched"]:
            out["electric-mining-drill-researched"] = s["minute"]
        if out["first-mining-field"] is None and (s.get("by_type", {}).get("mining-drill", 0) > 0 and (s.get("iron_per_min", 0) > 0 or s.get("copper_per_min", 0) > 0)):
            out["first-mining-field"] = s["minute"]
        if out["bus-head-fed"] is None and s.get("bus_head_fed"):
            out["bus-head-fed"] = s["minute"]
        if out["red-producing"] is None and (s.get("red_per_min", 0) > 0 or s.get("assembler_products", {}).get("automation-science-pack", 0) > 0):
            out["red-producing"] = s["minute"]
        if out["lab-row-consuming"] is None and len(s.get("labs", [])) >= 4 and any(st == "working" for st in s.get("labs", [])):
            out["lab-row-consuming"] = s["minute"]
        if out["green-producing"] is None and (s.get("green_per_min", 0) > 0 or s.get("assembler_products", {}).get("logistic-science-pack", 0) > 0):
            out["green-producing"] = s["minute"]
        if out["red-cell-built"] is None and "automation-science-pack" in s["assembler_recipes"]:
            out["red-cell-built"] = s["minute"]
        working = "automation-science-pack:working" in s["assemblers"]     # fallback when the mod has no product counts
        if out["red-cell-produced"] is None and (s["assembler_products"].get("automation-science-pack", 0) > 0 or working):
            out["red-cell-produced"] = s["minute"]
    return out


def longest_stall(samples: list[dict]) -> tuple[float, float]:
    """(minutes, starting at minute) of the longest stretch with no new milestone, tech,
    machine or plate-rate record."""
    best, best_at, last_change, last_key = 0.0, 0.0, 0.0, None
    peak_iron = 0
    for s in samples:
        peak_iron = max(peak_iron, s["iron_per_min"])
        key = (len(s["milestones"]), s["techs"], s["factory_total"], peak_iron)
        if key != last_key:
            if s["minute"] - last_change > best:
                best, best_at = s["minute"] - last_change, last_change
            last_key, last_change = key, s["minute"]
    end = samples[-1]["minute"] if samples else 0
    if end - last_change > best:
        best, best_at = end - last_change, last_change
    return round(best, 1), round(best_at, 1)


def bridge_stats(out_dir: Path, llm: bool) -> dict:
    rows = []
    for l in tail(out_dir / "metrics.jsonl", 100000):
        try:
            rows.append(json.loads(l))
        except ValueError:
            pass
    # Without --llm the "model" is the stub, which only echoes the planner's suggestions.
    src = Counter(r.get("source") if r.get("source") == "autopilot" else ("llm" if llm else "stub")
                  for r in rows)
    overrides = sum(1 for l in tail(out_dir / "bridge.log", 200000) if "override:" in l)
    fails: dict[str, dict] = {}
    for r in rows:
        for d in r.get("failed_detail") or []:
            k = norm(d)
            e = fails.setdefault(k, {"count": 0, "sample": str(d)[:300], "first_tick": r.get("tick"),
                                     "source": r.get("source")})
            e["count"] += 1
    bad = sum(1 for r in rows if r.get("status") != "ok")
    return {"turns": len(rows), "source": dict(src), "overrides": overrides, "bad_status": bad,
            "failures": fails}


def mod_errors(out_dir: Path) -> list[str]:
    seen, out = set(), []
    for l in tail(out_dir / "debug.jsonl", 100000):
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if e.get("kind") == "error":
            k = norm(str(e.get("error"))[:120])
            if k not in seen:
                seen.add(k)
                out.append(str(e.get("error"))[:600])
    return out[:8]


def skill_failures(out_dir: Path) -> dict:
    """Failed skill/action events from the mod's debug trail, grouped."""
    fails: dict[str, dict] = {}
    for l in tail(out_dir / "debug.jsonl", 200000):
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if e.get("kind") in ("skill", "action") and e.get("ok") is False:
            name = e.get("name") or e.get("skill") or e.get("action") or "?"
            k = f"{name}: {norm(e.get('detail') or e.get('error') or '')}"
            f = fails.setdefault(k, {"count": 0, "sample": str(e.get("detail") or e.get("error"))[:300],
                                     "first_minute": round((e.get("tick") or 0) / TICKS_PER_MIN, 1)})
            f["count"] += 1
    return fails


def kill_summary(samples: list[dict], killed_at: float | None) -> dict | None:
    """What the AI did after the bridge was killed (reflexes only)."""
    if killed_at is None:
        return None
    before = [s for s in samples if s["minute"] <= killed_at]
    after = [s for s in samples if s["minute"] > killed_at]
    if not before or not after:
        return {"killed_at": killed_at, "note": "no samples on one side of the kill"}
    first, last = before[-1], after[-1]
    return {
        "killed_at": killed_at, "minutes_after": round(last["minute"] - killed_at, 1),
        "techs_at_kill": first["techs"], "techs_end": last["techs"],
        "research_queued_samples": f"{sum(1 for s in after if s['research_current'])}/{len(after)}",
        "unfuelled_max_after": max((s["unfuelled"] or 0) for s in after),
        "unfuelled_end": last["unfuelled"],
        "kills_at_kill": first["kills"], "kills_end": last["kills"],
        "bridge_offline_seen": any((s["reflex"] or {}).get("bridge_offline") for s in after),
        "reflex_states_after": sorted({(s["reflex"] or {}).get("state", "?") for s in after}),
        "ai_deaths_after": ((last["reflex"] or {}).get("deaths") or 0) - ((first["reflex"] or {}).get("deaths") or 0),
        "last_research": (last["reflex"] or {}).get("last_research"),
        "magazines_at_kill": first["magazines"], "magazines_end": last["magazines"],
    }


def combat_summary(samples: list[dict]) -> dict:
    """Entities lost, AI deaths and nests over the whole run."""
    if not samples:
        return {}
    last = samples[-1]
    rf = last["reflex"] or {}
    homes = [s["spawners_home"] for s in samples if s["spawners_home"] is not None]
    return {
        "entities_lost": last["lost"], "entities_lost_total": sum((last["lost"] or {}).values()),
        "ai_deaths": rf.get("deaths", 0), "nests_cleared": rf.get("nests_cleared", 0),
        "hunts_done": rf.get("hunts_done", 0), "combat_mode": last["combat_mode"],
        "spawners_near_home_start": homes[0] if homes else None, "spawners_near_home_end": homes[-1] if homes else None,
        "kills": last["kills"], "reflex_states_seen": sorted({(s["reflex"] or {}).get("state", "?") for s in samples}),
    }


# --- report -------------------------------------------------------------------

def evaluate(samples: list[dict], times: dict, bstats: dict | None = None, errors: list[str] | None = None) -> dict:
    last = samples[-1] if samples else {}
    built = times.get("red-cell-built")
    red_rate = max((s["red_per_min"] for s in samples if built is not None and s["minute"] >= built), default=0)
    bar = {
        "bootstrap": times.get("bootstrap") is not None,
        "power": times.get("power") is not None,
        "automation researched": times.get("automation-researched") is not None,
        "red cell working": times.get("red-cell-produced") is not None and red_rate > 0,
    }

    last_min = last.get("minute", 0)
    last_10 = [s for s in samples if s["minute"] >= last_min - 10] or ([last] if last else [])

    def mean_rate(key):
        vals = [s.get(key, 0) for s in last_10]
        return round(sum(vals) / max(1, len(vals)), 2)

    turns_total = (bstats or {}).get("turns", 0)
    turns_auto = ((bstats or {}).get("source") or {}).get("autopilot", 0)
    auto_share = round(turns_auto / max(1, turns_total), 3) if turns_total > 0 else 0.0

    att_count = len(last.get("attention") or [])
    fac_total = last.get("factory_total") or 1
    att_share = round(att_count / max(1, fac_total), 3)

    score = {
        "milestones": {
            "power": times.get("power"),
            "electric-mining-drill": times.get("electric-mining-drill-researched"),
            "first_mining_field": times.get("first-mining-field"),
            "bus_head_fed": times.get("bus-head-fed"),
            "red_producing": times.get("red-producing"),
            "lab_row_consuming": times.get("lab-row-consuming"),
            "green_producing": times.get("green-producing"),
        },
        "rates_last_10m": {
            "iron_per_min": mean_rate("iron_per_min"),
            "copper_per_min": mean_rate("copper_per_min"),
            "red_per_min": mean_rate("red_per_min"),
            "green_per_min": mean_rate("green_per_min"),
        },
        "techs_researched": last.get("techs", 0),
        "flow_faults_last_30m": last.get("flow_faults_last_30m", 0),
        "attention_share": att_share,
        "hand_hauled_last_30m": last.get("hand_hauls_last_30m", 0),
        "mod_errors": len(errors or []),
        "autopilot_share": auto_share,
    }

    return {
        "bar": bar,
        "passed": all(bar.values()),
        "final": {k: last.get(k) for k in ("minute", "goal", "iron_per_min", "copper_per_min", "red_per_min", "techs", "factory_total")},
        "score": score,
    }


def write_report(out_dir: Path, out: Path, args, samples, bstats, times, ev, errors, stall, notes,
                 killed_at=None) -> Path:
    fails = [{**v, "what": k, "kind": "bridge"} for k, v in bstats["failures"].items()]
    sfails = [{**v, "what": k, "kind": "skill"} for k, v in skill_failures(out_dir).items()]
    # The bridge sees each failure one turn after the mod logs it: show one list, preferring the mod's.
    top = sorted(sfails or fails, key=lambda x: -x["count"])[:10]
    data = {"label": args.label, "mode": "llm" if args.llm else "no-llm", "seed": args.seed,
            "enemies": args.enemies, "speed": args.speed, "milestones": times, "evaluation": ev,
            "bridge": {k: v for k, v in bstats.items() if k != "failures"}, "stall": stall,
            "combat": combat_summary(samples), "bridge_killed": kill_summary(samples, killed_at),
            "top_failures": top, "mod_errors": errors, "notes": notes, "samples": samples}
    (out / f"soak-report-{args.label}.json").write_text(json.dumps(data, indent=1), encoding="utf8")

    L = [f"# Soak report: {args.label}", "",
         f"mode {data['mode']}, seed {args.seed}, enemies {args.enemies}, speed {args.speed}x, "
         f"reached game minute {ev['final'].get('minute')}",
         f"**Pass bar (bootstrap, power, automation researched, red cell working): "
         f"{'MET' if ev['passed'] else 'NOT MET'}** " + ", ".join(
             f"{k}={'yes' if v else 'NO'}" for k, v in ev["bar"].items()), "",
         "## Milestone timeline (game minute first seen)"]
    for k, v in times.items():
        L.append(f"- {k}: {v if v is not None else 'never'}")
    b = data["bridge"]
    L += ["", "## Turns", f"- total {b['turns']}, by source {b['source']}, coach overrides {b['overrides']}, "
          f"non-ok replies {b['bad_status']}",
          f"- longest stretch with no progress: {stall[0]} min starting at minute {stall[1]}",
          "", "## Plates and science per minute (every 5 game minutes)",
          "| min | goal | iron | copper | red | green | techs | machines | red cell |",
          "|---|---|---|---|---|---|---|---|---|"]
    rows = samples[::5] + ([samples[-1]] if samples and (len(samples) - 1) % 5 else [])
    for s in rows:
        L.append(f"| {s['minute']} | {s['goal']} | {s['iron_per_min']} | {s['copper_per_min']} | "
                 f"{s['red_per_min']} | {s['green_per_min']} | {s['techs']} | {s['factory_total']} | "
                 f"{', '.join(a for a in s['assemblers'] if 'science' in a) or '-'} |")
    L += ["", "## Combat and reflexes"] + [f"- {k}: {v}" for k, v in data["combat"].items()]
    if data["bridge_killed"]:
        L += ["", "## After the bridge was killed"] + [f"- {k}: {v}" for k, v in data["bridge_killed"].items()]
    L += ["", "## Top failures"]
    for f in top:
        L.append(f"- x{f['count']} [{f['kind']}] {f['what']} -- e.g. {f['sample']}")
    if not top:
        L.append("- none")
    if errors:
        L += ["", "## Mod Lua errors"] + [f"- {e.splitlines()[0]}" for e in errors]
    if notes:
        L += ["", "## Notes"] + [f"- {n}" for n in notes]
    path = out / f"soak-report-{args.label}.md"
    path.write_text("\n".join(L) + "\n", encoding="utf8")
    shutil.copyfile(path, out / "soak-report.md")
    shutil.copyfile(out / f"soak-report-{args.label}.json", out / "soak-report.json")
    return path


# --- main ---------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-llm", action="store_true")
    ap.add_argument("--llm", action="store_true")
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--speed", type=float, default=4)
    ap.add_argument("--seed", type=int, default=SEEDS[0])
    ap.add_argument("--enemies", action="store_true")
    ap.add_argument("--combat", choices=["defend", "hunt"], default="defend")
    ap.add_argument("--kill-bridge-at", type=float, default=0, help="kill the bridge at this game minute (0 = never)")
    ap.add_argument("--raids", action="store_true")
    ap.add_argument("--mediums", action="store_true", help="--raids also sends medium biters (1 at minute 20, 2 from 40)")
    ap.add_argument("--nests", type=int, default=0)
    ap.add_argument("--nests-at", type=float, default=0)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--label", default=time.strftime("%H%M%S"))
    ap.add_argument("--stall-min", type=int, default=25,
                    help="stop early after this many game minutes with no progress (0 = never)")
    ap.add_argument("--max-real-min", type=int, default=150, help="give up after this many real minutes")
    args = ap.parse_args()
    if args.seed not in SEEDS:
        print(f"seed must be one of {SEEDS} (the mod only arms these)")
        return 2
    if args.llm:
        args.speed = 1.0                    # request expiry counts game ticks; the model needs real time
        if not router_up():
            print(f"router at {ROUTER} does not answer - not starting --llm")
            return 2
    args.speed = max(0.25, min(4.0, args.speed))
    if not rs.EXE.exists():
        print(f"factorio.exe not found at {rs.EXE}")
        return 2
    if rs.factorio_running():
        print("factorio.exe is already running (game or server) - close it first. Not starting.")
        return 2
    from factorio_rcon import RCONClient

    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="ai-soak-"))
    write_data = tmp / "data"
    write_data.mkdir()
    out_dir = write_data / "script-output" / "ai-player"
    cfg = tmp / "config.ini"
    cfg.write_text(f"[path]\nread-data={rs.FACTORIO_DIR / 'data'}\nwrite-data={write_data}\n")
    save = tmp / "soak.zip"
    common = [str(rs.EXE), "-c", str(cfg), "--mod-directory", str(rs.prepare_mods(tmp))]
    (tmp / "map-gen-settings.json").write_text(json.dumps(make_map_settings(args.seed, args.enemies)))

    print("creating map ...", flush=True)
    r = subprocess.run(common + ["--create", str(save), "--map-gen-settings", str(tmp / "map-gen-settings.json")],
                       capture_output=True, text=True, timeout=600)
    if r.returncode != 0 or not save.exists():
        print("map creation failed:\n" + (r.stdout + r.stderr)[-1500:])
        shutil.rmtree(tmp, ignore_errors=True)
        return 2

    settings = json.loads((rs.FACTORIO_DIR / "data" / "server-settings.example.json").read_text(encoding="utf8"))
    settings.update(auto_pause=False, require_user_verification=False, autosave_interval=0,
                    max_players=0, autosave_only_on_server=True)
    settings["visibility"] = {"public": False, "lan": False}
    (tmp / "server-settings.json").write_text(json.dumps(settings))
    port, rport = rs.free_port(udp=True), rs.free_port()
    password = secrets.token_hex(8)
    log = open(tmp / "server.log", "w")
    server = subprocess.Popen(
        common + ["--start-server", str(save), "--server-settings", str(tmp / "server-settings.json"),
                  "--bind", "127.0.0.1", "--port", str(port),
                  "--rcon-bind", f"127.0.0.1:{rport}", "--rcon-password", password],
        stdout=log, stderr=subprocess.STDOUT)
    bridge = None
    bridge_log = None
    samples: list[dict] = []
    notes: list[str] = []
    killed_at = None
    try:
        client = None
        t0 = time.time()
        while time.time() - t0 < rs.BOOT_TIMEOUT:
            if server.poll() is not None:
                print("server exited early:\n" + "\n".join(tail(tmp / "server.log", 20)))
                return 2
            try:
                client = RCONClient("127.0.0.1", rport, password)
                break
            except Exception:
                time.sleep(2)
        if client is None:
            print("RCON never came up")
            return 2

        env_file = tmp / "bridge.env"
        write_env(env_file, out_dir, rport, password, args.llm, args.speed)
        env = {**os.environ, "BRIDGE_ENV_FILE": str(env_file), "PYTHONIOENCODING": "utf-8"}
        bridge_log = open(tmp / "bridge-stdout.log", "w")
        bridge = subprocess.Popen([PYTHON, "-m", "bridge.main"], cwd=str(rs.REPO), env=env,
                                  stdout=bridge_log, stderr=subprocess.STDOUT)
        time.sleep(6)
        client.send_command("/ai-soak-start")
        client.send_command("/spawn-ai-player")
        client.send_command(f"/ai-soak-speed {args.speed}")
        if args.combat == "hunt":
            client.send_command("/sc rcon.print(remote.call('ai_player','set_combat_mode','hunt'))")
        print(f"soak {args.label}: seed {args.seed}, {args.minutes} game min at {args.speed}x "
              f"({'llm' if args.llm else 'stub'}), enemies={args.enemies}", flush=True)

        snap_file = out_dir / "soak_snapshot.json"
        next_tick = TICKS_PER_MIN
        next_raid = 10 * TICKS_PER_MIN
        nests_sent = not args.nests
        started = time.time()
        while True:
            if server.poll() is not None:
                notes.append("server exited during the soak (Lua crash?): " + " | ".join(tail(tmp / "server.log", 6))[:500])
                break
            if bridge.poll() is not None and killed_at is None:
                notes.append("bridge process exited during the soak")
                break
            if time.time() - started > args.max_real_min * 60:
                notes.append(f"stopped after {args.max_real_min} real minutes")
                break
            try:
                tick = int(client.send_command("/sc rcon.print(game.tick)").strip())
            except Exception as e:        # noqa: BLE001
                notes.append(f"RCON poll failed: {e}")
                time.sleep(3)
                try:
                    client = RCONClient("127.0.0.1", rport, password)
                except Exception:
                    break
                continue
            if not nests_sent and tick >= args.nests_at * TICKS_PER_MIN:
                client.send_command(f"/ai-soak-nests {args.nests} 90")
                nests_sent = True
                notes.append(f"{args.nests} nest(s) placed 90 tiles from home at game minute {args.nests_at:g}")
            if args.raids and tick >= next_raid:
                med = (0 if tick < 20 * TICKS_PER_MIN else 1 if tick < 40 * TICKS_PER_MIN else 2) if args.mediums else 0
                client.send_command(f"/ai-soak-raid {4 + tick // (10 * TICKS_PER_MIN)} {med}")
                next_raid += 10 * TICKS_PER_MIN
            if tick >= next_tick:
                snap_file.unlink(missing_ok=True)
                client.send_command("/ai-soak-snapshot")
                snap = None
                for _ in range(20):
                    snap = read_json(snap_file)
                    if snap:
                        break
                    time.sleep(0.25)
                s = sample_from(snap) if snap else None
                if s and args.kill_bridge_at and killed_at is None and s["minute"] >= args.kill_bridge_at:
                    bridge.kill()                  # no goodbye: the mod just stops hearing from it
                    killed_at = s["minute"]
                    notes.append(f"bridge killed at game minute {killed_at}")
                    print(f"  bridge killed at minute {killed_at}", flush=True)
                if s:
                    samples.append(s)
                    if len(samples) % 5 == 0 or len(samples) == 1:
                        print(f"  min {s['minute']:>5}  goal {s['goal']:<10} iron {s['iron_per_min']:>3} "
                              f"copper {s['copper_per_min']:>3} red {s['red_per_min']:>3} techs {s['techs']:>2} "
                              f"machines {s['factory_total']:>3}  real {int(time.time() - started)}s", flush=True)
                elif snap and snap.get("error"):
                    notes.append("snapshot error: " + str(snap["error"])[:200])
                next_tick = tick + TICKS_PER_MIN
                if tick >= args.minutes * TICKS_PER_MIN:
                    break
                if args.stall_min and samples:
                    stalled, since = longest_stall(samples)
                    if stalled >= args.stall_min and since + stalled >= samples[-1]["minute"] - 1:
                        notes.append(f"stopped early: no progress for {stalled} game minutes since minute {since}")
                        break
            time.sleep(2 if args.speed >= 2 else 3)
        try:
            client.send_command("/quit")
        except Exception:
            pass
    finally:
        if bridge and bridge.poll() is None:
            bridge.terminate()
            try:
                bridge.wait(timeout=10)
            except subprocess.TimeoutExpired:
                bridge.kill()
        if bridge_log:
            bridge_log.close()
        try:
            server.wait(timeout=30)
        except subprocess.TimeoutExpired:
            server.kill()
        log.close()
        if server.poll() is None:
            server.kill()

    # Report (the server's script-output is still there until tmp is deleted).
    bstats = bridge_stats(out_dir, args.llm)
    times = milestone_times(samples)
    errors = mod_errors(out_dir)
    ev = evaluate(samples, times, bstats=bstats, errors=errors)
    stall = longest_stall(samples)
    path = write_report(out_dir, out, args, samples, bstats, times, ev, errors, stall, notes, killed_at)
    for name in ("bridge.log", "debug.jsonl", "metrics.jsonl", "errors.log"):
        if (out_dir / name).exists():
            shutil.copyfile(out_dir / name, out / f"{args.label}-{name}")
    # The server log's first line is its command line, which holds the RCON password.
    (out / f"{args.label}-server.log").write_text(
        "".join(l for l in (tmp / "server.log").read_text(encoding="utf8", errors="replace").splitlines(True)
                if "Program arguments" not in l and password not in l), encoding="utf8")
    print(f"report: {path}")
    print("pass bar " + ("MET" if ev["passed"] else "NOT MET") + "  " + json.dumps(ev["bar"]))
    print("combat " + json.dumps(combat_summary(samples)))
    if killed_at is not None:
        print("after bridge kill " + json.dumps(kill_summary(samples, killed_at)))
    if args.keep:
        print(f"kept {tmp}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0 if (ev["passed"] or bool(ev.get("score"))) else 1


if __name__ == "__main__":
    sys.exit(main())
