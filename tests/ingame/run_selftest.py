r"""Headless in-game self-tests (mod/scripts/selftest.lua).

    .venv/Scripts/python tests/ingame/run_selftest.py [case[:facing] ...] [--keep]

Creates a fresh map (fixed seed, which arms the mod's /ai-selftest command),
starts a headless server in a throwaway write-data folder with its own config,
runs each case over RCON and prints pass/fail per case. Refuses to start while
any factorio.exe is running. Never touches %APPDATA%\Factorio\saves.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SEED = 424242                     # must match SEED in selftest.lua
FACTORIO_DIR = Path(os.environ.get("FACTORIO_DIR", r"E:\SteamLibrary\steamapps\common\Factorio"))
EXE = FACTORIO_DIR / "bin" / "x64" / "factorio.exe"
REPO = Path(__file__).resolve().parents[2]
REAL_MODS = Path(os.environ["APPDATA"]) / "Factorio" / "mods"     # only mod-list.json is read from here

FACINGS = ["north", "east", "south", "west"]
FACING_CASES = {"miner_furnace", "miner_chest", "miner_belt", "power", "electric_miner", "electric_row", "pump_search",
                "mining_field", "bp_ports", "flow_red_cell", "base_frame"}
ALL_CASES = ["miner_furnace", "miner_chest", "miner_belt", "power", "assembler", "red_cell", "electric_miner", "electric_row", "tend_far", "lab_trigger", "tend_wire", "tend_depleted", "green_cell", "defense", "tend_registry", "shoot_probe", "guard", "protect", "retreat", "hunt", "reflex_tend", "reflex_research", "death_backoff", "hold_cap", "far_player", "connect_pipe", "connect_belt", "pump_search", "astar_cap",
             "field_sizing", "field_depletion", "mining_field", "doctor_output", "doctor_power", "doctor_ingredients", "bp_ports",
             "flow_reversed_inserter", "flow_dead_end", "flow_red_cell", "prod_red_cell", "prod_mining_field", "base_frame"]
CASE_TIMEOUT = 240
BOOT_TIMEOUT = 240


def factorio_running() -> bool:
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq factorio.exe", "/NH"],
                         capture_output=True, text=True).stdout
    return "factorio.exe" in out.lower()


def prepare_mods(tmp: Path) -> Path:
    """A throwaway mods folder: a copy of the repo's mod/ plus a minimal mod-list.json
    (the official mods the real list enables, and this one). The real mods folder
    stays untouched, and mod-settings.dat (which can hold API keys) is never copied."""
    mods = tmp / "mods"
    info = json.loads((REPO / "mod" / "info.json").read_text(encoding="utf8"))
    shutil.copytree(REPO / "mod", mods / f"{info['name']}_{info['version']}",
                    ignore=shutil.ignore_patterns("__pycache__", "config.json"))
    official = {p.name for p in (FACTORIO_DIR / "data").iterdir() if p.is_dir()}
    names = ["base"]
    try:
        real = json.loads((REAL_MODS / "mod-list.json").read_text(encoding="utf8"))
        names += [m["name"] for m in real.get("mods", [])
                  if m.get("enabled") and m["name"] in official and m["name"] != "base"]
    except (OSError, ValueError, KeyError):
        pass
    names.append(info["name"])
    (mods / "mod-list.json").write_text(json.dumps({"mods": [{"name": n, "enabled": True} for n in names]}))
    return mods


def free_port(udp: bool = False) -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def expand(names: list[str]) -> list[str]:
    out = []
    for n in names or ALL_CASES:
        if ":" not in n and n in FACING_CASES:
            out += [f"{n}:{f}" for f in FACINGS]
        else:
            out.append(n)
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    keep = "--keep" in sys.argv
    if "--all" in sys.argv:
        args = list(ALL_CASES)
    if not EXE.exists():
        print(f"factorio.exe not found at {EXE}")
        return 2
    if factorio_running():
        print("factorio.exe is already running (game or server) - close it first. Not starting.")
        return 2
    from factorio_rcon import RCONClient

    tmp = Path(tempfile.mkdtemp(prefix="ai-selftest-"))
    write_data = tmp / "data"
    write_data.mkdir()
    cfg = tmp / "config.ini"
    cfg.write_text(f"[path]\nread-data={FACTORIO_DIR / 'data'}\nwrite-data={write_data}\n")
    save = tmp / "selftest.zip"
    common = [str(EXE), "-c", str(cfg), "--mod-directory", str(prepare_mods(tmp))]

    print("creating map ...")
    r = subprocess.run(common + ["--create", str(save), "--map-gen-seed", str(SEED)],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0 or not save.exists():
        print("map creation failed:\n" + (r.stdout + r.stderr)[-1500:])
        return 2

    settings = json.loads((FACTORIO_DIR / "data" / "server-settings.example.json").read_text(encoding="utf8"))
    settings.update(auto_pause=False, require_user_verification=False, autosave_interval=0,
                    max_players=0, autosave_only_on_server=True)
    settings["visibility"] = {"public": False, "lan": False}
    (tmp / "server-settings.json").write_text(json.dumps(settings))

    port, rport = free_port(udp=True), free_port()
    password = secrets.token_hex(8)
    log = open(tmp / "server.log", "w")
    proc = subprocess.Popen(
        common + ["--start-server", str(save), "--server-settings", str(tmp / "server-settings.json"),
                  "--bind", "127.0.0.1", "--port", str(port),
                  "--rcon-bind", f"127.0.0.1:{rport}", "--rcon-password", password],
        stdout=log, stderr=subprocess.STDOUT)

    results: dict[str, dict] = {}
    code = 1
    try:
        client = None
        t0 = time.time()
        while time.time() - t0 < BOOT_TIMEOUT:
            if proc.poll() is not None:
                print("server exited early:\n" + (tmp / "server.log").read_text(errors="replace")[-1500:])
                return 2
            try:
                client = RCONClient("127.0.0.1", rport, password)
                break
            except Exception:
                time.sleep(2)
        if client is None:
            print("RCON never came up")
            return 2
        out_file = write_data / "script-output" / "ai-player" / "selftest.json"
        for case in expand(args):
            out_file.unlink(missing_ok=True)
            run_id = secrets.token_hex(3)
            client.send_command(f"/ai-selftest {case} {run_id}")
            t1, res = time.time(), None
            while time.time() - t1 < CASE_TIMEOUT:
                if out_file.exists():
                    try:
                        data = json.loads(out_file.read_text(encoding="utf8"))
                        if data.get("run_id") == run_id:
                            res = data
                            break
                    except ValueError:
                        pass
                time.sleep(1)
            results[case] = res or {"ok": False, "detail": f"no result within {CASE_TIMEOUT}s"}
            r = results[case]
            print(f"{'PASS' if r.get('ok') else 'FAIL'} {case}")
            if "--verbose" in sys.argv:
                for ch in r.get("checks") or []:
                    print(f"   {'ok' if ch.get('ok') else 'x '} {ch.get('name')}: {ch.get('info')}")
            if not r.get("ok"):
                print("   " + str(r.get("detail"))[:900])
                for ch in r.get("checks") or []:
                    if not ch.get("ok"):
                        print(f"   x {ch.get('name')}: {ch.get('info')}")
        code = 0 if all(r.get("ok") for r in results.values()) else 1
        print(f"{sum(1 for r in results.values() if r.get('ok'))}/{len(results)} passed")
        try:
            client.send_command("/quit")
        except Exception:
            pass
    finally:
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            print("server did not exit - killed")
        log.close()
        if proc.poll() is None:
            proc.kill()
        if keep:
            print(f"kept {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
