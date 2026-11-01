r"""Ultra-Fast Milestone Sprint Runner: Headless 10x-speed sprints with rapid local AI reflection."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests" / "ingame"))

import run_selftest as rs                                    # noqa: E402
from bridge.speedrun import Leaderboard, reflect_sprint       # noqa: E402

PYTHON = str(REPO / ".venv" / "Scripts" / "python.exe")
ROUTER = "http://127.0.0.1:11440/v1"
SEEDS = [424242, 2476103329, 1873625901, 3598211047]

SPRINT_TARGETS = {
    "red": {
        "name": "Red Science Speedrun",
        "check": "local p = game.forces['player'].get_item_production_statistics(game.surfaces[1]); rcon.print(p.get_flow_count{name='automation-science-pack', category='input', precision_index=defines.flow_precision_index.one_minute})",
        "threshold": 5,
        "max_minutes": 3.0
    },
    "green": {
        "name": "Green Science Speedrun",
        "check": "local p = game.forces['player'].get_item_production_statistics(game.surfaces[1]); rcon.print(p.get_flow_count{name='logistic-science-pack', category='input', precision_index=defines.flow_precision_index.one_minute})",
        "threshold": 5,
        "max_minutes": 5.0
    },
    "steel": {
        "name": "Steel Production Speedrun",
        "check": "local p = game.forces['player'].get_item_production_statistics(game.surfaces[1]); rcon.print(p.get_flow_count{name='steel-plate', category='input', precision_index=defines.flow_precision_index.one_minute})",
        "threshold": 2,
        "max_minutes": 4.0
    },
    "oil": {
        "name": "Oil Extraction & Refining Speedrun",
        "check": "local s = game.surfaces[1]; local pj = s.count_entities_filtered{name='pumpjack', force='player'}; local ref = s.count_entities_filtered{name='oil-refinery', force='player'}; rcon.print(string.format('%d,%d', pj, ref))",
        "threshold": 1,
        "max_minutes": 6.0
    }
}


def run_single_sprint(sprint_key: str, seed: int, speed: float = 8.0,
                      use_llm: bool = True, max_real_sec: float = 240.0) -> dict:
    target = SPRINT_TARGETS.get(sprint_key, SPRINT_TARGETS["red"])
    print(f"\n[Sprint] Starting '{target['name']}' (Seed: {seed}, Speed: {speed}x)...", flush=True)

    if rs.factorio_running():
        print("Cannot start sprint: another factorio.exe is running.")
        return {"ok": False, "reason": "factorio_running"}

    tmp = Path(tempfile.mkdtemp(prefix=f"sprint-{sprint_key}-"))
    server = None
    bridge = None
    client = None
    t0 = time.time()
    reached = False
    elapsed = 0.0
    failures = []
    rates = {}

    try:
        save = tmp / "sprint.zip"
        if not rs.create_map(save, seed, enemies=True):
            return {"ok": False, "reason": "create_map_failed"}

        common = rs.common_args(tmp)
        settings = rs.default_server_settings()
        (tmp / "server-settings.json").write_text(json.dumps(settings), encoding="utf-8")

        port, rport = rs.free_port(udp=True), rs.free_port()
        password = secrets.token_hex(8)
        srv_log = open(tmp / "server.log", "w", encoding="utf-8")
        server = subprocess.Popen(
            common + ["--start-server", str(save), "--server-settings", str(tmp / "server-settings.json"),
                      "--bind", "127.0.0.1", "--port", str(port),
                      "--rcon-bind", f"127.0.0.1:{rport}", "--rcon-password", password],
            stdout=srv_log, stderr=subprocess.STDOUT)

        # Wait for RCON
        boot_t0 = time.time()
        while time.time() - boot_t0 < 20:
            if server.poll() is not None:
                return {"ok": False, "reason": "server_exit_early"}
            try:
                client = rs.RCONClient("127.0.0.1", rport, password)
                break
            except Exception:
                time.sleep(1)

        if not client:
            return {"ok": False, "reason": "rcon_timeout"}

        # Write bridge .env
        env_file = tmp / "bridge.env"
        env_content = (
            f"FACTORIO_RCON_HOST=127.0.0.1\nFACTORIO_RCON_PORT={rport}\n"
            f"FACTORIO_RCON_PASSWORD={password}\nFACTORIO_OUTPUT_DIR={tmp}\n"
            f"AI_PROVIDER={'openai' if use_llm else 'stub'}\n"
            f"OPENAI_BASE_URL={ROUTER}\nOPENAI_MODEL=sol-fast\n"
            f"BRIDGE_AUTOPILOT=true\nAI_TIMEOUT=120\n"
        )
        env_file.write_text(env_content, encoding="utf-8")

        bridge_env = {**os.environ, "BRIDGE_ENV_FILE": str(env_file), "PYTHONIOENCODING": "utf-8"}
        bridge_log = open(tmp / "bridge.log", "w", encoding="utf-8")
        bridge = subprocess.Popen([PYTHON, "-m", "bridge.main"], cwd=str(REPO),
                                  env=bridge_env, stdout=bridge_log, stderr=subprocess.STDOUT)

        time.sleep(4)
        client.send_command("/ai-soak-start")
        client.send_command("/spawn-ai-player")
        client.send_command(f"/sc game.speed = {speed}")

        start_time = time.time()
        while time.time() - start_time < max_real_sec:
            if server.poll() is not None or bridge.poll() is not None:
                break

            time.sleep(1.5)
            # Check milestone condition
            try:
                res_str = client.send_command(f"/sc {target['check']}").strip()
                if sprint_key == "oil":
                    parts = [int(p) for p in res_str.split(",") if p.isdigit()]
                    if len(parts) == 2 and parts[0] >= 1 and parts[1] >= 1:
                        reached = True
                        elapsed = time.time() - start_time
                        break
                else:
                    val = float(res_str) if res_str.replace(".", "", 1).isdigit() else 0.0
                    rates[sprint_key] = val
                    if val >= target["threshold"]:
                        reached = True
                        elapsed = time.time() - start_time
                        break
            except Exception:
                pass

        if not reached:
            elapsed = time.time() - start_time

        # Read top failure modes from bridge logs
        try:
            log_text = (tmp / "bridge.log").read_text(encoding="utf-8", errors="ignore")
            for line in log_text.splitlines():
                if "override:" in line or "failed" in line or "error" in line:
                    failures.append(line.strip()[:100])
        except Exception:
            pass

    finally:
        if bridge:
            bridge.terminate()
            try:
                bridge.wait(timeout=2)
            except Exception:
                bridge.kill()
        if server:
            server.terminate()
            try:
                server.wait(timeout=2)
            except Exception:
                server.kill()
        try:
            shutil.rmtree(tmp, ignore_errors=True)
        except Exception:
            pass

    # Record to Leaderboard
    lb = Leaderboard()
    is_pb, prev_pb = lb.record_sprint(sprint_key, seed, elapsed, reached, rates, failures)

    # Trigger rapid reflection if completed or reached cap
    playbook_rules = reflect_sprint(sprint_key, elapsed, is_pb, prev_pb, failures)

    status_str = f"COMPLETED in {elapsed:.1f}s" if reached else f"TIMEOUT ({elapsed:.1f}s)"
    pb_str = "NEW PB! 🏆" if is_pb else f"(PB: {prev_pb}s)" if prev_pb else ""
    print(f"[Sprint Result] {target['name']}: {status_str} {pb_str}")
    if playbook_rules:
        print(f"  Playbook heuristic: {playbook_rules[0]}")

    return {
        "ok": True,
        "sprint": sprint_key,
        "name": target["name"],
        "seed": seed,
        "elapsed": elapsed,
        "reached": reached,
        "is_pb": is_pb,
        "prev_pb": prev_pb,
        "rules": playbook_rules
    }


def main():
    parser = argparse.ArgumentParser(description="Fast Milestone Sprint Runner")
    parser.add_argument("--sprint", choices=["red", "green", "steel", "oil", "all"], default="red")
    parser.add_argument("--speed", type=float, default=8.0)
    parser.add_argument("--seed", type=int, default=424242)
    parser.add_argument("--max-sec", type=float, default=180.0)
    parser.add_argument("--no-llm", action="store_true")
    args = parser.parse_args()

    sprints = ["red", "green", "steel"] if args.sprint == "all" else [args.sprint]
    for s in sprints:
        run_single_sprint(s, args.seed, speed=args.speed, use_llm=not args.no_llm, max_real_sec=args.max_sec)


if __name__ == "__main__":
    main()
