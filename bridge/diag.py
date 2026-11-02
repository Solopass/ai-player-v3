"""
One-command health check: what is the AI doing, and where is it going wrong?

    python -m bridge.diag              # readable report
    python -m bridge.diag --events 60  # more mod events
    python -m bridge.diag --json       # everything as JSON (for tools / Claude)

Pulls together, in order:
  1. Setup      — model, endpoint, schema/goal flags, local router mode
  2. Model      — is the endpoint up and the model known
  3. Mod        — live snapshot over RCON (remote.call ai_player.diag):
                  character, brain state, pending requests, last results,
                  library size, what the bridge last told the panel
  4. Events     — tail of script-output/ai-player/debug.jsonl (mod side:
                  requests, skill results, placement attempts and why spots
                  were rejected, Lua errors with tracebacks)
  5. Errors     — tail of errors.log (mod) and warnings in bridge.log
  6. Last turn  — the last prompt's goal section, the model's reply, and
                  what was parsed (chat.log)
  7. Turns      — status counts and latency from metrics.jsonl

Also provides rotate_logs(), which main.py calls so the log files in
script-output don't grow without bound.
"""

import argparse
import json
import sys
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
import time
import urllib.request
from collections import Counter
from pathlib import Path

from .config import ConfigLoader

# file -> max bytes before it's moved to <name>.1 (one old copy kept)
_ROTATE = {"debug.jsonl": 5_000_000, "chat.log": 20_000_000,
           "metrics.jsonl": 20_000_000, "errors.log": 5_000_000}

# Optional: a JSON file describing the local model router's mode
# ({"mode", "since", "reason"}), e.g. one written by a script that unloads
# models while games run. Set AI_ROUTER_STATE in bridge/.env to show it.
def _router_state_path(env: dict) -> Path | None:
    p = env.get("AI_ROUTER_STATE")
    return Path(p) if p else None


def rotate_logs(output_dir: Path, max_backups: int = 3) -> None:
    for name, limit in _ROTATE.items():
        p = Path(output_dir) / name
        try:
            if p.exists() and p.stat().st_size > limit:
                for i in range(max_backups - 1, 0, -1):
                    src = p.with_name(f"{name}.{i}")
                    dst = p.with_name(f"{name}.{i+1}")
                    if src.exists():
                        src.replace(dst)
                p.replace(p.with_name(name + ".1"))
        except OSError:
            pass   # the game may have it open this instant; try next time


def _tail_lines(path: Path, n: int) -> list[str]:
    if not path.exists():
        return []
    with path.open("rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 400_000))
        data = fh.read().decode("utf-8", "replace")
    return data.splitlines()[-n:]


def _last_exchange(chat_log: Path) -> dict:
    lines = _tail_lines(chat_log, 400)
    starts = [i for i, l in enumerate(lines) if l.startswith("=" * 20)]
    if not starts:
        return {}
    block = lines[starts[-1]:]
    out = {"header": block[1] if len(block) > 1 else ""}
    section = None
    for l in block:
        if l.startswith("CURRENT GOAL") or l.startswith("GOAL:"):
            out["goal"] = l
        if l.startswith("--- RESPONSE"):
            section = "reply"; out["reply"] = []; out["reply_header"] = l; continue
        if l.startswith("--- PARSED"):
            out["parsed"] = l; section = None; continue
        if l.startswith("--- PROMPT"):
            section = None
        if section == "reply":
            out["reply"].append(l)
    if "reply" in out:
        out["reply"] = "\n".join(out["reply"]).strip()
    return out


def _fmt_event(e: dict) -> str:
    secs = int((e.get("tick") or 0) / 60)
    stamp = f"{secs // 3600}:{secs // 60 % 60:02d}:{secs % 60:02d}"
    kind = e.get("kind", "?")
    what = e.get("name") or e.get("skill") or e.get("action") or e.get("req_id") or ""
    ok = {True: "OK", False: "FAILED"}.get(e.get("ok"), "")
    rest = {k: v for k, v in e.items()
            if k not in ("tick", "kind", "name", "skill", "action", "req_id", "ok", "entry")}
    detail = rest.pop("detail", None) or rest.pop("error", None)
    detail = str(detail).splitlines()[0] if detail else detail   # tracebacks print separately
    s = f"{stamp} [{kind}] {what} {ok}".rstrip()
    if detail:
        s += f" — {detail}"
    if rest:
        s += "  " + json.dumps(rest, separators=(",", ":"))[:400]
    return s


def collect(n_events: int = 25, all_sessions: bool = False) -> dict:
    loader = ConfigLoader()
    cfg = loader.get()
    out_dir = Path(cfg.output_dir)
    report: dict = {"time": time.strftime("%Y-%m-%d %H:%M:%S")}

    pc = cfg.to_provider_config()
    report["setup"] = {
        "output_dir": str(out_dir), "provider": pc.provider, "model": pc.model, "url": pc.url,
        "json_schema": cfg.json_schema, "goals": cfg.goals, "enable_thinking": cfg.enable_thinking,
        "timeout_s": cfg.timeout, "rcon": f"{cfg.rcon.host}:{cfg.rcon.port}",
    }
    state = _router_state_path(loader._env)
    if state:
        try:
            report["setup"]["router_mode"] = json.loads(state.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            pass

    try:
        with urllib.request.urlopen(pc.url.rstrip("/") + "/models", timeout=4) as r:
            models = json.loads(r.read()).get("data", [])
        m = next((x for x in models if x.get("id") == pc.model), None)
        report["model"] = {"reachable": True, "known": m is not None,
                           "state": (m or {}).get("status", {}).get("value")}
    except Exception as e:      # noqa: BLE001
        report["model"] = {"reachable": False, "error": str(e)[:200]}

    try:
        from .factorio.rcon import RCONGateway
        gw = RCONGateway(cfg.rcon.host, cfg.rcon.port, cfg.rcon.password)
        if gw.connect():
            raw = gw.query_lua("rcon.print(helpers.table_to_json(remote.call('ai_player','diag')))")
            gw.disconnect()
            report["mod"] = json.loads(raw) if raw else {"ok": False, "detail": "empty reply"}
        else:
            report["mod"] = {"ok": False, "detail": "RCON not reachable — is Factorio hosting with RCON on?"}
    except Exception as e:      # noqa: BLE001
        report["mod"] = {"ok": False, "detail": f"diag call failed (old mod loaded?): {e}"}

    raw_events = []
    current_session_id = None
    latest_session = {}
    for l in _tail_lines(out_dir / "debug.jsonl", 1000 if not all_sessions else n_events):
        try:
            ev = json.loads(l)
            if ev.get("kind") == "session_start":
                latest_session = ev
                current_session_id = ev.get("session_id")
            elif ev.get("session_id"):
                current_session_id = ev.get("session_id")
            raw_events.append(ev)
        except ValueError:
            pass

    if not all_sessions and current_session_id:
        events = [e for e in raw_events if e.get("session_id") == current_session_id]
    else:
        events = raw_events

    report["session"] = latest_session or ({"session_id": current_session_id} if current_session_id else {})
    report["events"] = events[-n_events:]
    report["errors_log"] = _tail_lines(out_dir / "errors.log", 10)
    report["bridge_warnings"] = [l for l in _tail_lines(out_dir / "bridge.log", 2000)
                                 if "[WARNING]" in l or "[ERROR]" in l][-15:]
    report["last_exchange"] = _last_exchange(out_dir / "chat.log")

    turns = []
    for l in _tail_lines(out_dir / "metrics.jsonl", 50):
        try:
            turns.append(json.loads(l))
        except ValueError:
            pass
    if turns:
        lat = [t.get("elapsed_s") or 0 for t in turns]
        report["turns"] = {"last_n": len(turns), "status": dict(Counter(t.get("status") for t in turns)),
                           "avg_s": round(sum(lat) / len(lat), 1), "max_s": max(lat),
                           "source": dict(Counter(t.get("source") or "llm" for t in turns))}
        rewrites = Counter()
        for t in turns:
            for k, v in (t.get("guard_rewrites") or {}).items():
                rewrites[k] += v
        if rewrites:
            report["turns"]["rewrites"] = dict(rewrites)
    return report


def _print(report: dict) -> None:
    def h(t):
        print(f"\n=== {t} " + "=" * max(0, 60 - len(t)))

    s = report["setup"]
    h("Setup")
    print(f"model {s['model']} via {s['provider']} at {s['url']}  (schema={s['json_schema']}, "
          f"goals={s['goals']}, thinking={s['enable_thinking']}, timeout={s['timeout_s']:.0f}s)")
    sess = report.get("session") or {}
    if sess.get("session_id"):
        print(f"session: {sess.get('session_id')} (ver={sess.get('version')}, seed={sess.get('seed')}, type={sess.get('event_type', 'run')})")
    rm = s.get("router_mode")
    if rm:
        print(f"local router mode: {rm.get('mode')} since {rm.get('since')} ({rm.get('reason', '')})"
              + ("  <- AI is OFF, models won't load" if rm.get("mode") == "off" else ""))
    m = report["model"]
    print("model endpoint: " + ("up" if m.get("reachable") else f"DOWN ({m.get('error')})")
          + (f", {s['model']} {'known' if m.get('known') else 'NOT LISTED'} ({m.get('state')})"
             if m.get("reachable") else ""))

    h("Mod (live)")
    d = report["mod"]
    if not d.get("ok"):
        print(d.get("detail"))
    else:
        c = d.get("character") or {}
        print("character: " + (f"on {c.get('surface')} at {c.get('position')}, health {c.get('health')}, home {c.get('home')}"
                               if c.get("valid") else "not spawned"))
        print(f"autonomy={'on' if d.get('autonomy') else 'PAUSED'}  coop={d.get('coop')}  "
              f"decide every {d.get('tick_interval', 0) / 60:.0f}s  request timeout {d.get('request_timeout_s')}s")
        pend = d.get("pending") or {}
        print("pending requests: " + (", ".join(f"{k} ({v}s)" for k, v in pend.items()) if pend else "none"))
        if d.get("directive"):
            print(f"player order: {d['directive']}")
        if d.get("last_summary"):
            print(f"last summary: {d['last_summary']}")
        for r in d.get("last_results") or []:
            print(f"  {'OK    ' if r.get('ok') else 'FAILED'} {r.get('action')}: {r.get('detail')}")
        print(f"blueprints in mod: {d.get('blueprints')} (measured {d.get('blueprints_measured')})")
        for p in d.get("placed") or []:
            print(f"  placed {p.get('name')} at {p.get('position')} on {p.get('surface')}")
        bs = d.get("bridge_status")
        if bs:
            print(f"panel status: goal {bs.get('goal')} | {bs.get('model')} {bs.get('seconds')}s")

    h(f"Mod events (last {len(report['events'])})")
    for e in report["events"]:
        print(_fmt_event(e))
        if e.get("kind") == "error" and e.get("error"):
            for tb in str(e["error"]).splitlines()[1:8]:
                print("      " + tb)
    if not report["events"]:
        print("(none — debug.jsonl missing; is ai-player-debug-log on and the game running?)")

    h("Errors")
    for l in report["errors_log"]:
        print("mod: " + l)
    for l in report["bridge_warnings"]:
        print("bridge: " + l)
    if not report["errors_log"] and not report["bridge_warnings"]:
        print("(none)")

    h("Last turn")
    x = report["last_exchange"]
    if not x:
        print("(no exchanges in chat.log yet)")
    else:
        print(x.get("header", ""))
        if x.get("goal"):
            print(x["goal"])
        print(x.get("reply_header", ""))
        print((x.get("reply") or "")[:1500])
        print(x.get("parsed", ""))

    t = report.get("turns")
    if t:
        h("Turns")
        print(f"last {t['last_n']}: {t['status']}  avg {t['avg_s']}s, max {t['max_s']}s")
        if t.get("source"):
            print(f"decided by: {t['source']}")
        if t.get("rewrites"):
            print(f"coach rewrites: {t['rewrites']}")


def main() -> None:
    ap = argparse.ArgumentParser(prog="python -m bridge.diag", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--events", type=int, default=25, help="how many mod events to show")
    ap.add_argument("--all", action="store_true", help="show events across all sessions")
    ap.add_argument("--json", action="store_true", help="print everything as JSON")
    args = ap.parse_args()
    report = collect(args.events, all_sessions=args.all)
    if args.json:
        json.dump(report, sys.stdout, indent=1, default=str)
        print()
    else:
        _print(report)


if __name__ == "__main__":
    main()
