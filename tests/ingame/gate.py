r"""Automated regression gate for Round 20 (docs/ROUND20_PLAN.md).

Usage:
    uv run python tests/ingame/gate.py --mode quick [--cases power ...]
    uv run python tests/ingame/gate.py --mode full
    uv run python tests/ingame/gate.py --baseline-only
    uv run python tests/ingame/gate.py --accept
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MOD_DIR = REPO / "mod"
SCORES_DIR = REPO / "docs" / "scores"
BASELINE_FILE = SCORES_DIR / "baseline.json"
SCORES_LOG = REPO / "docs" / "SCORES.md"
SEEDS = [424242, 2476103329]


def run_cmd(cmd: list[str], desc: str, timeout: int = 1800) -> tuple[int, str]:
    print(f"\n=== [GATE] {desc} ===")
    print(f"Command: {' '.join(cmd)}")
    p = subprocess.run(cmd, cwd=str(REPO), capture_output=True, text=True, timeout=timeout)
    out = (p.stdout or "") + ("\n" + p.stderr if p.stderr else "")
    print(out[-1500:] if len(out) > 1500 else out)
    return p.returncode, out


def check_lua_syntax() -> list[str]:
    print("\n=== [GATE] Lua Syntax Check (luaparser) ===")
    from luaparser import ast

    errors = []
    lua_files = sorted(MOD_DIR.rglob("*.lua"))
    for f in lua_files:
        try:
            content = f.read_text(encoding="utf-8")
            ast.parse(content)
        except Exception as e:
            err = f"{f.relative_to(REPO)}: {e}"
            print(f"  FAIL: {err}")
            errors.append(err)
    if not errors:
        print(f"  PASS: {len(lua_files)} Lua files parsed cleanly with no syntax errors.")
    return errors


def get_git_commit() -> str:
    try:
        r = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=str(REPO),
                           capture_output=True, text=True)
        return r.stdout.strip()
    except Exception:
        return "unknown"


def parse_latest_report(label_prefix: str) -> dict | None:
    soak_out = REPO / "tests" / "ingame" / "soak-out"
    if not soak_out.exists():
        return None
    matching = sorted(soak_out.glob(f"soak-report-{label_prefix}*.json"),
                      key=lambda p: p.stat().st_mtime, reverse=True)
    if not matching:
        return None
    try:
        return json.loads(matching[0].read_text(encoding="utf-8"))
    except Exception:
        return None


def run_soak(seed: int, minutes: int, speed: int, label: str) -> dict | None:
    cmd = [
        sys.executable, "tests/ingame/run_soak.py",
        "--no-llm",
        "--seed", str(seed),
        "--minutes", str(minutes),
        "--speed", str(speed),
        "--label", label,
    ]
    code, _ = run_cmd(cmd, f"Soak {label} (seed {seed}, {minutes}m game time, {speed}x)")
    rep = parse_latest_report(label)
    if not rep:
        return None
    return rep


def append_score_log(report: dict, commit: str, flag: bool = False):
    SCORES_LOG.parent.mkdir(parents=True, exist_ok=True)
    header = ("| Date | Commit | Seed | Buildbook | Min | Iron/m | Cu/m | Red/m | "
              "FlowFaults | ModErrors | Autopilot% |\n"
              "|---|---|---|---|---|---|---|---|---|---|---|\n")
    if not SCORES_LOG.exists() or SCORES_LOG.stat().st_size == 0:
        SCORES_LOG.write_text(header, encoding="utf-8")

    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    ev = report.get("evaluation") or {}
    sc = ev.get("score") or {}
    rates = sc.get("rates_last_10m") or {}
    fin = ev.get("final") or {}

    line = (f"| {now} | `{commit}` | {report.get('seed')} | {'ON' if flag else 'OFF'} | "
            f"{fin.get('minute')} | {rates.get('iron_per_min', 0)} | {rates.get('copper_per_min', 0)} | "
            f"{rates.get('red_per_min', 0)} | {sc.get('flow_faults_last_30m', 0)} | "
            f"{sc.get('mod_errors', 0)} | {sc.get('autopilot_share', 0):.1%} |\n")

    with open(SCORES_LOG, "a", encoding="utf-8") as f:
        f.write(line)


def compare_against_baseline(score: dict, seed_str: str, baseline_data: dict) -> list[str]:
    regressions = []
    base_seed = baseline_data.get(seed_str)
    if not base_seed:
        return regressions

    base_score = base_seed.get("mean_score", base_seed)
    spread = base_seed.get("spread", {})

    # 1. Mod errors must be 0
    if score.get("mod_errors", 0) > 0:
        regressions.append(f"Hard fail: mod_errors = {score.get('mod_errors')} (must be 0)")

    # 2. Flow faults: fail only if they rise by more than 2
    base_ff = base_score.get("flow_faults_last_30m", 0)
    curr_ff = score.get("flow_faults_last_30m", 0)
    if curr_ff > base_ff + 2:
        regressions.append(f"Regression: flow faults ({curr_ff}) rose by >2 over baseline ({base_ff})")

    # 3. Milestones
    base_ms = base_score.get("milestones") or {}
    curr_ms = score.get("milestones") or {}
    for m, base_val in base_ms.items():
        if base_val is None:
            continue
        curr_val = curr_ms.get(m)
        if curr_val is None:
            regressions.append(f"Regression: milestone '{m}' achieved in baseline at min {base_val} but missing now")
        else:
            sp = spread.get("milestones", {}).get(m, 0)
            threshold = max(5.0, 0.10 * base_val, 2.0 * sp)
            if curr_val > base_val + threshold:
                regressions.append(
                    f"Regression: milestone '{m}' at min {curr_val} exceeded baseline {base_val} + threshold {threshold:.1f}")

    # 4. Production Rates (higher is better)
    base_rates = base_score.get("rates_last_10m") or {}
    curr_rates = score.get("rates_last_10m") or {}
    for r, base_val in base_rates.items():
        if base_val <= 0:
            continue
        curr_val = curr_rates.get(r, 0)
        sp = spread.get("rates_last_10m", {}).get(r, 0)
        threshold = max(5.0, 0.10 * base_val, 2.0 * sp)
        if curr_val < base_val - threshold:
            regressions.append(
                f"Regression: rate '{r}' ({curr_val}/m) dropped below baseline {base_val} - threshold {threshold:.1f}")

    return regressions


def run_baseline_collection(speed: int = 4, runs_per_seed: int = 2, seeds: list[int] | None = None):
    seeds = seeds or SEEDS
    print("\n=======================================================")
    print(f"Collecting Round 20 Baseline: {runs_per_seed} run(s) per seed on HEAD (seeds: {seeds})")
    print("=======================================================")
    SCORES_DIR.mkdir(parents=True, exist_ok=True)
    results = {}
    if BASELINE_FILE.exists():
        try:
            results = json.loads(BASELINE_FILE.read_text(encoding="utf-8"))
        except Exception:
            results = {}

    for seed in seeds:
        seed_key = str(seed)
        runs = []
        for run_idx in range(1, runs_per_seed + 1):
            label = f"baseline-s{seed}-r{run_idx}"
            rep = run_soak(seed, minutes=90, speed=speed, label=label)
            if not rep:
                print(f"FATAL: Baseline run {label} failed to complete!")
                sys.exit(1)
            runs.append(rep["evaluation"]["score"])
            append_score_log(rep, get_git_commit(), flag=False)

        if len(runs) >= 2:
            r1, r2 = runs[0], runs[1]
            mean_score = {}
            spread = {}

            # Milestones
            mean_ms = {}
            spread_ms = {}
            all_ms_keys = set(r1["milestones"].keys()) | set(r2["milestones"].keys())
            for k in all_ms_keys:
                v1, v2 = r1["milestones"].get(k), r2["milestones"].get(k)
                if v1 is not None and v2 is not None:
                    mean_ms[k] = round((v1 + v2) / 2.0, 1)
                    spread_ms[k] = round(abs(v1 - v2), 1)
                elif v1 is not None:
                    mean_ms[k] = v1
                    spread_ms[k] = 0.0
                elif v2 is not None:
                    mean_ms[k] = v2
                    spread_ms[k] = 0.0
                else:
                    mean_ms[k] = None
                    spread_ms[k] = 0.0
            mean_score["milestones"] = mean_ms
            spread["milestones"] = spread_ms

            # Rates
            mean_rates = {}
            spread_rates = {}
            for k in r1["rates_last_10m"].keys():
                v1, v2 = r1["rates_last_10m"].get(k, 0), r2["rates_last_10m"].get(k, 0)
                mean_rates[k] = round((v1 + v2) / 2.0, 2)
                spread_rates[k] = round(abs(v1 - v2), 2)
            mean_score["rates_last_10m"] = mean_rates
            spread["rates_last_10m"] = spread_rates

            # Other fields
            for field in ("techs_researched", "flow_faults_last_30m", "attention_share",
                          "hand_hauled_last_30m", "mod_errors", "autopilot_share"):
                v1, v2 = r1.get(field, 0), r2.get(field, 0)
                mean_score[field] = round((v1 + v2) / 2.0, 3)
                spread[field] = round(abs(v1 - v2), 3)

            results[seed_key] = {
                "mean_score": mean_score,
                "spread": spread,
                "runs": runs,
            }
        else:
            r1 = runs[0]
            results[seed_key] = {
                "mean_score": r1,
                "spread": {
                    "milestones": {k: 0.0 for k in r1.get("milestones", {})},
                    "rates_last_10m": {k: 0.0 for k in r1.get("rates_last_10m", {})},
                    "techs_researched": 0.0, "flow_faults_last_30m": 0.0,
                    "attention_share": 0.0, "hand_hauled_last_30m": 0.0,
                    "mod_errors": 0.0, "autopilot_share": 0.0
                },
                "runs": runs,
            }

    BASELINE_FILE.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"\n[BASELINE SAVED] Saved baseline to {BASELINE_FILE}")


def main():
    parser = argparse.ArgumentParser(description="Round 20 Gate Runner")
    parser.add_argument("--mode", choices=["quick", "full"], default="quick",
                        help="Quick gate (per commit) or Full gate (per part)")
    parser.add_argument("--cases", nargs="*", default=[],
                        help="Specific self-test cases touched (quick mode)")
    parser.add_argument("--speed", type=int, default=4, help="Soak speed factor (default 4)")
    parser.add_argument("--baseline-only", action="store_true",
                        help="Run baseline seeds and save docs/scores/baseline.json")
    parser.add_argument("--runs-per-seed", type=int, default=2,
                        help="Number of runs per seed for baseline collection (default 2)")
    parser.add_argument("--seeds", type=int, nargs="*", default=None,
                        help="Specific seeds to run for baseline (default [424242, 2476103329])")
    parser.add_argument("--accept", action="store_true",
                        help="Accept latest soak results as baseline")
    args = parser.parse_args()

    commit = get_git_commit()

    if args.baseline_only:
        run_baseline_collection(speed=args.speed, runs_per_seed=args.runs_per_seed, seeds=args.seeds)
        return

    # 1. Pytest
    pt_cmd = [sys.executable, "-m", "pytest", "-q", "tests/"]
    c, out = run_cmd(pt_cmd, "Pytest Unit Tests")
    if c != 0:
        print("\nGATE HARD FAIL: pytest failed!")
        sys.exit(1)

    # 2. Lua syntax check
    lua_errs = check_lua_syntax()
    if lua_errs:
        print("\nGATE HARD FAIL: Lua syntax errors detected!")
        sys.exit(1)

    # 3. Selftest
    if args.mode == "full":
        st_cmd = [sys.executable, "tests/ingame/run_selftest.py", "--all"]
    else:
        st_cases = args.cases if args.cases else ["power"]
        st_cmd = [sys.executable, "tests/ingame/run_selftest.py"] + st_cases

    c, out = run_cmd(st_cmd, f"Selftest ({'--all' if args.mode == 'full' else ' '.join(args.cases)})")
    if c != 0:
        print("\nGATE HARD FAIL: In-game selftest failed!")
        sys.exit(1)

    # 4. Soak Runs
    baseline_data = {}
    if BASELINE_FILE.exists():
        try:
            baseline_data = json.loads(BASELINE_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass

    if args.mode == "quick":
        # One soak: 45m on Seed A (424242)
        label = f"gate-quick-{commit}"
        rep = run_soak(SEEDS[0], minutes=45, speed=args.speed, label=label)
        if not rep:
            print("\nGATE HARD FAIL: Quick soak failed!")
            sys.exit(1)
        append_score_log(rep, commit, flag=False)

        # Regressions check if baseline available
        score = rep.get("evaluation", {}).get("score", {})
        if baseline_data:
            regs = compare_against_baseline(score, str(SEEDS[0]), baseline_data)
            if regs:
                print("\nGATE REGRESSION DETECTED:")
                for r in regs:
                    print(f"  * {r}")
                sys.exit(1)

    elif args.mode == "full":
        # Two soaks: 90m on Seed A (424242) and Seed B (2476103329), 1 retry if fail
        for seed in SEEDS:
            label = f"gate-full-s{seed}-{commit}"
            rep = run_soak(seed, minutes=90, speed=args.speed, label=label)
            if not rep:
                print(f"Seed {seed} failed on first attempt — retrying once per plan rules...")
                rep = run_soak(seed, minutes=90, speed=args.speed, label=f"{label}-retry")
                if not rep:
                    print(f"\nGATE HARD FAIL: Seed {seed} failed twice!")
                    sys.exit(1)

            append_score_log(rep, commit, flag=False)
            score = rep.get("evaluation", {}).get("score", {})
            if baseline_data:
                regs = compare_against_baseline(score, str(seed), baseline_data)
                if regs:
                    print(f"\nGATE REGRESSION DETECTED on seed {seed}:")
                    for r in regs:
                        print(f"  * {r}")
                    sys.exit(1)

    print("\n=======================================================")
    print(f"GATE PASSED: {args.mode.upper()} GATE MET ALL CRITERIA")
    print("=======================================================")


if __name__ == "__main__":
    main()
