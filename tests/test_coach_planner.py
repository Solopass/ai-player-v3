"""Coach (loop breaker) and planner (next step) — built from states seen in the
first real game (2026-10-30)."""

import copy

from bridge import planner
from bridge.coach import Coach


def spawn() -> dict:
    """Fresh start: starter items, nothing built."""
    return {
        "surface": {"name": "nauvis"},
        "home": {"position": {"x": 18, "y": 4}, "distance": 0},
        "inventory": [{"name": "coal", "count": 100}, {"name": "stone", "count": 50},
                      {"name": "iron-plate", "count": 50}, {"name": "wood", "count": 50},
                      {"name": "burner-mining-drill", "count": 4}, {"name": "stone-furnace", "count": 4},
                      {"name": "lab", "count": 1}],
        "factory": {"total": 0, "by_type": {}, "miners_by_resource": {}, "labs": {"count": 0, "without_packs": 0}},
        "needs": {"burners_low_fuel": [], "outputs_full": []},
        "research": {"current": None, "done": [], "triggers": []},
        "production": {"items": {}},
        "landmarks": {"resources": [{"name": "coal", "x": 43, "y": -13, "distance": 30},
                                    {"name": "iron-ore", "x": 43, "y": -51, "distance": 60}]},
        "ghosts": {"count": 0}, "deconstruction": {"count": 0},
    }


def stuck_fuel_all() -> dict:
    """The live fuel_all loop: drills on coal, one iron drill spilling on the ground."""
    p = spawn()
    p["inventory"] = [{"name": "coal", "count": 150}, {"name": "wood", "count": 102},
                      {"name": "stone", "count": 35}, {"name": "iron-plate", "count": 5},
                      {"name": "stone-furnace", "count": 2}, {"name": "lab", "count": 1}]
    p["factory"]["miners_by_resource"] = {"coal": 8, "iron-ore": 1}
    p["needs"]["outputs_full"] = [{"name": "burner-mining-drill", "position": {"x": 47, "y": -31}, "drop": "ground"}]
    return p


def lab_trigger() -> dict:
    """Bootstrap done; the next tech wants a NEW lab crafted while one is held."""
    p = spawn()
    p["factory"]["miners_by_resource"] = {"coal": 1, "iron-ore": 2, "copper-ore": 1}
    p["production"]["items"] = {"iron-plate": {"per_min": 20}}
    p["research"]["triggers"] = [{"tech": "automation-science-pack", "type": "craft-item",
                                  "target": "lab", "count": 1}]
    return p


def payload(p: dict, results=None, rid=None, **mem) -> dict:
    return {"perception": p, "memory": {"last_action_results": results or [],
                                        "last_results_req_id": rid, **mem}}


# --- planner -----------------------------------------------------------------

def test_spawn_builds_coal_first():
    entry, _ = planner.next_step(spawn())
    assert entry == {"skill": "build_miner", "resource": "coal", "output": "chest", "count": 1}


def test_spawn_turn_is_several_moves():
    moves = [e for e, _ in planner.next_steps(spawn())]
    assert len(moves) == 4
    assert moves[0]["resource"] == "coal"


def test_no_drills_chains_tend_craft_build():
    p = spawn()
    p["inventory"] = [i for i in p["inventory"] if i["name"] != "burner-mining-drill"]
    p["landmarks"]["resources"][0]["distance"] = 10
    moves = [e for e, _ in planner.next_steps(p)]
    assert moves[:3] == [{"skill": "tend"},
                     {"skill": "craft_for", "item": "burner-mining-drill", "count": 1},
                     {"skill": "build_miner", "resource": "coal", "output": "chest", "count": 1}]


def test_stuck_state_tends_the_spilling_drill():
    entry, why = planner.next_step(stuck_fuel_all())
    assert entry == {"skill": "tend"}
    assert "drills" in why


def test_lab_trigger_crafts_one_more_lab():
    entry, _ = planner.next_step(lab_trigger())
    assert entry == {"skill": "craft_for", "item": "lab", "count": 2}


def test_ghosts_come_first():
    p = stuck_fuel_all()
    p["ghosts"] = {"count": 3}
    assert planner.next_step(p)[0] == {"skill": "build_ghosts"}


def test_far_ore_goes_to_landmark_first():
    p = spawn()
    p["factory"]["miners_by_resource"] = {"coal": 1}
    entry, _ = planner.next_step(p)
    assert entry == {"skill": "goto", "position": {"x": 43, "y": -51}}


def test_planner_skips_blocked_steps():
    p = spawn()
    blocked = {planner.entry_key({"skill": "build_miner", "resource": "coal", "output": "chest", "count": 1})}
    entry, _ = planner.next_step(p, blocked)
    assert entry["skill"] in ("goto", "build_miner") and entry.get("resource") != "coal"


# --- coach -------------------------------------------------------------------

FAIL = {"action": "skill:craft_for", "item": "lab", "count": 1, "ok": False,
        "detail": "craft_for: already have 1 lab"}


def test_blocks_after_two_failures_and_substitutes_planner_step():
    c, p = Coach(), lab_trigger()
    c.observe(payload(p, [FAIL], "r1"))
    c.observe(payload(p, [FAIL], "r2"))
    key = planner.entry_key({"skill": "craft_for", "item": "lab", "count": 1})
    assert key in c.blocked()
    out, why = c.guard([{"skill": "craft_for", "item": "lab", "count": 1}], payload(p),
                       planner.next_steps(p, c.blocked()))
    assert out[0] == {"skill": "craft_for", "item": "lab", "count": 2}
    assert "dropped" in why


def test_same_batch_counted_once():
    c, p = Coach(), lab_trigger()
    for _ in range(3):
        c.observe(payload(p, [FAIL], "r1"))
    assert not c.blocked()


def test_unblocks_when_inventory_changes():
    c, p = Coach(), lab_trigger()
    c.observe(payload(p, [FAIL], "r1"))
    c.observe(payload(p, [FAIL], "r2"))
    assert c.blocked()
    richer = copy.deepcopy(p)
    richer["inventory"].append({"name": "copper-plate", "count": 30})
    c.observe(payload(richer, [], "r3"))
    assert not c.blocked()


def test_never_returns_a_blocked_step():
    c, p = Coach(), spawn()
    step = ({"skill": "build_miner", "resource": "coal", "output": "chest"}, "x")
    bad = {"action": "skill:build_miner", "resource": "coal", "output": "chest", "ok": False, "detail": "no"}
    c.observe(payload(p, [bad], "r1"))
    c.observe(payload(p, [bad], "r2"))
    out, _ = c.guard([step[0]], payload(p), [step])
    assert out == [{"action": "wait"}]


def test_directive_suppresses_substitution():
    c, p = Coach(), lab_trigger()
    c.observe(payload(p, [FAIL], "r1", user_directive="build a wall"))
    c.observe(payload(p, [FAIL], "r2", user_directive="build a wall"))
    out, _ = c.guard([{"skill": "craft_for", "item": "lab", "count": 1}],
                     payload(p, user_directive="build a wall"), planner.next_steps(p, c.blocked()))
    assert out == [{"action": "wait"}]


def test_repeating_an_ok_move_without_progress_blocks_it():
    c, p = Coach(), stuck_fuel_all()
    move = {"skill": "fuel_all"}
    for i in range(3):
        c.observe(payload(p, [], f"r{i}"))
        c.guard([move], payload(p), None)
    c.observe(payload(p, [], "r9"))
    assert planner.entry_key(move) in c.blocked()


def test_idle_tend_is_not_a_failure_but_repeats_block():
    c, p = Coach(), stuck_fuel_all()
    idle = {"action": "skill:tend", "ok": False, "detail": "tend: collected nothing"}
    c.observe(payload(p, [idle], "r0"))
    c.observe(payload(p, [idle], "r1"))
    assert "skill:tend" not in c.blocked()          # failures alone don't block it
    for _ in range(3):
        c.guard([{"skill": "tend"}], payload(p), None)
    c.observe(payload(p, [], "r9"))
    assert "skill:tend" in c.blocked()              # but 3 turns of nothing do


def test_out_of_coal_moves_past_blocked_tend():
    p = stuck_fuel_all()
    p["inventory"] = [i for i in p["inventory"] if i["name"] != "coal"]
    p["needs"]["outputs_full"] = []
    entry, _ = planner.next_step(p, {"skill:tend"})
    assert entry == {"skill": "gather", "item": "coal", "count": 50}


def test_counts_only_changes_dont_unblock():
    c, p = Coach(), lab_trigger()
    c.observe(payload(p, [FAIL], "r1"))
    c.observe(payload(p, [FAIL], "r2"))
    more = copy.deepcopy(p)
    more["inventory"][0]["count"] += 7
    c.observe(payload(more, [], "r3"))
    assert c.blocked()


def _fail(key_entry: dict) -> dict:
    return {**{k: v for k, v in key_entry.items() if k != "skill"},
            "action": "skill:" + key_entry["skill"], "ok": False, "detail": "nope"}


def test_blocks_escalate_so_cycles_cant_outlast_them():
    c, p = Coach(), lab_trigger()
    move = {"skill": "craft_for", "item": "copper-plate", "count": 40}
    rid = iter(range(1000))
    durations = []
    for _ in range(3):
        c.observe(payload(p, [_fail(move)], f"r{next(rid)}"))
        c.observe(payload(p, [_fail(move)], f"r{next(rid)}"))
        b = c.blocks[planner.entry_key(move)]
        durations.append(b["until"] - c.turn)
        while planner.entry_key(move) in c.blocked():      # let it expire
            c.observe(payload(p, [], f"r{next(rid)}"))
    assert durations == [6, 12, 24]


def test_stuck_ai_gets_the_planners_moves():
    c, p = Coach(), spawn()
    bad = {"skill": "craft_for", "item": "iron-plate", "count": 91}
    for i in range(13):
        c.observe(payload(p, [_fail(bad)] if i % 2 else [], f"r{i}"))
    assert c.stuck()
    out, why = c.guard([{"skill": "gather", "item": "wood", "count": 10}], payload(p), planner.next_steps(p))
    assert out[0]["skill"] == "build_miner" and "no progress" in why


def test_new_drill_counts_as_progress():
    c, p = Coach(), spawn()
    c.observe(payload(p, [], "r1"))
    more = copy.deepcopy(p)
    more["factory"]["miners_by_resource"] = {"coal": 1}
    c.observe(payload(more, [], "r2"))
    assert c.sig_since == 2
