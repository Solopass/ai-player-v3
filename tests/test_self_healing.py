"""Unit tests for Round 18: Closed-Loop Self-Healing & Factory Auditing."""

from bridge import planner
from tests.test_coach_planner import post_bootstrap, powered


def test_unpowered_machine_triggers_connect_power():
    p = powered(post_bootstrap())
    p["power"]["has_grid"] = True
    p["power"]["unpowered_positions"] = [{"x": 35.5, "y": 45.5}]
    p["inventory"] = [{"name": "small-electric-pole", "count": 10}, {"name": "coal", "count": 50}]

    plan = planner.next_plan(p, limit=4)
    moves = [e for e, _, _ in plan]

    assert any(
        e.get("skill") == "connect_power"
        and e.get("to") == {"x": 35.5, "y": 45.5}
        for e in moves
    )


def test_flow_faults_trigger_fix_flow():
    p = powered(post_bootstrap())
    p["factory"]["flow_faults"] = [{"kind": "dead_end", "detail": "belt ends with no consumer"}]
    p["inventory"] = [{"name": "coal", "count": 50}]

    plan = planner.next_plan(p, limit=4)
    moves = [e for e, _, _ in plan]

    assert any(e.get("skill") == "fix_flow" for e in moves)


def test_depleted_miner_triggers_deconstruction():
    p = powered(post_bootstrap())
    p["factory"]["depleted_miners"] = [{"x": 15, "y": -20}]
    p["inventory"] = [{"name": "coal", "count": 50}]

    plan = planner.next_plan(p, limit=4)
    moves = [e for e, _, _ in plan]

    assert any(
        e.get("skill") == "deconstruct"
        and e.get("position") == {"x": 15, "y": -20}
        for e in moves
    )
