"""
Setup diagnostics for the bridge on this machine.

Checks, in order:
  1. Parser — fenced / prose / <think>-wrapped replies still parse into actions.
  2. Output dir — FACTORIO_OUTPUT_DIR exists (created if missing).
  3. LLM — one real turn through the configured provider; reports latency and
     whether the reply parsed. For a full latency measurement use
     `python -m bridge.benchmark --runs 3`.
  4. RCON — connects to Factorio and runs a trivial command.

Run from the repo root:  .venv\\Scripts\\python test_bridge_setup.py
Exit code 0 only if every check passed.
"""

import logging
import sys
import time

from bridge.config import ConfigLoader
from bridge.factorio.api import parse_response
from bridge.factorio.rcon import RCONGateway
from bridge.prompt import build_messages
from bridge.providers import get_provider

logging.basicConfig(level=logging.WARNING, format="  %(levelname)s %(name)s: %(message)s")

_PARSER_CASES = {
    "plain array":   '[{"skill":"build_ghosts"}]',
    "json fence":    '```json\n[{"skill":"build_ghosts"}]\n```',
    "prose prefix":  'Here are my actions: [{"skill":"build_ghosts"}]',
    "think tags":    '<think>plan...</think>[{"skill":"build_ghosts"}]',
    "single object": '{"skill":"build_ghosts"}',
}

_SAMPLE_PAYLOAD = {
    "perception": {
        "character": {"position": {"x": 0, "y": 0}, "health": 250, "health_pct": 100},
        "game_phase": 0,
        "inventory": [{"name": "iron-plate", "count": 20}, {"name": "coal", "count": 50}],
        "craftable": ["iron-gear-wheel", "stone-furnace"],
        "nearby_resources": [
            {"name": "iron-ore", "patch_count": 30, "total_amount": 4000,
             "nearest": {"x": 6, "y": -3}, "nearest_distance": 6},
        ],
    },
    "memory": {},
}


def check_parser() -> bool:
    bad = [name for name, text in _PARSER_CASES.items() if not parse_response(text)]
    if bad:
        print(f"[FAIL] parser: could not parse {', '.join(bad)}")
        return False
    print(f"[ OK ] parser: {len(_PARSER_CASES)} wrapped-reply cases parse")
    return True


def check_output_dir(cfg) -> bool:
    d = cfg.output_dir
    existed = d.exists()
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        print(f"[FAIL] output dir: cannot create {d}: {e}")
        return False
    print(f"[ OK ] output dir: {d} ({'exists' if existed else 'created'})")
    return True


def check_llm(cfg) -> bool:
    pcfg = cfg.to_provider_config()
    print(f"       llm: provider={pcfg.provider} model={pcfg.model} url={pcfg.url} "
          f"reasoning={pcfg.reasoning_effort or 'default'} timeout={pcfg.timeout:.0f}s")
    complete = get_provider(pcfg)
    t0 = time.monotonic()
    content = complete(build_messages(_SAMPLE_PAYLOAD, cfg.system_prefix), pcfg)
    dt = time.monotonic() - t0
    if content is None:
        print(f"[FAIL] llm: no reply after {dt:.1f}s (server down, model not loaded, or timeout)")
        return False
    actions = parse_response(content)
    if not actions:
        print(f"[FAIL] llm: replied in {dt:.1f}s but nothing parsed. Raw: {content[:300]!r}")
        return False
    fenced = "```" in content
    print(f"[ OK ] llm: {len(actions)} action(s) in {dt:.1f}s"
          f"{' (reply had a markdown fence; parser stripped it)' if fenced else ''}")
    print(f"       first action: {actions[0]}")
    return True


def check_rcon(cfg) -> bool:
    r = cfg.rcon
    gw = RCONGateway(r.host, r.port, r.password)
    if not gw.connect():
        print(f"[FAIL] rcon: cannot connect to {r.host}:{r.port} — is Factorio hosting a game "
              "with --rcon-port/--rcon-password?")
        return False
    reply = gw.query_lua("rcon.print(game.tick)")
    gw.disconnect()
    print(f"[ OK ] rcon: {r.host}:{r.port} connected, game.tick = {reply}")
    return True


def main() -> int:
    cfg = ConfigLoader().get()
    print("factorio-ai-bridge setup check")
    print("=" * 64)
    results = {
        "parser": check_parser(),
        "output_dir": check_output_dir(cfg),
        "llm": check_llm(cfg),
        "rcon": check_rcon(cfg),
    }
    print("-" * 64)
    failed = [k for k, ok in results.items() if not ok]
    print("All checks passed." if not failed else f"Failed: {', '.join(failed)}")
    if results["llm"]:
        print("\nStart the bridge with:  .venv\\Scripts\\python -m bridge.main")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
