"""
Turn memory and loop breaker.

The mod reports only the previous turn's results, so on its own the model
can't tell it has sent the same failing move ten times. The coach lives in the
bridge process and remembers:

- failures per move (planner.entry_key), counted once per reported batch
  (memory.last_results_req_id, so a stale batch isn't counted twice);
- what was sent each turn, to catch the same moves repeated with no progress;
- how long the game state has gone without changing.

A move that failed twice, or was sent three turns running, is BLOCKED: the
prompt says so, and guard() drops it from the answer. Each time the same move
gets blocked again, the block lasts twice as long (6, 12, 24... turns), so a
cycle of several failing moves can't outlast its blocks. A block also lifts
when a new item or new research shows up (a craft that lacked plates may work
once plates exist).

When nothing has changed for STUCK_TURNS turns while moves keep failing, the
coach stops trusting the model and sends the planner's moves instead (never
against a player directive).
"""

from __future__ import annotations

import json
from collections import deque

from .planner import entry_key

FAIL_LIMIT = 2
REPEAT_LIMIT = 3
BLOCK_TURNS = 6
MAX_BLOCK_TURNS = 48
STUCK_TURNS = 12
MAX_ENTRIES = 4
# Entries that never block or count as progress.
PASSIVE = {"chat", "summary", "wait", "add_note", "note"}
# A "failed" tend/build_ghosts just means nothing to do right now; never count
# those as failures. Repeating them with no progress still blocks tend.
NO_FAIL_BLOCK = {"skill:tend", "skill:build_ghosts"}
NO_REPEAT_BLOCK = {"skill:build_ghosts"}

Steps = list[tuple[dict, str]]


def _passive(e: dict) -> bool:
    return not e.get("skill") and e.get("action") in PASSIVE


def result_key(r: dict) -> str:
    """entry_key for a result from the mod (skills are labelled "skill:<name>")."""
    label = str(r.get("action") or "")
    if label.startswith("skill:"):
        return entry_key({**r, "skill": label[6:]})
    return entry_key(r)


def _research_sig(p: dict) -> str:
    research = p.get("research") or {}
    return json.dumps([research.get("current"), sorted(research.get("done") or [])])


BUILD_PROGRESS = ("boiler", "steam-engine", "assembling-machine-1", "lab")


def _miner_total(p: dict) -> int:
    """Drills plus the other things the build order adds (power, assemblers, labs)."""
    factory = p.get("factory") or {}
    by_type = factory.get("by_type") or {}
    return (sum((factory.get("miners_by_resource") or {}).values())
            + sum(int(by_type.get(n, 0)) for n in BUILD_PROGRESS))


class Coach:
    def __init__(self):
        self.turn = 0
        self.blocks: dict[str, dict] = {}       # key -> {fails, detail, turn, sig, until?}
        self.strikes: dict[str, int] = {}       # key -> times blocked (survives expiry)
        self.history: deque[dict] = deque(maxlen=12)
        self.sent: deque[tuple[str, ...]] = deque(maxlen=REPEAT_LIMIT)
        self.seen_ids: deque[str] = deque(maxlen=50)
        self.context: tuple | None = None
        # Progress = an item never held before, research moving, or more drills/power/assemblers.
        # Inventory counts churn every turn (5x crafting), so they don't count.
        self.progress = 0
        self.items_seen: set[str] = set()
        self._research = None
        self._miners = 0
        self.sig_since = 0                      # turn of the last progress
        self.last_fail_turn = -1

    def _note_progress(self, p: dict) -> None:
        names = {i.get("name") for i in p.get("inventory") or [] if isinstance(i, dict)}
        research, miners = _research_sig(p), _miner_total(p)
        new_items = names - self.items_seen
        first = self._research is None
        if not first and (new_items or research != self._research or miners > self._miners):
            self.progress += 1
            self.sig_since = self.turn
        self.items_seen |= names
        self._research, self._miners = research, max(miners, self._miners)

    # -- per request ------------------------------------------------------
    def observe(self, payload: dict) -> None:
        p = payload.get("perception") or {}
        mem = payload.get("memory") or {}
        context = ((p.get("surface") or {}).get("name"), mem.get("user_directive"))
        if context != self.context:     # new planet or new player order: start over
            self.__init__()
            self.context = context
        self.turn += 1
        self._note_progress(p)
        sig = self.progress

        rid = mem.get("last_results_req_id")
        results = mem.get("last_action_results") or []
        if rid and rid not in self.seen_ids:
            self.seen_ids.append(rid)
            line = []
            for r in results:
                if not isinstance(r, dict):
                    continue
                k = result_key(r)
                line.append(f"{'OK' if r.get('ok') else 'FAILED'} {k}")
                if r.get("ok"):
                    b = self.blocks.get(k)
                    if b and b.get("fails"):
                        del self.blocks[k]
                elif k not in NO_FAIL_BLOCK:
                    self.last_fail_turn = self.turn
                    b = self.blocks.setdefault(k, {"fails": 0})
                    b.update(fails=b["fails"] + 1, detail=str(r.get("detail") or "")[:160],
                             turn=self.turn, sig=sig)
                    if b["fails"] >= FAIL_LIMIT and "until" not in b:
                        self._activate(k, b)
            if line:
                self.history.append({"turn": self.turn, "results": line})

        for k, b in list(self.blocks.items()):
            expired = self.turn > b["until"] if "until" in b else self.turn - b["turn"] > BLOCK_TURNS
            if expired or b["sig"] != sig:
                del self.blocks[k]

    def _activate(self, key: str, b: dict) -> None:
        n = self.strikes[key] = self.strikes.get(key, 0) + 1
        b["until"] = self.turn + min(BLOCK_TURNS * 2 ** (n - 1), MAX_BLOCK_TURNS)

    def blocked(self) -> set[str]:
        return {k for k, b in self.blocks.items() if "until" in b}

    def stuck(self) -> bool:
        """Nothing new for a while and moves still failing: the model is lost."""
        return (self.turn - self.sig_since >= STUCK_TURNS
                and self.turn - self.last_fail_turn < STUCK_TURNS)

    def prompt_text(self, steps: Steps | None) -> str:
        lines = []
        if self.history:
            lines.append("Recent turns (oldest first):")
            for h in list(self.history)[-6:]:
                lines.append(f"  turn {h['turn']}: " + "; ".join(h["results"]))
        blocked = self.blocked()
        if blocked:
            lines.append("BLOCKED — these keep failing or repeating; do NOT send them again, do something else:")
            for k in sorted(blocked):
                b = self.blocks[k]
                lines.append(f"  {k} → {b.get('detail') or 'repeated with no progress'} "
                             f"(blocked for {b['until'] - self.turn} more turns)")
        if steps:
            moves = json.dumps([e for e, _ in steps])
            why = "; ".join(r for _, r in steps)
            lines.append(f"SUGGESTED MOVES (send these unless the player asked for something else): {moves} — {why}")
        return "\n".join(lines)

    # -- per answer -------------------------------------------------------
    def guard(self, entries: list[dict] | None, payload: dict,
              steps: Steps | None) -> tuple[list[dict], str | None]:
        """Drop blocked moves. If nothing useful is left, or the AI is stuck,
        use the planner's moves, but never against a player directive /
        forced skill. Returns (entries, reason-if-overridden)."""
        mem = payload.get("memory") or {}
        blocked = self.blocked()
        player_led = mem.get("user_directive") or mem.get("force_skill")
        plan = [e for e, _ in steps or [] if entry_key(e) not in blocked]
        entries = list(entries or [])
        kept = [e for e in entries if _passive(e) or entry_key(e) not in blocked]
        dropped = [entry_key(e) for e in entries if e not in kept]
        reason = None
        if plan and not player_led and self.stuck():
            kept = [e for e in kept if _passive(e)] + plan
            reason = f"no progress for {self.turn - self.sig_since} turns — sent the planner's moves"
            self.sig_since = self.turn          # give the plan a fresh window
        elif not any(not _passive(e) for e in kept) and (dropped or not entries):
            if plan and not player_led:
                kept += plan
                reason = "used the planner's moves (" + "; ".join(r for _, r in steps) + ")"
            else:
                kept.append({"action": "wait"})
                reason = "nothing unblocked to do — waiting"
            if dropped:
                reason = f"dropped blocked {', '.join(dropped)}; {reason}"
        elif dropped:
            reason = f"dropped blocked {', '.join(dropped)}"
        kept = kept[:MAX_ENTRIES]               # the mod/schema take at most 4
        self._record_sent(kept)
        return kept, reason

    def _record_sent(self, entries: list[dict]) -> None:
        keys = tuple(sorted(entry_key(e) for e in entries if not _passive(e)))
        self.sent.append(keys)
        if keys and len(self.sent) == REPEAT_LIMIT and len(set(self.sent)) == 1:
            for k in keys:
                if k not in NO_REPEAT_BLOCK:
                    b = self.blocks[k] = {"fails": 0, "repeated": True, "turn": self.turn,
                                          "detail": f"sent {REPEAT_LIMIT} turns in a row with no progress",
                                          "sig": self.progress}
                    self._activate(k, b)
            self.sent.clear()
