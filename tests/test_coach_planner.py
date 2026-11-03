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
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
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


def labbed() -> dict:
    """Past red science: a lab is standing, nothing is being researched."""
    p = lab_trigger()
    p["research"]["triggers"] = []
    p["research"]["done"] = ["steam-power", "electronics", "automation-science-pack", "automation"]
    p["factory"]["labs"] = {"count": 1, "without_packs": 0}
    p["production"]["items"].update({"copper-plate": {"per_min": 20}})
    return p


def research_moves(p, blocked=frozenset()):
    return [e for e, _, _ in planner.next_plan(p, blocked, 24) if e.get("skill") == "research"]


def test_research_order_queues_the_next_unresearched_tech():
    p = labbed()
    # electric drills come right after automation: the economy-first ladder depends on them
    assert research_moves(p)[0] == {"skill": "research", "tech": "electric-mining-drill"}
    p["research"]["done"] += ["electric-mining-drill"]
    assert research_moves(p)[0] == {"skill": "research", "tech": "logistics"}
    p["research"]["done"] += ["logistics"]
    assert research_moves(p)[0] == {"skill": "research", "tech": "logistic-science-pack"}


def test_research_order_skips_trigger_techs_and_blocked_ones():
    p = labbed()
    p["research"]["done"] += ["electric-mining-drill"]
    p["production"]["items"].update({"iron-plate": {"per_min": 200}, "copper-plate": {"per_min": 100}})
    p["research"]["triggers"] = [{"tech": "logistics", "type": "craft-item", "target": "lab", "count": 1}]
    assert research_moves(p)[0]["tech"] == "logistic-science-pack"
    p["research"]["triggers"] = []
    blocked = {planner.entry_key({"skill": "research", "tech": "logistics"})}
    assert research_moves(p, blocked)[0]["tech"] == "logistic-science-pack"


def test_research_order_is_quiet_while_researching_or_without_a_lab():
    p = labbed()
    p["research"]["current"] = "logistics"
    assert all("tech" not in e for e in research_moves(p))
    p = labbed()
    p["factory"]["labs"] = {"count": 0, "without_packs": 0}
    assert all("tech" not in e for e in research_moves(p))


def test_research_order_threat_moves_military_to_front():
    p = labbed()
    p["research"]["done"] = ["steam-power", "automation-science-pack", "automation"]
    p["threat"] = {"nearest": {"name": "biter-spawner", "distance": 120}}
    order = planner.research_order(p)
    mil_first = order[0][0]
    assert mil_first in ("gun-turret", "military", "stone-wall")


def test_research_order_holds_green_techs_until_green_science_runs():
    p = labbed()
    p["research"]["done"] += [t for t, g in planner.RESEARCH_ORDER if not g]
    p["production"]["items"].update({"iron-plate": {"per_min": 200}, "copper-plate": {"per_min": 100}})  # no field wanted
    assert all("tech" not in e for e in research_moves(p))
    p["production"]["items"]["logistic-science-pack"] = {"per_min": 3}
    assert research_moves(p)[0]["tech"] == "automation-2"


def test_labs_without_packs_haul_through_the_red_cell():
    p = labbed()
    p["research"]["current"] = "logistics"
    p["factory"]["labs"] = {"count": 1, "without_packs": 1}
    p["factory"]["machines"] = [{"type": "lab", "position": {"x": 1, "y": 1}}]
    assert planner.next_step(p)[0] == {"skill": "tend"}         # no plates to craft packs from yet
    p["inventory"] += [{"name": "copper-plate", "count": 20}]
    assert planner.next_step(p)[0] == {"skill": "craft_for", "item": "automation-science-pack", "count": 10}
    p["factory"]["assemblers"] = [{"recipe": "automation-science-pack"}]
    assert planner.next_step(p)[0] == {"skill": "tend"}


def test_far_water_goes_there_before_build_power():
    p = labbed()
    p["research"]["done"] = ["steam-power", "electronics"]
    p["power"] = {"has_grid": False}
    p["factory"]["by_type"] = {}
    p["landmarks"]["water"] = {"x": -44, "y": -20, "distance": 44}
    entry, _ = planner.next_step(p)
    assert entry == {"skill": "goto", "position": {"x": -44, "y": -20}}


def test_low_coal_with_far_coal_goes_there_first():
    p = spawn()
    p["inventory"] = [{"name": "coal", "count": 1}, {"name": "burner-mining-drill", "count": 1}]
    p["landmarks"]["resources"][0].update(distance=44)
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert moves[0] == {"skill": "goto", "position": {"x": 43, "y": -13}}
    assert {"skill": "gather", "item": "coal", "count": 50} in moves


def green_ready() -> dict:
    """Red cell running, logistic-science-pack researched, no green units yet."""
    p = labbed()
    p["research"]["done"] += ["logistics", "logistic-science-pack"]
    p["production"]["items"].update({"automation-science-pack": {"per_min": 6}, "iron-plate": {"per_min": 35},
                                     "copper-plate": {"per_min": 20}})
    p["factory"]["assemblers"] = [{"recipe": "automation-science-pack"}, {"recipe": "iron-gear-wheel"},
                                  {"recipe": "automation-science-pack"}]
    p["inventory"] += [{"name": "assembling-machine-1", "count": 3}, {"name": "inserter", "count": 6}]
    return p


def test_green_cell_is_built_once_the_tech_is_done():
    moves = [e for e, _ in planner.next_steps(green_ready())]
    assert {"skill": "build_green_cell"} in moves
    p = green_ready()
    p["research"]["done"].remove("logistic-science-pack")
    assert {"skill": "build_green_cell"} not in [e for e, _ in planner.next_steps(p)]


def test_green_cell_crafts_the_parts_first_and_counts_built_units():
    p = green_ready()
    p["inventory"] = [i for i in p["inventory"] if i["name"] not in ("assembling-machine-1", "inserter")]
    p["inventory"].append({"name": "iron-plate", "count": 300})
    first = [e for e, _ in planner.next_steps(p)][:3]
    assert first[0] == {"skill": "craft_for", "item": "assembling-machine-1", "count": 3}
    assert first[1] == {"skill": "craft_for", "item": "inserter", "count": 6}
    assert first[2] == {"skill": "build_green_cell"}
    # one unit already standing besides the red cell's: still builds the rest
    p["factory"]["assemblers"].append({"recipe": "electronic-circuit"})
    p["factory"]["assemblers"] += [{"recipe": r} for r in planner.GREEN_UNITS[:1] if r != "iron-gear-wheel"]
    assert {"skill": "build_green_cell"} in [e for e, _ in planner.next_steps(p)]


def test_finished_green_cell_is_only_tended():
    p = green_ready()
    p["factory"]["assemblers"] += [{"recipe": r} for r in ("copper-cable", "electronic-circuit", "inserter",
                                                           "transport-belt", "logistic-science-pack",
                                                           "logistic-science-pack")]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "build_green_cell"} not in moves
    assert {"skill": "tend"} in moves


def test_smelted_trigger_items_are_not_hand_crafted():
    p = labbed()
    p["research"]["triggers"] = [{"tech": "steel-axe", "type": "craft-item", "target": "steel-plate", "count": 5}]
    assert not any(e.get("item") == "steel-plate" for e, _ in planner.next_steps(p, limit=8))


def threatened(**kw) -> dict:
    p = labbed()
    p["threat"] = {"nearest": {"name": "biter-spawner", "x": 90, "y": 0, "distance": 100}, **kw}
    return p


def test_enemies_near_home_research_the_turret_then_build_defense():
    p = threatened()
    assert planner.next_step(p)[0] == {"skill": "research", "tech": "gun-turret"}
    p["research"]["done"] += ["gun-turret"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert moves[-1] == {"skill": "build_defense", "count": 3} or {"skill": "build_defense", "count": 3} in moves
    assert {"skill": "craft_for", "item": "gun-turret", "count": 3} in moves


def test_far_enemies_do_not_trigger_defense():
    p = threatened()
    p["threat"]["nearest"]["distance"] = 400
    moves = [e for e, _ in planner.next_steps(p, limit=8)]
    assert not any(e.get("skill") == "build_defense" or e.get("tech") == "gun-turret" for e in moves)


def test_an_attack_triggers_defense_without_a_visible_nest():
    p = labbed()
    p["threat"] = {"nearest": None, "attack": {"name": "lab", "x": 5, "y": 5, "seconds_ago": 4}}
    p["research"]["done"] += ["gun-turret"]
    assert {"skill": "build_defense", "count": 3} in [e for e, _ in planner.next_steps(p, limit=8)]


def test_attacked_power_plant_builds_defense_at_power_site():
    p = labbed()
    p["threat"] = {"nearest": None, "attack": {"name": "boiler", "x": 40, "y": 10, "seconds_ago": 2}}
    p["research"]["done"] += ["gun-turret"]
    moves = [e for e, _ in planner.next_steps(p, limit=8)]
    assert {"skill": "build_defense", "count": 3, "site": "power"} in moves


def test_built_turrets_end_the_defense_rule():
    p = threatened()
    p["research"]["done"] += ["gun-turret"]
    p["factory"]["by_type"]["ammo-turret"] = 3
    assert not any(e.get("skill") == "build_defense" for e, _ in planner.next_steps(p, limit=8))


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
    move = {"skill": "gather", "item": "stone", "count": 20}
    for i in range(3):
        c.observe(payload(p, [], f"r{i}"))
        c.guard([move], payload(p), None)
    c.observe(payload(p, [], "r9"))
    assert planner.entry_key(move) in c.blocked()


def test_guard_drops_fuel_all():
    c, p = Coach(), spawn()
    out, _ = c.guard([{"skill": "fuel_all"}], payload(p), None)
    assert c.rewrites["drop_fuel_all"] == 1
    assert out == [{"action": "wait"}]


def test_guard_rewrites_craft_smelted():
    c, p = Coach(), spawn()
    out, _ = c.guard([{"skill": "craft_for", "item": "iron-plate", "count": 20}], payload(p), None)
    assert c.rewrites["rewrite_craft_smelted"] == 1
    assert out == [{"skill": "build_miner", "resource": "iron-ore", "output": "furnace", "count": 2}]

    out2, _ = c.guard([{"skill": "craft_for", "item": "copper-plate", "count": 10}], payload(p), None)
    assert c.rewrites["rewrite_craft_smelted"] == 2
    assert out2 == [{"skill": "build_miner", "resource": "copper-ore", "output": "furnace", "count": 1}]


def test_guard_drops_redundant_research():
    c, p = Coach(), labbed()
    p["research"]["current"] = "automation"
    p["research"]["done"] = ["logistics"]
    out, _ = c.guard([{"skill": "research", "tech": "automation"}], payload(p), None)
    assert c.rewrites["drop_redundant_research"] == 1
    assert out == [{"action": "wait"}]

    out2, _ = c.guard([{"skill": "research", "tech": "logistics"}], payload(p), None)
    assert c.rewrites["drop_redundant_research"] == 2
    assert out2 == [{"action": "wait"}]


def test_guard_drops_empty_build_ghosts():
    c, p = Coach(), spawn()
    p["ghosts"] = {"count": 0}
    out, _ = c.guard([{"skill": "build_ghosts"}], payload(p), None)
    assert c.rewrites["drop_empty_build_ghosts"] == 1
    assert out == [{"action": "wait"}]



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


def field_blocked(*ores):
    return {planner.entry_key({"skill": "build_miner", "resource": o, "output": "field", "count": 1}) for o in ores}


def test_smelting_pairs_use_the_demand_targets_when_a_field_is_blocked():
    # automation done: iron target 45, copper 22.5 (demand_targets, not the old fixed 30/15)
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    blocked = field_blocked("iron-ore", "copper-ore")
    p["production"]["items"] = {"iron-plate": {"per_min": 27}, "copper-plate": {"per_min": 30}}
    builds = [e for e in moves(p, blocked, limit=8) if e.get("skill") == "build_miner"]
    assert builds[0] == {"skill": "build_miner", "resource": "iron-ore", "output": "furnace", "count": 1,
                         "drill": "electric"}                    # (45 - 27) / 18 = 1 pair
    p["production"]["items"] = {"iron-plate": {"per_min": 12}, "copper-plate": {"per_min": 30}}
    builds = [e for e in moves(p, blocked, limit=8) if e.get("skill") == "build_miner"]
    assert builds[0]["resource"] == "iron-ore" and builds[0]["count"] == 2     # 45 - 12 = 33 -> 2 pairs
    p["production"]["items"] = {"iron-plate": {"per_min": 60}, "copper-plate": {"per_min": 0}}
    builds = [e for e in moves(p, blocked, limit=8) if e.get("skill") == "build_miner"]
    assert builds[0]["resource"] == "copper-ore" and builds[0]["count"] == 2   # 22.5 / 18 -> 2 pairs


def test_field_move_picks_the_plate_furthest_below_target():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    # iron 12/45 = 27%, copper 15/22.5 = 67%: iron first, sized for the 33/min gap (2 furnaces)
    p["production"]["items"] = {"iron-plate": {"per_min": 12}, "copper-plate": {"per_min": 15}}
    plan = planner.next_plan(p, limit=8)
    fields = [(e, sure) for e, _, sure in plan if e.get("output") == "field"]
    assert fields == [({"skill": "build_miner", "resource": "iron-ore", "output": "field", "count": 2}, True)]
    # copper furthest below target: that plate gets the field
    p["production"]["items"] = {"iron-plate": {"per_min": 44}, "copper-plate": {"per_min": 3}}
    fields = [e for e, _, _ in planner.next_plan(p, limit=8) if e.get("output") == "field"]
    assert fields == [{"skill": "build_miner", "resource": "copper-ore", "output": "field", "count": 2}]
    # both met: no field; the power rules stay ahead of the field when the grid is down
    p["production"]["items"] = {"iron-plate": {"per_min": 60}, "copper-plate": {"per_min": 30}}
    assert not [e for e in moves(p, limit=8) if e.get("output") == "field"]
    q = post_bootstrap()
    q["research"]["done"] = ["automation", "electric-mining-drill"]
    assert planner.next_plan(q)[0][0] == {"skill": "build_power"}


def test_field_move_follows_power_and_counts_built_drills():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 12}, "copper-plate": {"per_min": 30}}
    ms = moves(p, limit=8)
    assert ms.index({"skill": "build_miner", "resource": "iron-ore", "output": "field", "count": 2}) >= 0
    p["factory"]["electric_miners"] = {"iron-ore": 3}              # 3 drills will make 54/min: enough
    assert not [e for e in moves(p, limit=8) if e.get("output") == "field"]
    # a blocked field move gives way (the pair rule takes over)
    p["factory"]["electric_miners"] = {}
    blocked = field_blocked("iron-ore")
    assert not [e for e in moves(p, blocked, limit=8) if e.get("output") == "field"]
    assert [e for e in moves(p, blocked, limit=8) if e.get("output") == "furnace"]


def test_depleted_field_gets_a_replacement():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 60}, "copper-plate": {"per_min": 30}}   # targets met
    p["fields"] = [{"resource": "iron-ore", "furnaces": 3, "remaining_pct": 60, "position": {"x": 1, "y": 1}}]
    assert not [e for e in moves(p, limit=8) if e.get("output") == "field"]
    p["fields"][0]["remaining_pct"] = 15
    plan = planner.next_plan(p, limit=8)
    repl = [(e, why, sure) for e, why, sure in plan if e.get("output") == "field"]
    assert len(repl) == 1
    assert repl[0][0] == {"skill": "build_miner", "resource": "iron-ore", "output": "field", "count": 3}
    assert repl[0][2] is True and "15%" in repl[0][1]
    # once a fresh field of the same ore exists, nothing more is built
    p["fields"].append({"resource": "iron-ore", "furnaces": 3, "remaining_pct": 100, "position": {"x": 9, "y": 9}})
    assert not [e for e in moves(p, limit=8) if e.get("output") == "field"]
    # a depleted copper field is replaced independently
    p["fields"] = [{"resource": "copper-ore", "furnaces": 1, "remaining_pct": 5}]
    repl = [e for e in moves(p, limit=8) if e.get("output") == "field"]
    assert repl == [{"skill": "build_miner", "resource": "copper-ore", "output": "field", "count": 1}]


def test_science_blocks_wait_while_a_needed_field_is_queued():
    # automation done: targets 45 iron / 22.5 copper -> blocks start at 36 / 18 (built drills x 18)
    def red(iron_drills, copper_drills, blocked=frozenset()):
        p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
        p["production"]["items"] = {"iron-plate": {"per_min": 18 * iron_drills},
                                    "copper-plate": {"per_min": 18 * copper_drills}}
        p["factory"]["electric_miners"] = {"iron-ore": iron_drills, "copper-ore": copper_drills}
        return moves(p, blocked, limit=12)
    low = red(1, 1)
    assert {"skill": "build_red_cell"} not in low                   # fields queued, under 80%
    assert any(e.get("output") == "field" for e in low)
    assert {"skill": "build_red_cell"} in red(2, 1)                 # 36 / 18: at 80%
    assert {"skill": "build_red_cell"} in red(3, 2)                 # targets met: no field queued
    # past the ladder's smelting step (30/15) but under the gate (36/18): a field that keeps
    # failing must not hold science back forever
    def short(blocked=frozenset()):
        p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
        p["production"]["items"] = {"iron-plate": {"per_min": 32}, "copper-plate": {"per_min": 16}}
        p["factory"]["electric_miners"] = {"iron-ore": 1, "copper-ore": 0}
        return moves(p, blocked, limit=12)
    first = short()
    assert {"skill": "build_red_cell"} not in first
    fields = frozenset(planner.entry_key(e) for e in first if e.get("output") == "field")
    assert fields
    for _ in range(3):                          # block each field move the planner falls back to
        again = short(fields)
        more = frozenset(planner.entry_key(e) for e in again if e.get("output") == "field")
        if not more - fields:
            break
        fields |= more
    assert {"skill": "build_red_cell"} in again
    # the gate is for the electric era only: with no electric drill tech nothing waits
    p = powered(post_bootstrap(), ["automation"])
    assert planner._plates_ready(p, p["factory"], set())


def test_every_tech_the_planner_gates_on_is_researched_and_reported():
    import re
    from pathlib import Path
    root = Path(__file__).resolve().parent.parent / "mod" / "scripts"
    lua_order = set(re.findall(r'\{"([a-z0-9-]+)", (?:true|false)\}',
                               re.search(r"AISkills\.RESEARCH_ORDER = \{(.*?)\n\}", (root / "skills.lua").read_text("utf-8"), re.S).group(1)))
    key_techs = set(re.findall(r'"([a-z0-9-]+)"', re.search(r"KEY_TECHS = \{(.*?)\n\}", (root / "perception.lua").read_text("utf-8"), re.S).group(1)))
    src = (Path(planner.__file__)).read_text("utf-8")
    gated = set(re.findall(r'_tech\(p, "([a-z0-9-]+)"\)', src))
    py_order = {t for t, _ in planner.RESEARCH_ORDER}
    optional = {"military-2"}          # an ammo upgrade the AI never queues; the planner only prefers it when present
    assert "electric-mining-drill" in gated
    for tech in sorted(gated - optional):
        assert tech in lua_order, f"{tech} is gated on in planner.py but never researched (skills.lua RESEARCH_ORDER)"
        assert tech in py_order, f"{tech} is missing from planner.RESEARCH_ORDER"
        assert tech in key_techs, f"{tech} is not in perception KEY_TECHS, so research.done never reports it"
    assert lua_order == py_order, "skills.lua RESEARCH_ORDER and planner.RESEARCH_ORDER drifted apart"
    order = [t for t, _ in planner.RESEARCH_ORDER]
    assert order.index("electric-mining-drill") == order.index("automation") + 1


def test_smelting_needs_the_electric_drill_tech():
    p = powered(post_bootstrap(), ["automation"])
    p["production"]["items"] = {"iron-plate": {"per_min": 12}}
    assert not [e for e in moves(p) if e.get("skill") == "build_miner"]


def test_red_cell_after_automation_and_smelting():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 60}, "copper-plate": {"per_min": 30}}
    ms = moves(p)
    craft = {"skill": "craft_for", "item": "assembling-machine-1", "count": 3}
    assert {"skill": "build_red_cell"} in ms
    assert ms.index({"skill": "build_red_cell"}) > ms.index(craft)


def test_built_red_cell_is_tended():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 60}, "copper-plate": {"per_min": 30}}
    p["factory"]["by_type"]["assembling-machine-1"] = 3
    p["factory"]["assemblers"] = [{"recipe": "automation-science-pack", "status": "working"}]
    assert moves(p)[0] == {"skill": "tend"}


def test_a_lone_gear_assembler_does_not_block_the_red_cell():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 60}, "copper-plate": {"per_min": 30}}
    p["factory"]["assemblers"] = [{"recipe": "iron-gear-wheel", "status": "working"}]
    assert {"skill": "build_red_cell"} in moves(p, limit=8)


def test_built_electric_pairs_count_before_the_rate_catches_up():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 12}, "copper-plate": {"per_min": 20}}
    p["factory"]["electric_miners"] = {"iron-ore": 3}              # 3 x 18 = 54/min vs the 45 target
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

def test_tend_blocks_do_not_escalate():
    c = Coach()
    spans = []
    for key in ("skill:tend", "skill:gather"):
        c.turn = 0
        for _ in range(4):
            b = {"fails": 0}
            c._activate(key, b)
            spans.append((key, b["until"] - c.turn))
    assert [n for k, n in spans if k == "skill:tend"] == [6, 6, 6, 6]
    assert [n for k, n in spans if k == "skill:gather"] == [6, 12, 24, 48]


# --- reflexes (the mod fights and tends by itself) ------------------------------

def reflexive(p: dict) -> dict:
    p["reflex"] = {"state": "idle", "mode": "defend", "enabled": True}
    return p


def test_reflexes_take_over_refuelling_and_emptying():
    p = stuck_fuel_all()
    p["needs"] = {"burners_low_fuel": [{"name": "burner-mining-drill"}],
                  "outputs_full": [{"name": "stone-furnace", "drop": "furnace"},
                                   {"name": "iron-chest", "drop": "container"}]}
    assert planner.next_step(p)[0] == {"skill": "tend"}                  # old mod: the planner tends
    assert not any(e.get("skill") == "tend" and "fuel" in r for e, r in planner.next_steps(reflexive(p), limit=8))


def test_tend_stays_for_drills_spilling_on_the_ground():
    p = reflexive(stuck_fuel_all())                                      # one drill drops on the ground
    assert planner.next_step(p)[0] == {"skill": "tend"}


def test_low_coal_gathers_instead_of_tending_with_reflexes():
    p = reflexive(stuck_fuel_all())
    p["inventory"] = [i for i in p["inventory"] if i["name"] != "coal"]
    p["needs"]["outputs_full"] = []
    entry, _ = planner.next_step(p)
    assert entry == {"skill": "gather", "item": "coal", "count": 50}


def test_research_order_comes_from_the_mod_when_it_reports_one():
    p = labbed()
    p["research"]["order"] = [{"tech": "toolbelt", "green": False}, {"tech": "logistics", "green": False}]
    assert research_moves(p)[0] == {"skill": "research", "tech": "toolbelt"}
    p["research"]["order"] = []
    assert research_moves(p)[0] == {"skill": "research", "tech": "electric-mining-drill"}    # falls back to the built-in list


def test_a_turn_cancelled_by_combat_is_not_a_failure():
    c, p = Coach(), lab_trigger()
    cancelled = {**FAIL, "detail": "cancelled: combat"}
    for rid in ("r1", "r2", "r3"):
        c.observe(payload(p, [cancelled], rid))
    assert not c.blocked() and not c.blocks
    assert "CANCELLED (combat)" in c.prompt_text(None)


def test_combat_cancels_do_not_make_the_same_moves_a_loop():
    c, p = Coach(), lab_trigger()
    move = [{"skill": "gather", "item": "coal", "count": 50}]
    for i in range(6):
        c.guard(move, payload(p), None)
        c.observe(payload(p, [{"action": "skill:gather", "item": "coal", "count": 50, "ok": False,
                               "detail": "cancelled: combat"}], f"r{i}"))
    assert not c.blocked()


def test_prompt_tells_the_model_about_reflexes():
    from bridge.prompt import SYSTEM_PROMPT
    assert "REFLEXES" in SYSTEM_PROMPT and "cancelled: combat" in SYSTEM_PROMPT


def test_get_tile_target_computes_adjacent_snap():
    from bridge import blueprints
    bp = {
        "name": "tileable-smelter-stone",
        "tileable": True,
        "tile_offset": {"x": 0, "y": 6}
    }
    placed = [{"name": "tileable-smelter-stone", "position": {"x": 10, "y": 20}}]
    target = blueprints.get_tile_target(placed, bp)
    assert target == {"x": 10, "y": 26}


def test_planner_selects_modular_smelter_when_unlocked():
    p = labbed()
    p["power"] = {"has_grid": True}
    p["production"]["items"]["iron-plate"] = {"per_min": 10}
    p["blueprint_library"] = ["tileable-smelter-stone"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-smelter-stone"} in moves


def test_planner_tiles_modular_smelter_when_plate_deficit():
    p = labbed()
    p["power"] = {"has_grid": True}
    p["production"]["items"]["iron-plate"] = {"per_min": 10}
    p["blueprint_library"] = ["tileable-smelter-stone"]
    p["placed_blueprints"] = [{"name": "tileable-smelter-stone", "position": {"x": 5, "y": 10}}]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-smelter-stone", "position": {"x": 5, "y": 16}} in moves


def test_planner_selects_modular_red_science_when_unlocked():
    p = labbed()
    p["research"]["done"] = ["automation"]
    p["production"]["items"].update({"iron-plate": {"per_min": 35}, "copper-plate": {"per_min": 20},
                                     "automation-science-pack": {"per_min": 0}})
    p["blueprint_library"] = ["tileable-science-red"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-science-red"} in moves


def test_planner_tiles_modular_red_science_when_output_low():
    p = labbed()
    p["research"]["done"] = ["automation"]
    p["production"]["items"].update({"iron-plate": {"per_min": 35}, "copper-plate": {"per_min": 20},
                                     "automation-science-pack": {"per_min": 2}})
    p["blueprint_library"] = ["tileable-science-red"]
    p["placed_blueprints"] = [{"name": "tileable-science-red", "position": {"x": 2, "y": 4}}]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-science-red", "position": {"x": 2, "y": 10}} in moves


def test_planner_selects_modular_green_science_when_unlocked():
    p = green_ready()
    p["blueprint_library"] = ["tileable-science-green"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-science-green"} in moves


def test_next_plan_suppresses_redundant_pack_insert_after_tend():
    p = labbed()
    p["research"]["current"] = "automation"
    p["factory"]["labs"] = {"count": 1, "without_packs": 1}
    p["factory"]["machines"] = [{"type": "lab", "position": {"x": 1, "y": 1}}]
    p["needs"]["burners_low_fuel"] = 2
    p["inventory"] = [{"name": "coal", "count": 10}, {"name": "automation-science-pack", "count": 5}]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    # tend runs, so manual insert of science packs must be filtered
    assert any(e.get("skill") == "tend" for e in moves)
    assert not any(e.get("action") == "insert" and e.get("item") == "automation-science-pack" for e in moves)


def test_planner_selects_modular_labs_when_unlocked():
    p = labbed()
    p["power"] = {"has_grid": True}
    p["factory"]["labs"] = {"count": 0, "without_packs": 0}
    p["factory"]["machines"] = []
    p["blueprint_library"] = ["tileable-labs", "tileable-science-red"]
    p["research"]["done"] = ["automation"]
    p["production"]["items"].update({"iron-plate": {"per_min": 35}, "copper-plate": {"per_min": 20}})
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-labs"} in moves


def test_planner_connects_belt_between_red_science_and_labs():
    p = labbed()
    p["power"] = {"has_grid": True}
    p["research"]["done"] = ["automation"]
    p["production"]["items"].update({"iron-plate": {"per_min": 35}, "copper-plate": {"per_min": 20},
                                     "automation-science-pack": {"per_min": 0}})
    p["blueprint_library"] = ["tileable-science-red", "tileable-labs"]
    p["placed_blueprints"] = [
        {"name": "tileable-science-red", "position": {"x": 10, "y": 0}},
        {"name": "tileable-labs", "position": {"x": 30, "y": 0}}
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 16.0, "y": 0.5}, "to": {"x": 30.5, "y": 0.5}} in moves


def test_planner_connects_belt_between_smelter_and_red_science():
    p = labbed()
    p["power"] = {"has_grid": True}
    p["research"]["done"] = ["automation"]
    p["production"]["items"].update({"iron-plate": {"per_min": 35}, "copper-plate": {"per_min": 20},
                                     "automation-science-pack": {"per_min": 0}})
    p["blueprint_library"] = ["tileable-smelter-stone", "tileable-science-red"]
    p["placed_blueprints"] = [
        {"name": "tileable-smelter-stone", "position": {"x": 0, "y": 0}},
        {"name": "tileable-science-red", "position": {"x": 10, "y": 10}}
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 5.0, "y": 0.5}, "to": {"x": 10.5, "y": 15.5}} in moves


def test_military_escalation_crafts_red_ammo_when_researched():
    p = labbed()
    p["threat"] = {"attack": {"name": "boiler", "count": 1, "position": {"x": 0, "y": 0}}}
    p["research"]["done"] = ["gun-turret", "military-2"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    ammo_crafts = [e for e in moves if e.get("skill") == "craft_for" and "magazine" in e.get("item", "")]
    assert any(e.get("item") == "piercing-rounds-magazine" for e in ammo_crafts)


def test_planner_connects_belt_between_smelter_and_green_science():
    p = green_ready()
    p["blueprint_library"] = ["tileable-smelter-stone", "tileable-science-green"]
    p["placed_blueprints"] = [
        {"name": "tileable-smelter-stone", "position": {"x": 0, "y": 0}},
        {"name": "tileable-science-green", "position": {"x": 10, "y": 10}}
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 5.0, "y": 0.5}, "to": {"x": 10.5, "y": 15.5}} in moves


def test_planner_sideloads_green_science_into_labs():
    p = green_ready()
    p["blueprint_library"] = ["tileable-science-green", "tileable-labs"]
    p["placed_blueprints"] = [
        {"name": "tileable-science-green", "position": {"x": 10, "y": 0}},
        {"name": "tileable-labs", "position": {"x": 30, "y": 0}}
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 16.0, "y": 0.5}, "to": {"x": 31.5, "y": 0.5}} in moves


def test_planner_selects_and_connects_modular_steel_smelter():
    p = green_ready()
    # Fulfill green milestone so goal ladder advances to steel
    p["production"]["items"]["logistic-science-pack"] = {"per_min": 5}
    p["research"]["done"].append("steel-processing")
    p["blueprint_library"] = ["tileable-smelter-stone", "tileable-steel"]
    p["placed_blueprints"] = [
        {"name": "tileable-smelter-stone", "position": {"x": 0, "y": 0}}
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-steel"} in moves


def test_planner_selects_radar_when_oil_undiscovered():
    p = green_ready()
    p["production"]["items"].update({"logistic-science-pack": {"per_min": 5}, "steel-plate": {"per_min": 2}})
    p["research"]["done"].extend(["steel-processing", "oil-processing"])
    p["landmarks"]["resources"] = []
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "build_radar"} in moves


def test_planner_selects_pumpjack_and_refinery_when_oil_known():
    p = green_ready()
    p["production"]["items"].update({"logistic-science-pack": {"per_min": 5}, "steel-plate": {"per_min": 2}})
    p["research"]["done"].extend(["steel-processing", "oil-processing"])
    p["landmarks"]["resources"] = [{"name": "crude-oil", "x": 20, "y": 30, "distance": 36}]
    p["blueprint_library"] = ["tileable-oil-basic"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "build_pumpjack"} in moves
    assert {"skill": "place_blueprint", "name": "tileable-oil-basic"} in moves


def test_planner_connects_pipe_from_crude_to_refinery():
    p = green_ready()
    p["production"]["items"].update({"logistic-science-pack": {"per_min": 5}, "steel-plate": {"per_min": 2}})
    p["research"]["done"].extend(["steel-processing", "oil-processing"])
    p["landmarks"]["resources"] = [{"name": "crude-oil", "x": 20, "y": 30, "distance": 36}]
    p["factory"]["machines"] = [{"type": "pumpjack", "position": {"x": 20, "y": 30}}]
    p["blueprint_library"] = ["tileable-oil-basic"]
    p["placed_blueprints"] = [{"name": "tileable-oil-basic", "position": {"x": 10, "y": 10}}]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_pipe", "from": {"x": 20, "y": 30}, "to": {"x": 12.0, "y": 10}} in moves


def test_planner_selects_plastic_and_connects_petroleum():
    p = green_ready()
    p["power"] = {"has_grid": True}
    p["production"]["items"].update({"logistic-science-pack": {"per_min": 5}, "steel-plate": {"per_min": 2}})
    # Satisfy oil milestone: 1 pumpjack and 1 refinery
    p["factory"].setdefault("by_type", {})
    p["factory"]["by_type"].update({"pumpjack": 1, "oil-refinery": 1, "boiler": 1})
    p["research"]["done"].extend(["steel-processing", "oil-processing", "plastics", "sulfur-processing"])
    p["blueprint_library"] = ["tileable-plastic", "tileable-sulfur"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-plastic"} in moves






def test_planner_scales_modular_power_when_load_approaches_capacity():
    p = labbed()
    p["power"] = {"has_grid": True, "production_kw": 900, "consumption_kw": 800}
    p["factory"]["machines"] = [{"type": "boiler", "name": "boiler", "position": {"x": 10, "y": 10}}]
    p["blueprint_library"] = ["tileable-steam-power"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-steam-power"} in moves


def test_planner_connects_coal_belt_to_modular_steam_power():
    p = labbed()
    p["power"] = {"has_grid": True, "production_kw": 900, "consumption_kw": 300}
    p["factory"]["machines"] = [{"type": "boiler", "name": "boiler", "position": {"x": 10, "y": 10}}]
    p["blueprint_library"] = ["tileable-steam-power"]
    p["placed_blueprints"] = [{"name": "tileable-steam-power", "position": {"x": 20, "y": 30}}]
    p["landmarks"] = {"resources": [{"name": "coal", "x": 5, "y": 15, "distance": 20}]}
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 5, "y": 15}, "to": {"x": 20.5, "y": 30.5}} in moves


def test_planner_builds_offshore_pump_and_pipes_to_steam_power():
    p = labbed()
    p['power'] = {'has_grid': True, 'production_kw': 900, 'consumption_kw': 300}
    p['factory']['machines'] = [{'type': 'boiler', 'name': 'boiler', 'position': {'x': 10, 'y': 10}}]
    p['blueprint_library'] = ['tileable-steam-power']
    p['placed_blueprints'] = [{'name': 'tileable-steam-power', 'position': {'x': 20, 'y': 30}}]
    p['landmarks'] = {'water': {'x': 8, 'y': 12, 'distance': 15}}
    moves = [e for e, _ in planner.next_steps(p, limit=5)]
    assert {'skill': 'build_offshore_pump'} in moves
    assert {'skill': 'connect_pipe', 'from': {'x': 8, 'y': 12}, 'to': {'x': 20.5, 'y': 33.0}} in moves


def test_planner_connects_water_pipe_to_unwatered_boiler():
    p = labbed()
    p['power'] = {'has_grid': True, 'production_kw': 900, 'consumption_kw': 300}
    p['factory']['machines'] = [
        {'type': 'boiler', 'name': 'boiler', 'position': {'x': 10, 'y': 10}, 'status': 'no_input_fluid'},
        {'type': 'offshore-pump', 'name': 'offshore-pump', 'position': {'x': 2, 'y': 10}},
    ]
    p['factory']['by_type']['offshore-pump'] = 1
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {'skill': 'connect_pipe', 'from': {'x': 2, 'y': 10}, 'to': {'x': 9.0, 'y': 10}} in moves


def test_planner_selects_and_connects_modular_engine_plant():
    p = green_ready()
    p["power"] = {"has_grid": True}
    p["production"]["items"].update({
        "logistic-science-pack": {"per_min": 5},
        "steel-plate": {"per_min": 2},
        "plastic-bar": {"per_min": 10},
        "sulfur": {"per_min": 5},
    })
    p["factory"].setdefault("by_type", {})
    p["factory"]["by_type"].update({"pumpjack": 1, "oil-refinery": 1, "boiler": 1})
    p["research"]["done"].extend(["steel-processing", "oil-processing", "plastics", "sulfur-processing", "engine"])
    p["blueprint_library"] = ["tileable-engine"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-engine"} in moves

    p["placed_blueprints"] = [
        {"name": "tileable-steel", "position": {"x": 10, "y": 20}},
        {"name": "tileable-engine", "position": {"x": 25, "y": 20}},
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 15.0, "y": 20.5}, "to": {"x": 25.5, "y": 20.5}} in moves


def test_planner_selects_and_connects_modular_red_circuits():
    p = green_ready()
    p["power"] = {"has_grid": True}
    p["production"]["items"].update({
        "logistic-science-pack": {"per_min": 5},
        "steel-plate": {"per_min": 2},
        "plastic-bar": {"per_min": 10},
        "sulfur": {"per_min": 5},
        "engine-unit": {"per_min": 5},
    })
    p["factory"].setdefault("by_type", {})
    p["factory"]["by_type"].update({"pumpjack": 1, "oil-refinery": 1, "boiler": 1})
    p["research"]["done"].extend(["steel-processing", "oil-processing", "plastics", "sulfur-processing", "engine", "advanced-circuit"])
    p["blueprint_library"] = ["tileable-red-circuits"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-red-circuits"} in moves

    p["placed_blueprints"] = [
        {"name": "tileable-plastic", "position": {"x": 10, "y": 20}},
        {"name": "tileable-red-circuits", "position": {"x": 25, "y": 20}},
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 17.5, "y": 20.5}, "to": {"x": 25.5, "y": 20.5}} in moves


def test_planner_selects_and_connects_modular_blue_science():
    p = green_ready()
    p["power"] = {"has_grid": True}
    p["production"]["items"].update({
        "logistic-science-pack": {"per_min": 5},
        "steel-plate": {"per_min": 2},
        "plastic-bar": {"per_min": 10},
        "sulfur": {"per_min": 5},
        "engine-unit": {"per_min": 5},
        "advanced-circuit": {"per_min": 5},
    })
    p["factory"].setdefault("by_type", {})
    p["factory"]["by_type"].update({"pumpjack": 1, "oil-refinery": 1, "boiler": 1})
    p["research"]["done"].extend(["steel-processing", "oil-processing", "plastics", "sulfur-processing", "engine", "advanced-circuit", "chemical-science-pack"])
    p["blueprint_library"] = ["tileable-science-blue"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-science-blue"} in moves

    p["placed_blueprints"] = [
        {"name": "tileable-engine", "position": {"x": 10, "y": 20}},
        {"name": "tileable-labs", "position": {"x": 40, "y": 20}},
        {"name": "tileable-science-blue", "position": {"x": 25, "y": 20}},
    ]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "connect_belt", "from": {"x": 20.5, "y": 20.5}, "to": {"x": 25.5, "y": 20.5}} in moves
    assert {"skill": "connect_belt", "from": {"x": 31.0, "y": 25.5}, "to": {"x": 40.5, "y": 20.5}} in moves


def test_planner_selects_and_crafts_construction_robotics():
    p = green_ready()
    p["power"] = {"has_grid": True}
    p["production"]["items"].update({
        "logistic-science-pack": {"per_min": 5},
        "steel-plate": {"per_min": 2},
        "plastic-bar": {"per_min": 10},
        "sulfur": {"per_min": 5},
        "engine-unit": {"per_min": 5},
        "advanced-circuit": {"per_min": 5},
        "chemical-science-pack": {"per_min": 5},
    })
    p["factory"].setdefault("by_type", {})
    p["factory"]["by_type"].update({"pumpjack": 1, "oil-refinery": 1, "boiler": 1})
    p["research"]["done"].extend(["steel-processing", "oil-processing", "plastics", "sulfur-processing", "engine", "advanced-circuit", "chemical-science-pack", "robotics", "construction-robotics"])
    p["blueprint_library"] = ["tileable-robotics"]
    moves = [e for e, _ in planner.next_steps(p, limit=4)]
    assert {"skill": "place_blueprint", "name": "tileable-robotics"} in moves
    assert {"skill": "craft_for", "item": "flying-robot-frame", "count": 5} in moves


def test_burner_phaseout_when_electric_available():
    # When electric-mining-drill is researched and power grid exists,
    # the planner must never yield burner-mining-drill even with 0 miners
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 0}, "copper-plate": {"per_min": 0}}
    p["factory"]["miners_by_resource"] = {}
    p["inventory"] = []
    all_moves = moves(p, limit=16)
    for m in all_moves:
        assert m.get("item") != "burner-mining-drill"
        assert m.get("recipe") != "burner-mining-drill"
        if m.get("skill") == "build_miner":
            assert m.get("drill") != "burner"


def test_post_red_science_electric_drill_expansion():
    # In green science era, electric drills must scale up to targets
    p = green_ready()
    p["power"] = {"has_grid": True}
    p["research"]["done"].append("electric-mining-drill")
    p["factory"]["electric_miners"] = {"iron-ore": 2, "copper-ore": 1, "coal": 1, "stone": 0}
    plan = list(planner.next_plan(p, limit=8))
    drill_moves = [e for e, _, _ in plan if e.get("skill") == "build_miner" and e.get("drill") == "electric"]
    assert len(drill_moves) > 0
    assert drill_moves[0]["resource"] == "iron-ore"


def test_prompt_strips_heavy_perception_fields():
    from bridge.prompt import build_messages
    perception = {
        "game_phase": 1,
        "factory": {
            "total": 35,
            "summary": {"working": 30},
            "attention": [],
            "machines": [{"name": f"machine_{i}", "position": {"x": i, "y": i}} for i in range(100)],
        },
        "connected_belts": [{"from": {"x": 1, "y": 2}, "to": {"x": 3, "y": 4}}],
        "connected_pipes": [{"from": {"x": 10, "y": 20}, "to": {"x": 30, "y": 40}}],
    }
    msgs = build_messages({"perception": perception})
    user_content = msgs[1]["content"]
    assert "machine_99" not in user_content
    assert "connected_belts" not in user_content
    assert "connected_pipes" not in user_content


def test_demand_targets_scaling():
    # need x1.5 headroom + a flat buffer (iron 30, copper 15) that is NOT scaled
    from bridge import goals
    assert planner.demand_targets is goals.demand_targets          # one shared copy
    p = spawn()
    t0 = planner.demand_targets(p)
    assert t0["iron-ore"] == ("iron-plate", 30.0)
    assert t0["copper-ore"] == ("copper-plate", 15.0)

    p["research"]["done"] = ["automation"]                         # red 5/min: iron 10, copper 5
    t1 = planner.demand_targets(p)
    assert t1["iron-ore"] == ("iron-plate", 45.0)
    assert t1["copper-ore"] == ("copper-plate", 22.5)

    p["research"]["done"] += ["logistic-science-pack"]             # green 5/min: iron 27.5, copper 7.5
    t2 = planner.demand_targets(p)
    assert t2["iron-ore"] == ("iron-plate", pytest.approx(86.2, abs=0.1))
    assert t2["copper-ore"] == ("copper-plate", pytest.approx(33.8, abs=0.1))

    p["research"]["done"] += ["steel-processing"]                  # steel: iron 25
    t3 = planner.demand_targets(p)
    assert t3["iron-ore"] == ("iron-plate", pytest.approx(123.8, abs=0.1))
    assert t3["copper-ore"] == ("copper-plate", pytest.approx(33.8, abs=0.1))


# --- Round 16 Part 2: Model doesn't do coordinate layout ---

def test_schema_llm_layout_disabled():
    from bridge.schema import action_schema
    s_no = action_schema(blueprint_names=["tileable-smelter-stone"], llm_layout=False)
    variants_no = s_no["items"]["anyOf"]
    skills_no = {v["properties"]["skill"]["const"] for v in variants_no if "skill" in v["properties"]}
    actions_no = {v["properties"]["action"]["const"] for v in variants_no if "action" in v["properties"]}
    for bad in ("place_blueprint", "connect_belt", "connect_pipe", "connect_ports"):
        assert bad not in skills_no
    assert "place" not in actions_no

    s_yes = action_schema(blueprint_names=["tileable-smelter-stone"], llm_layout=True)
    variants_yes = s_yes["items"]["anyOf"]
    skills_yes = {v["properties"]["skill"]["const"] for v in variants_yes if "skill" in v["properties"]}
    actions_yes = {v["properties"]["action"]["const"] for v in variants_yes if "action" in v["properties"]}
    for good in ("place_blueprint", "connect_belt", "connect_pipe", "connect_ports"):
        assert good in skills_yes
    assert "place" in actions_yes


def test_coach_guard_drops_llm_layout():
    c = Coach()
    p = spawn()
    # Model entries with layout moves
    entries = [
        {"skill": "connect_belt", "from": {"x": 1, "y": 2}, "to": {"x": 3, "y": 4}},
        {"action": "place", "item": "lab", "position": {"x": 0, "y": 0}},
        {"skill": "gather", "item": "wood", "count": 20},
    ]
    out, _ = c.guard(entries, payload(p), None, llm_layout=False)
    assert len(out) == 1
    assert out[0] == {"skill": "gather", "item": "wood", "count": 20}
    assert c.rewrites["drop_llm_layout"] == 2

    # Autopilot moves are unaffected
    auto_entries = [
        {"source": "autopilot", "skill": "connect_belt", "from": {"x": 1, "y": 2}, "to": {"x": 3, "y": 4}},
    ]
    out_auto, _ = c.guard(auto_entries, payload(p), None, llm_layout=False)
    assert len(out_auto) == 1
    assert out_auto[0]["skill"] == "connect_belt"


def test_prompt_omits_layout_when_disabled():
    from bridge.prompt import get_system_prompt
    prompt_no = get_system_prompt(llm_layout=False)
    assert "connect_belt" not in prompt_no
    assert "connect_pipe" not in prompt_no
    assert "place_blueprint" not in prompt_no
    assert "place{" not in prompt_no

    prompt_yes = get_system_prompt(llm_layout=True)
    assert "connect_belt" in prompt_yes
    assert "connect_pipe" in prompt_yes
    assert "place_blueprint" in prompt_yes
    assert "place{" in prompt_yes


def test_load_library_excludes_local_by_default(tmp_path, monkeypatch):
    import json
    import bridge.blueprints as bp_mod
    local_dir = tmp_path / "local"
    local_dir.mkdir()
    fake_local = {"name": "test-custom-bp", "string": "0eNp...", "entities": 5}
    (local_dir / "test-custom-bp.json").write_text(json.dumps(fake_local), encoding="utf-8")

    monkeypatch.setattr(bp_mod, "LOCAL_DIR", local_dir)

    # Default (include_local=False) should NOT include it
    lib_default = bp_mod.load_library()
    assert "test-custom-bp" not in lib_default

    # Explicit include_local=True includes it
    lib_all = bp_mod.load_library(include_local=True)
    assert "test-custom-bp" in lib_all
    assert lib_all["test-custom-bp"]["source"] == "local"



