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
from factorio_rcon import RCONClient                          # noqa: E402
from bridge.speedrun import (Leaderboard, copy_debug_sprint, parse_tick,  # noqa: E402
                             reflect_sprint, ticks_to_seconds)

PYTHON = str(REPO / ".venv" / "Scripts" / "python.exe")
ROUTER = "http://127.0.0.1:11440/v1"
SEEDS = [424242, 2476103329, 1873625901, 3598211047]

SPRINT_TARGETS = {
    "red": {
        "name": "Red Science Speedrun",
        "check": "/ai-sprint-check automation-science-pack",
        "threshold": 5,
        "max_minutes": 3.0
    },
    "green": {
        "name": "Green Science Speedrun",
        "check": "/ai-sprint-check logistic-science-pack",
        "threshold": 5,
        "max_minutes": 5.0
    },
    "steel": {
        "name": "Steel Production Speedrun",
        "check": "/ai-sprint-check steel-plate",
        "threshold": 2,
        "max_minutes": 4.0
    },
    "oil": {
        "name": "Oil Extraction & Refining Speedrun",
        "check": "/ai-sprint-oil",
        "threshold": 1,
        "max_minutes": 6.0
    }
}


# Sprints whose item is made by assemblers (the check counts assembler output only).
ASSEMBLER_SPRINTS = {"red", "green"}


def make_map_settings(seed: int, enemies: bool = True) -> dict:
    s = json.loads((rs.FACTORIO_DIR / "data" / "map-gen-settings.example.json").read_text(encoding="utf-8"))
    s["seed"] = seed
    ctl = s.setdefault("autoplace_controls", {})
    ctl["enemy-base"] = {"frequency": 1, "size": 1 if enemies else 0, "richness": 1}
    return s


def make_server_settings() -> dict:
    settings = json.loads((rs.FACTORIO_DIR / "data" / "server-settings.example.json").read_text(encoding="utf-8"))
    settings.update(auto_pause=False, require_user_verification=False, autosave_interval=0,
                    max_players=0, autosave_only_on_server=True)
    settings["visibility"] = {"public": False, "lan": False}
    return settings


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
        write_data = tmp / "data"
        write_data.mkdir(parents=True, exist_ok=True)
        out_dir = write_data / "script-output" / "ai-player"
        cfg = tmp / "config.ini"
        cfg.write_text(f"[path]\nread-data={rs.FACTORIO_DIR / 'data'}\nwrite-data={write_data}\n", encoding="utf-8")
        common = [str(rs.EXE), "-c", str(cfg), "--mod-directory", str(rs.prepare_mods(tmp))]

        save = tmp / "sprint.zip"
        (tmp / "map-gen-settings.json").write_text(json.dumps(make_map_settings(seed, enemies=True)), encoding="utf-8")
        r = subprocess.run(common + ["--create", str(save), "--map-gen-settings", str(tmp / "map-gen-settings.json")],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0 or not save.exists():
            print("Map creation failed:\n" + (r.stdout + r.stderr)[-1000:], flush=True)
            return {"ok": False, "reason": "create_map_failed"}

        settings = make_server_settings()
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
        while time.time() - boot_t0 < 25:
            if server.poll() is not None:
                return {"ok": False, "reason": "server_exit_early"}
            try:
                client = RCONClient("127.0.0.1", rport, password)
                break
            except Exception:
                time.sleep(1)

        if not client:
            return {"ok": False, "reason": "rcon_timeout"}

        # Write bridge .env
        env_file = tmp / "bridge.env"
        lines = [
            f"FACTORIO_OUTPUT_DIR={out_dir}",
            f"FACTORIO_RCON_HOST=127.0.0.1",
            f"FACTORIO_RCON_PORT={rport}",
            f"FACTORIO_RCON_PASSWORD={password}",
            f"AI_PROVIDER={'lmstudio' if use_llm else 'stub'}",
            f"AI_MODEL=sol-fast",
            f"LM_STUDIO_URL={ROUTER}",
            f"AI_ENABLE_THINKING=false",
            f"BRIDGE_AUTOPILOT=true",
            f"AI_TIMEOUT={int(120 * max(speed, 1.0))}",
            f"BRIDGE_VERBOSE=0"
        ]
        env_file.write_text("\n".join(lines) + "\n", encoding="utf-8")

        bridge_env = {**os.environ, "BRIDGE_ENV_FILE": str(env_file), "PYTHONIOENCODING": "utf-8"}
        bridge_log = open(tmp / "bridge.log", "w", encoding="utf-8")
        bridge = subprocess.Popen([PYTHON, "-m", "bridge.main"], cwd=str(REPO),
                                  env=bridge_env, stdout=bridge_log, stderr=subprocess.STDOUT)

        time.sleep(4)
        client.send_command("/ai-soak-start")
        client.send_command("/spawn-ai-player")
        client.send_command(f"/ai-soak-speed {speed}")

        start_time = time.time()
        # Sprint times are game ticks (read over RCON), not wall clock.
        def game_tick():
            return parse_tick(client.send_command("/sc rcon.print(game.tick)"))

        def game_elapsed():
            end = game_tick()
            if start_tick is None or end is None:        # tick unreadable: wall-clock fallback
                return time.time() - start_time
            return ticks_to_seconds(start_tick, end)

        start_tick = game_tick()
        while time.time() - start_time < max_real_sec:
            if server.poll() is not None or bridge.poll() is not None:
                break

            time.sleep(1.5)
            # Check milestone condition
            try:
                res_str = client.send_command(target["check"]).strip()
                if int(time.time() - start_time) % 10 == 0:
                    print(f"[{time.time() - start_time:.1f}s] check '{target['check']}' -> '{res_str}'", flush=True)
                if sprint_key == "oil":
                    parts = [int(p) for p in res_str.split(",") if p.isdigit()]
                    if len(parts) == 2 and parts[0] >= 1 and parts[1] >= 1:
                        reached = True
                        elapsed = game_elapsed()
                        break
                else:
                    parts = [int(p) for p in res_str.split(",") if p.isdigit()]
                    if len(parts) >= 3 and sprint_key in ASSEMBLER_SPRINTS:
                        # Third field = items finished by assemblers; hand-crafted packs
                        # (they also show in production stats / the inventory) don't count.
                        rates[sprint_key] = parts[2]
                        if parts[2] >= target["threshold"]:
                            reached = True
                            elapsed = game_elapsed()
                            break
                    elif len(parts) >= 2:
                        rate_val, total_val = parts[0], parts[1]
                        rates[sprint_key] = max(rate_val, total_val)
                        if rate_val >= target["threshold"] or total_val >= target["threshold"]:
                            reached = True
                            elapsed = game_elapsed()
                            break
                    elif res_str.replace(".", "", 1).isdigit():
                        val = float(res_str)
                        rates[sprint_key] = val
                        if val >= target["threshold"]:
                            reached = True
                            elapsed = game_elapsed()
                            break
            except Exception:
                pass

        if not reached:
            try:
                elapsed = game_elapsed()
            except Exception:
                elapsed = time.time() - start_time

        # Read top failure modes from bridge logs
        try:
            log_text = (tmp / "bridge.log").read_text(encoding="utf-8", errors="ignore")
            for line in log_text.splitlines():
                if "override:" in line or "failed" in line or "error" in line:
                    failures.append(line.strip()[:100])
            if not reached:
                print("Bridge log tail:\n" + "\n".join(log_text.splitlines()[-20:]), flush=True)
                print("Bridge failure lines:\n" + "\n".join(failures[:15]), flush=True)
                copy_debug_sprint(tmp, REPO / "debug_sprint", password)
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
    pb_str = "NEW PB!" if is_pb else f"(PB: {prev_pb}s)" if prev_pb else ""
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
