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
    p["power"] = {"has_grid": True}                  # past the power milestone
    p["factory"]["by_type"] = {"boiler": 1, "steam-engine": 2}
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


# --- planner past the bootstrap (round 4) -------------------------------------

def post_bootstrap(**inv) -> dict:
    """Bootstrap done (coal, 2 iron, copper drills, 20 iron/min); power not built yet."""
    p = spawn()
    p["factory"]["miners_by_resource"] = {"coal": 1, "iron-ore": 2, "copper-ore": 1}
    p["production"]["items"] = {"iron-plate": {"per_min": 20}}
    p["inventory"] = [{"name": n, "count": c} for n, c in
                      {"coal": 100, "offshore-pump": 1, "boiler": 1, "steam-engine": 2, "pipe": 10,
                       "small-electric-pole": 10, **inv}.items()]
    p["landmarks"]["water"] = {"x": 20, "y": 20, "distance": 15}
    return p


def powered(p: dict, techs=()) -> dict:
    p["power"] = {"has_grid": True}
    p["factory"]["by_type"] = {"boiler": 1, "steam-engine": 2}
    p["research"]["done"] = list(techs)
    return p


def moves(p, blocked=frozenset(), limit=planner.MAX_MOVES):
    return [e for e, _, _ in planner.next_plan(p, blocked, limit)]


def test_no_grid_builds_power():
    plan = planner.next_plan(post_bootstrap())
    assert plan[0][0] == {"skill": "build_power"}
    assert plan[0][2] is True


def test_far_water_goes_there_first():
    p = post_bootstrap()
    p["landmarks"]["water"] = {"x": 90, "y": 10, "distance": 80}
    ms = moves(p)
    assert ms[0] == {"skill": "goto", "position": {"x": 90, "y": 10}}
    assert ms[1] == {"skill": "build_power"}


def test_missing_power_parts_are_crafted_before_the_build():
    p = post_bootstrap(**{"steam-engine": 0, "boiler": 0})
    ms = moves(p)
    boiler = {"skill": "craft_for", "item": "boiler", "count": 1}
    assert boiler in ms
    assert {"skill": "craft_for", "item": "steam-engine", "count": 2} in ms
    assert ms.index({"skill": "build_power"}) > ms.index(boiler)


def test_automation_research_once_powered():
    plan = planner.next_plan(powered(post_bootstrap()))
    assert plan[0][0] == {"skill": "research", "tech": "automation"} and plan[0][2]


def test_automation_waits_for_pending_trigger_techs():
    p = powered(post_bootstrap())
    p["research"]["triggers"] = [{"tech": "automation-science-pack", "type": "craft-item",
                                  "target": "lab", "count": 1}]
    first = planner.next_plan(p)[0]
    assert first[0]["skill"] == "craft_for" and first[2] is False     # a guess, not a sure move


def test_smelting_counts_electric_pairs_from_current_rates():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 12}, "copper-plate": {"per_min": 0}}
    builds = [e for e in moves(p, limit=8) if e.get("skill") == "build_miner"]
    assert builds[0] == {"skill": "build_miner", "resource": "iron-ore", "output": "furnace", "count": 1,
                         "drill": "electric"}
    p["production"]["items"] = {"iron-plate": {"per_min": 11}, "copper-plate": {"per_min": 0}}
    builds = [e for e in moves(p, limit=8) if e.get("skill") == "build_miner"]
    assert builds[0]["resource"] == "iron-ore" and builds[0]["count"] == 2
    p["production"]["items"] = {"iron-plate": {"per_min": 40}, "copper-plate": {"per_min": 0}}
    builds = [e for e in moves(p, limit=8) if e.get("skill") == "build_miner"]
    assert builds[0]["resource"] == "copper-ore" and builds[0]["count"] == 1


def test_smelting_needs_the_electric_drill_tech():
    p = powered(post_bootstrap(), ["automation"])
    p["production"]["items"] = {"iron-plate": {"per_min": 12}}
    assert not [e for e in moves(p) if e.get("skill") == "build_miner"]


def test_red_cell_after_automation_and_smelting():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 40}, "copper-plate": {"per_min": 20}}
    ms = moves(p)
    craft = {"skill": "craft_for", "item": "assembling-machine-1", "count": 3}
    assert {"skill": "build_red_cell"} in ms
    assert ms.index({"skill": "build_red_cell"}) > ms.index(craft)


def test_built_red_cell_is_tended():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 40}, "copper-plate": {"per_min": 20}}
    p["factory"]["by_type"]["assembling-machine-1"] = 3
    p["factory"]["assemblers"] = [{"recipe": "automation-science-pack", "status": "working"}]
    assert moves(p)[0] == {"skill": "tend"}


def test_a_lone_gear_assembler_does_not_block_the_red_cell():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 40}, "copper-plate": {"per_min": 20}}
    p["factory"]["assemblers"] = [{"recipe": "iron-gear-wheel", "status": "working"}]
    assert {"skill": "build_red_cell"} in moves(p, limit=8)


def test_built_electric_pairs_count_before_the_rate_catches_up():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 12}, "copper-plate": {"per_min": 20}}
    p["factory"]["electric_miners"] = {"iron-ore": 2}
    assert not [e for e in moves(p, limit=8) if e.get("resource") == "iron-ore"]


def test_sure_prefix_stops_at_the_first_guess():
    plan = [({"skill": "tend"}, "a", True), ({"skill": "research"}, "b", False),
            ({"skill": "gather", "item": "coal"}, "c", True)]
    assert planner.sure_prefix(plan) == [({"skill": "tend"}, "a")]
    assert planner.sure_prefix(plan[1:]) == []


# --- hybrid autopilot ----------------------------------------------------------

import pytest

from bridge import agent as agent_mod
from bridge.config import BridgeConfig
from bridge.factorio.watcher import PendingRequest


class Recorder:
    """Stands in for the LLM provider: counts calls, answers with a fixed move."""
    def __init__(self):
        self.calls = 0

    def __call__(self, messages, cfg):
        self.calls += 1
        return '[{"skill":"wait"}]'


@pytest.fixture
def pilot(tmp_path, monkeypatch):
    rec = Recorder()
    monkeypatch.setattr(agent_mod, "get_provider", lambda cfg: rec)
    monkeypatch.setattr(agent_mod.blueprints, "load_library", lambda: {})
    cfg = BridgeConfig()
    cfg.output_dir = tmp_path
    cfg.autopilot = True
    return agent_mod.Agent(), cfg, rec


def req(n: int, p: dict, results=None, rid=None, **mem) -> PendingRequest:
    return PendingRequest(req_id=f"q{n}", payload=payload(p, results, rid, **mem), path=None)


def test_autopilot_skips_the_model_for_sure_moves(pilot):
    agent, cfg, rec = pilot
    out = agent.decide(req(1, spawn()), cfg)
    assert rec.calls == 0
    assert out[0].pop("source") == "autopilot"
    assert out[0] == {"skill": "build_miner", "resource": "coal", "output": "chest", "count": 1}
    assert agent.status["model"] == "autopilot"


def test_autopilot_off_asks_the_model(pilot):
    agent, cfg, rec = pilot
    cfg.autopilot = False
    agent.decide(req(1, spawn()), cfg)
    assert rec.calls == 1


def test_player_message_goes_to_the_model(pilot):
    agent, cfg, rec = pilot
    r = req(1, spawn())
    r.payload["user_message"] = "build me a house"
    agent.decide(r, cfg)
    assert rec.calls == 1


def test_directive_goes_to_the_model(pilot):
    agent, cfg, rec = pilot
    agent.decide(req(1, spawn(), user_directive="gather wood"), cfg)
    assert rec.calls == 1


def test_guess_moves_go_to_the_model(pilot):
    agent, cfg, rec = pilot
    p = powered(post_bootstrap())
    p["research"]["triggers"] = [{"tech": "automation-science-pack", "type": "craft-item",
                                  "target": "lab", "count": 1}]
    agent.decide(req(1, p), cfg)
    assert rec.calls == 1


def test_every_sixth_turn_is_the_model(pilot):
    agent, cfg, rec = pilot
    p = spawn()
    for n in range(1, 7):
        p["inventory"].append({"name": f"item{n}", "count": 1})   # progress, so nothing gets blocked
        agent.decide(req(n, p), cfg)
    assert rec.calls == 1 and agent.auto_streak == 0


def test_failed_autopilot_move_hands_the_next_turn_to_the_model(pilot):
    agent, cfg, rec = pilot
    p = spawn()
    agent.decide(req(1, p), cfg)
    assert rec.calls == 0
    fail = {"action": "skill:build_miner", "resource": "coal", "output": "chest", "ok": False,
            "detail": "build_miner: no spot"}
    agent.decide(req(2, p, [fail], rid="q1"), cfg)
    assert rec.calls == 1


def test_successful_autopilot_move_keeps_going(pilot):
    agent, cfg, rec = pilot
    p = spawn()
    agent.decide(req(1, p), cfg)
    ok = {"action": "skill:build_miner", "resource": "coal", "output": "chest", "ok": True, "detail": "built"}
    p["factory"]["miners_by_resource"] = {"coal": 1}
    p["landmarks"]["resources"][1]["distance"] = 10
    agent.decide(req(2, p, [ok], rid="q1"), cfg)
    assert rec.calls == 0


def test_idle_tend_failure_does_not_stop_the_autopilot(pilot):
    agent, cfg, rec = pilot
    p = stuck_fuel_all()
    agent.decide(req(1, p), cfg)
    idle = {"action": "skill:tend", "ok": False, "detail": "tend: nothing to do"}
    agent.decide(req(2, p, [idle], rid="q1"), cfg)
    assert rec.calls == 0


def test_autopilot_turns_feed_the_coach(pilot):
    agent, cfg, rec = pilot
    p = spawn()
    agent.decide(req(1, p), cfg)
    assert agent.coach.sent                      # the turn was recorded for loop detection
    fail = {"action": "skill:build_miner", "resource": "coal", "output": "chest", "ok": False, "detail": "x"}
    for n in (2, 3):
        agent.decide(req(n, p, [fail], rid=f"q{n - 1}"), cfg)
    key = planner.entry_key({"skill": "build_miner", "resource": "coal", "output": "chest", "count": 1})
    assert key in agent.coach.blocked()


def test_stuck_ai_goes_back_to_the_model(pilot):
    agent, cfg, rec = pilot
    p = spawn()
    agent.decide(req(1, p), cfg)
    agent.coach.sig_since = -20                  # no progress for a long time...
    agent.coach.last_fail_turn = agent.coach.turn    # ...while moves keep failing
    agent.decide(req(2, p), cfg)
    assert rec.calls == 1
