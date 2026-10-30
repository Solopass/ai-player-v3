"""
Turn memory and loop breaker.

The mod reports only the previous turn's results, so on its own the model
can't tell it has sent the same failing move ten times. The coach lives in the
bridge process and remembers:

- failures per move (planner.entry_key), counted once per reported batch
  (memory.last_results_req_id, so a stale batch isn't counted twice);
- what was sent each turn, to catch the same moves repeated with no progress.

A move that failed twice, or was sent three turns running, is BLOCKED: the
prompt says so, and guard() drops it from the answer. Blocks lift after
BLOCK_TURNS turns or as soon as the inventory/research changes (a craft that
lacked plates may work once plates exist).
"""

from __future__ import annotations

import json
from collections import deque

from .planner import entry_key

FAIL_LIMIT = 2
REPEAT_LIMIT = 3
BLOCK_TURNS = 6
# Entries that never block or count as progress.
PASSIVE = {"chat", "summary", "wait", "add_note", "note"}
# A "failed" tend/build_ghosts just means nothing to do right now; never count
# those as failures. Repeating them with no progress still blocks tend.
NO_FAIL_BLOCK = {"skill:tend", "skill:build_ghosts"}
NO_REPEAT_BLOCK = {"skill:build_ghosts"}


def _passive(e: dict) -> bool:
    return not e.get("skill") and e.get("action") in PASSIVE


def result_key(r: dict) -> str:
    """entry_key for a result from the mod (skills are labelled "skill:<name>")."""
    label = str(r.get("action") or "")
    if label.startswith("skill:"):
        return entry_key({**r, "skill": label[6:]})
    return entry_key(r)


def _state_sig(p: dict) -> str:
    # Item NAMES only: counts change nearly every turn, which would lift every
    # block at once. A new item (plates arrive, a drill gets crafted) or new
    # research is real progress.
    inv = sorted({i.get("name") for i in p.get("inventory") or [] if isinstance(i, dict)})
    research = p.get("research") or {}
    return json.dumps([inv, research.get("current"), sorted(research.get("done") or [])])


class Coach:
    def __init__(self):
        self.turn = 0
        self.blocks: dict[str, dict] = {}       # key -> {fails, detail, turn, sig}
        self.history: deque[dict] = deque(maxlen=12)
        self.sent: deque[tuple[str, ...]] = deque(maxlen=REPEAT_LIMIT)
        self.seen_ids: deque[str] = deque(maxlen=50)
        self.context: tuple | None = None

    # -- per request ------------------------------------------------------
    def observe(self, payload: dict) -> None:
        p = payload.get("perception") or {}
        mem = payload.get("memory") or {}
        context = ((p.get("surface") or {}).get("name"), mem.get("user_directive"))
        if context != self.context:     # new planet or new player order: start over
            self.__init__()
            self.context = context
        self.turn += 1
        sig = self._last_sig = _state_sig(p)

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
                    b = self.blocks.setdefault(k, {"fails": 0})
                    b.update(fails=b["fails"] + 1, detail=str(r.get("detail") or "")[:160],
                             turn=self.turn, sig=sig)
            if line:
                self.history.append({"turn": self.turn, "results": line})

        for k, b in list(self.blocks.items()):
            if self.turn - b["turn"] > BLOCK_TURNS or b["sig"] != sig:
                del self.blocks[k]

    def blocked(self) -> set[str]:
        return {k for k, b in self.blocks.items()
                if b.get("fails", 0) >= FAIL_LIMIT or b.get("repeated")}

    def prompt_text(self, suggestion: tuple[dict, str] | None) -> str:
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
                why = b.get("detail") or "repeated with no progress"
                lines.append(f"  {k} → {why}")
        if suggestion:
            entry, reason = suggestion
            lines.append(f"SUGGESTED NEXT STEP (follow it unless the player asked for something else): "
                         f"{json.dumps(entry)} — {reason}")
        return "\n".join(lines)

    # -- per answer -------------------------------------------------------
    def guard(self, entries: list[dict] | None, payload: dict,
              suggestion: tuple[dict, str] | None) -> tuple[list[dict], str | None]:
        """Drop blocked moves. If nothing useful is left, use the planner's
        step, but never against a player directive / forced skill. Returns
        (entries, reason-if-overridden)."""
        mem = payload.get("memory") or {}
        blocked = self.blocked()
        entries = list(entries or [])
        kept = [e for e in entries if _passive(e) or entry_key(e) not in blocked]
        dropped = [entry_key(e) for e in entries if e not in kept]
        reason = None
        if not any(not _passive(e) for e in kept) and (dropped or not entries):
            player_led = mem.get("user_directive") or mem.get("force_skill")
            if suggestion and not player_led and entry_key(suggestion[0]) not in blocked:
                kept.append(suggestion[0])
                reason = f"used the planner's step ({suggestion[1]})"
            else:
                kept.append({"action": "wait"})
                reason = "nothing unblocked to do — waiting"
            if dropped:
                reason = f"dropped blocked {', '.join(dropped)}; {reason}"
        elif dropped:
            reason = f"dropped blocked {', '.join(dropped)}"
        self._record_sent(kept)
        return kept, reason

    def _record_sent(self, entries: list[dict]) -> None:
        keys = tuple(sorted(entry_key(e) for e in entries if not _passive(e)))
        self.sent.append(keys)
        if keys and len(self.sent) == REPEAT_LIMIT and len(set(self.sent)) == 1:
            for k in keys:
                if k not in NO_REPEAT_BLOCK:
                    self.blocks[k] = {"fails": 0, "repeated": True, "turn": self.turn,
                                      "detail": f"sent {REPEAT_LIMIT} turns in a row with no progress",
                                      "sig": self._last_sig}
            self.sent.clear()

    _last_sig = ""
