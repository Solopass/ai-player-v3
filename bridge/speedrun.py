"""Personal Best (PB) Leaderboard and Rapid LLM Reflection Engine for ultra-fast milestone sprints."""

from __future__ import annotations

import json
import logging
import time
import urllib.request
from pathlib import Path

log = logging.getLogger("speedrun")

REPO_ROOT = Path(__file__).resolve().parent.parent
MEMORY_DIR = REPO_ROOT / "memory"
LEADERBOARD_FILE = MEMORY_DIR / "leaderboard.json"
PLAYBOOK_FILE = MEMORY_DIR / "speedrun_playbook.json"
ROUTER_URL = "http://127.0.0.1:11440/v1"
DEFAULT_MODEL = "sol-fast"


def _ensure_dir():
    MEMORY_DIR.mkdir(parents=True, exist_ok=True)


class Leaderboard:
    """Tracks fastest completion times (Personal Bests) across seeds and milestones."""

    def __init__(self, path: Path = LEADERBOARD_FILE):
        self.path = path
        self.data: dict[str, dict] = self._load()

    def _load(self) -> dict[str, dict]:
        if self.path.exists():
            try:
                return json.loads(self.path.read_text(encoding="utf-8"))
            except Exception as e:
                log.warning("Failed to load leaderboard from %s: %s", self.path, e)
        return {}

    def save(self) -> None:
        _ensure_dir()
        self.path.write_text(json.dumps(self.data, indent=2) + "\n", encoding="utf-8")

    def get_pb(self, sprint_name: str) -> float | None:
        entry = self.data.get(sprint_name)
        return entry.get("best_time") if entry else None

    def record_sprint(self, sprint_name: str, seed: int, elapsed_seconds: float,
                      reached: bool, rates: dict | None = None,
                      failures: list[str] | None = None) -> tuple[bool, float | None]:
        """Record sprint result. Returns (is_new_pb, previous_best)."""
        entry = self.data.setdefault(sprint_name, {
            "best_time": None,
            "best_seed": None,
            "runs_total": 0,
            "runs_completed": 0,
            "history": []
        })
        entry["runs_total"] += 1
        prev_best = entry["best_time"]
        is_new_pb = False

        if reached:
            entry["runs_completed"] += 1
            if prev_best is None or elapsed_seconds < prev_best:
                is_new_pb = True
                entry["best_time"] = round(elapsed_seconds, 1)
                entry["best_seed"] = seed

        record = {
            "timestamp": time.time(),
            "seed": seed,
            "time": round(elapsed_seconds, 1),
            "reached": reached,
            "rates": rates or {},
            "failures_count": len(failures or [])
        }
        entry["history"].append(record)
        if len(entry["history"]) > 50:
            entry["history"] = entry["history"][-50:]

        self.save()
        return is_new_pb, prev_best


def load_playbook(path: Path = PLAYBOOK_FILE) -> list[str]:
    """Returns the list of active speedrun heuristics."""
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return data.get("rules", [])
        except Exception:
            pass
    return []


def save_playbook(rules: list[str], path: Path = PLAYBOOK_FILE) -> None:
    _ensure_dir()
    path.write_text(json.dumps({"rules": rules, "updated_at": time.time()}, indent=2) + "\n",
                    encoding="utf-8")


def reflect_sprint(sprint_name: str, elapsed_seconds: float, is_pb: bool,
                   pb: float | None, failures: list[str],
                   model: str = DEFAULT_MODEL) -> list[str]:
    """Query the local AI router to reflect on the sprint and extract 1-2 tactical heuristics."""
    existing_rules = load_playbook()
    top_fails = failures[:5] if failures else ["none"]
    prompt = (
        f"You are the strategic speedrun coach for an autonomous Factorio AI player.\n"
        f"Sprint: '{sprint_name}'. Result: {round(elapsed_seconds, 1)}s. "
        f"{'NEW PERSONAL BEST!' if is_pb else f'PB is {pb}s'}.\n"
        f"Top action failures:\n" + "\n".join(f"- {f}" for f in top_fails) + "\n\n"
        f"In 1 or 2 concise bullet points (under 20 words each), give the #1 tactical adjustment "
        f"the AI must make in the next sprint to reduce wasted time or avoid failures. "
        f"Start each line with '- '."
    )

    new_rule = None
    try:
        req = urllib.request.Request(
            f"{ROUTER_URL}/chat/completions",
            data=json.dumps({
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 120,
                "temperature": 0.3
            }).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            res = json.loads(r.read().decode("utf-8"))
            content = res["choices"][0]["message"]["content"]
            lines = [line.strip().lstrip("-* ").strip() for line in content.splitlines() if line.strip().startswith(("-", "*", "1", "2"))]
            if lines:
                new_rule = lines[0]
    except Exception as e:
        log.warning("Local AI reflection query failed: %s; using deterministic fallback", e)

    if not new_rule:
        if "belt" in str(top_fails).lower():
            new_rule = f"Clear path obstacles before routing {sprint_name} belt lines."
        elif "craft_for" in str(top_fails).lower():
            new_rule = f"Pre-smelt iron plates before batch-crafting {sprint_name} assemblers."
        else:
            new_rule = f"Keep boiler fueled to ensure 100% electric uptime during {sprint_name}."

    if new_rule and new_rule not in existing_rules:
        existing_rules.insert(0, new_rule)
        save_playbook(existing_rules[:12])

    return existing_rules
