"""Unit tests for Round 17: Automated Coal Logistics and Belt Feeds."""

from bridge import planner
from tests.test_coach_planner import post_bootstrap, powered


def test_boiler_missing_fuel_belt_connects_coal_miner_to_boiler():
    p = powered(post_bootstrap())
    p["power"]["boiler_fuel_connected"] = False
    p["power"]["fuel_in_position"] = {"x": 20.5, "y": 25.5}
    p["factory"]["miner_positions"] = {
        "coal": [{"x": 40.5, "y": -10.5, "drop_position": {"x": 40.5, "y": -9.5}, "name": "burner-mining-drill"}]
    }
    p["inventory"] = [{"name": "transport-belt", "count": 100}]

    plan = planner.next_plan(p, limit=8)
    moves = [e for e, _, _ in plan]
    
    assert any(
        e.get("skill") == "connect_belt"
        and e.get("from") == {"x": 40.5, "y": -9.5}
        and e.get("to") == {"x": 20.5, "y": 25.5}
        for e in moves
    )


def test_smelter_stamped_connects_ore_and_coal_belts():
    p = powered(post_bootstrap(), ["automation", "electric-mining-drill"])
    p["production"]["items"] = {"iron-plate": {"per_min": 20}, "copper-plate": {"per_min": 10}}
    p["factory"]["electric_miners"] = {"iron-ore": 4, "copper-ore": 3}
    p["blueprint_library"] = ["tileable-smelter-stone"]
    p["placed_blueprints"] = [
        {
            "name": "tileable-smelter-stone",
            "position": {"x": 10.0, "y": 10.0},
            "ports": [
                {"name": "in1", "kind": "belt_in", "x": 10.5, "y": 10.5, "dir": 8},
                {"name": "in2", "kind": "belt_in", "x": 15.0, "y": 10.5, "dir": 8},
                {"name": "out2", "kind": "belt_out", "x": 15.0, "y": 15.5, "dir": 8},
            ]
        }
    ]
    p["factory"]["miner_positions"] = {
        "iron-ore": [{"x": 5.0, "y": -5.0, "drop_position": {"x": 5.0, "y": -4.0}, "name": "electric-mining-drill"}],
        "coal": [{"x": 25.0, "y": -5.0, "drop_position": {"x": 25.0, "y": -4.0}, "name": "electric-mining-drill"}],
    }
    p["inventory"] = [{"name": "coal", "count": 50}, {"name": "transport-belt", "count": 200}]

    plan = planner.next_plan(p, limit=8)
    moves = [e for e, _, _ in plan]

    connect_moves = [e for e in moves if e.get("skill") == "connect_belt"]
    assert any(e.get("from") == {"x": 5.0, "y": -4.0} and e.get("to") == {"x": 15.0, "y": 10.5} for e in connect_moves)
    assert any(e.get("from") == {"x": 25.0, "y": -4.0} and e.get("to") == {"x": 10.5, "y": 10.5} for e in connect_moves)


def test_boiler_with_connected_coal_belt_does_not_spam_tend_when_grid_is_up():
    p = powered(post_bootstrap())
    p["power"]["boiler_fuel_connected"] = True
    p["power"]["has_grid"] = True
    p["needs"]["burners_low_fuel"] = [{"name": "boiler", "position": {"x": 20, "y": 20}}]

    plan = planner.next_plan(p, limit=4)
    moves = [e for e, _, _ in plan]

    # tend should NOT be triggered for boiler fuel since belt is connected and grid is up
    assert not any(e.get("skill") == "tend" and "power needs attention" in why for e, why, _ in plan)
