import os
from bridge import buildbook, planner


def test_buildbook_toggle():
    p_off = {"buildbook_enabled": False}
    assert not buildbook.is_enabled(p_off)

    p_on = {"buildbook_enabled": True}
    assert buildbook.is_enabled(p_on)

    os.environ["AI_BUILDBOOK"] = "1"
    try:
        assert buildbook.is_enabled(p_off)
    finally:
        del os.environ["AI_BUILDBOOK"]


def test_buildbook_bootstrap_moves():
    p = {
        "buildbook_enabled": True,
        "factory": {"miners_by_resource": {}},
        "inventory": {"main": {"iron-plate": 20, "stone": 10}},
    }
    moves = list(buildbook.candidates(p))
    assert len(moves) > 0
    # First missing is coal burner drill
    assert moves[0][0]["skill"] == "craft_for"
    assert moves[0][0]["item"] == "burner-mining-drill"


def test_buildbook_power_step():
    p = {
        "buildbook_enabled": True,
        "factory": {
            "miners_by_resource": {"coal": 1, "iron-ore": 2, "copper-ore": 1, "stone": 1},
            "by_type": {},
        },
        "power": {"has_grid": False},
        "landmarks": {"water": {"x": 10, "y": 10, "distance": 15}},
    }
    moves = list(buildbook.candidates(p))
    assert len(moves) == 1
    assert moves[0][0]["skill"] == "build_power"


def test_buildbook_research_bootstrap_step():
    p = {
        "buildbook_enabled": True,
        "factory": {
            "miners_by_resource": {"coal": 1, "iron-ore": 2, "copper-ore": 1, "stone": 1},
            "by_type": {"boiler": 1, "generator": 2, "lab": 1},
        },
        "power": {"has_grid": True},
        "research": {"done": {}, "current": None},
        "inventory": {"main": {"automation-science-pack": 20}},
    }
    moves = list(buildbook.candidates(p))
    assert any(m[0].get("skill") == "research" and m[0].get("tech") == "automation" for m in moves)


def test_buildbook_fields_step():
    p = {
        "buildbook_enabled": True,
        "factory": {
            "miners_by_resource": {"coal": 1, "iron-ore": 2, "copper-ore": 1, "stone": 1},
            "by_type": {"boiler": 1, "generator": 2, "lab": 1},
        },
        "power": {"has_grid": True},
        "research": {"done": {"automation": True, "electric-mining-drill": True}},
        "fields": [],
    }
    moves = list(buildbook.candidates(p))
    assert len(moves) == 1
    assert moves[0][0]["skill"] == "build_miner"
    assert moves[0][0]["resource"] == "iron-ore"
    assert moves[0][0]["output"] == "field"
    assert moves[0][0]["plate_belt"] is True

    p["fields"].append({"resource": "iron-ore", "has_output": True})
    moves = list(buildbook.candidates(p))
    assert len(moves) == 1
    assert moves[0][0]["skill"] == "build_miner"
    assert moves[0][0]["resource"] == "copper-ore"
    assert moves[0][0]["output"] == "field"
    assert moves[0][0]["plate_belt"] is True


def test_buildbook_base_frame_steps():
    # 1. Base site needed
    p = {
        "buildbook_enabled": True,
        "factory": {
            "miners_by_resource": {"coal": 1, "stone": 1, "iron-ore": 4, "copper-ore": 3},
            "by_type": {"boiler": 1, "generator": 2, "lab": 1},
        },
        "power": {"has_grid": True},
        "research": {"done": {"automation": True, "electric-mining-drill": True}},
        "fields": [{"resource": "iron-ore", "has_output": True}, {"resource": "copper-ore", "has_output": True}],
        "base": None,
        "placed_stamps": [],
    }
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "build_base"

    # 2. Base established -> bus_head stamp needed
    p["base"] = {"origin": {"x": 0, "y": 0}, "dir": "east", "length": 60, "slots": {}}
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "bus_head"
    assert moves[0][0]["at_u"] == 0

    # 3. bus_head placed -> tap_inner at u=4
    p["placed_stamps"].append({"name": "bus_head", "at_u": 0})
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "tap_inner"
    assert moves[0][0]["at_u"] == 4

    # 4. tap_inner placed -> tap_outer at u=8
    p["placed_stamps"].append({"name": "tap_inner", "at_u": 4})
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "tap_outer"
    assert moves[0][0]["at_u"] == 8

    # 5. tap_outer placed -> bus_segment 1 at u=10
    p["placed_stamps"].append({"name": "tap_outer", "at_u": 8})
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "bus_segment"
    assert moves[0][0]["at_u"] == 10

    # 6. bus_segment 1 placed -> bus_segment 2 at u=24
    p["placed_stamps"].append({"name": "bus_segment", "at_u": 10})
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "bus_segment"
    assert moves[0][0]["at_u"] == 24


def test_buildbook_trunks_step():
    p = {
        "buildbook_enabled": True,
        "factory": {
            "miners_by_resource": {"coal": 1, "stone": 1, "iron-ore": 4, "copper-ore": 3},
            "by_type": {"boiler": 1, "generator": 2, "lab": 1},
        },
        "power": {"has_grid": True},
        "research": {"done": {"automation": True, "electric-mining-drill": True}},
        "fields": [{"resource": "iron-ore", "has_output": True}, {"resource": "copper-ore", "has_output": True}],
        "base": {"origin": {"x": 0, "y": 0}, "dir": "east", "length": 60, "slots": {}},
        "placed_stamps": [
            {"name": "bus_head", "at_u": 0},
            {"name": "tap_inner", "at_u": 4},
            {"name": "tap_outer", "at_u": 8},
            {"name": "bus_segment", "at_u": 10},
            {"name": "bus_segment", "at_u": 24},
        ],
        "base_links": [],
    }
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "connect_ports"
    assert moves[0][0]["from_bp"] == "field:iron-ore"
    assert moves[0][0]["from_port"] == "plate_output"
    assert moves[0][0]["to_port"] == "in_fe"

    p["base_links"].append("field:iron-ore:plate_output->base:in_fe")
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "connect_ports"
    assert moves[0][0]["from_bp"] == "field:copper-ore"
    assert moves[0][0]["from_port"] == "plate_output"
    assert moves[0][0]["to_port"] == "in_cu"


def test_buildbook_red_and_lab_step():
    p = {
        "buildbook_enabled": True,
        "factory": {
            "miners_by_resource": {"coal": 1, "stone": 1, "iron-ore": 4, "copper-ore": 3},
            "by_type": {"boiler": 1, "generator": 2, "lab": 1},
        },
        "power": {"has_grid": True},
        "research": {"done": {"automation": True, "electric-mining-drill": True}},
        "fields": [{"resource": "iron-ore", "has_output": True}, {"resource": "copper-ore", "has_output": True}],
        "base": {"origin": {"x": 0, "y": 0}, "dir": "east", "length": 60, "slots": {}},
        "placed_stamps": [
            {"name": "bus_head", "at_u": 0},
            {"name": "tap_inner", "at_u": 4},
            {"name": "tap_outer", "at_u": 8},
            {"name": "bus_segment", "at_u": 10},
            {"name": "bus_segment", "at_u": 24},
        ],
        "base_links": [
            "field:iron-ore:plate_output->base:in_fe",
            "field:copper-ore:plate_output->base:in_cu",
        ],
    }
    # 1. gear_red at u=9
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "gear_red"
    assert moves[0][0]["at_u"] == 9

    # 2. red_feed at u=6
    p["placed_stamps"].append({"name": "gear_red", "at_u": 9})
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "red_feed"
    assert moves[0][0]["at_u"] == 6

    # 3. lab_row at u=23
    p["placed_stamps"].append({"name": "red_feed", "at_u": 6})
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "place_stamp"
    assert moves[0][0]["stamp"] == "lab_row"
    assert moves[0][0]["at_u"] == 23

    # 4. connect science out to lab row
    p["placed_stamps"].append({"name": "lab_row", "at_u": 23})
    moves = list(buildbook.candidates(p))
    assert moves[0][0]["skill"] == "connect_ports"
    assert moves[0][0]["from_bp"] == "gear_red"
    assert moves[0][0]["to_bp"] == "lab_row"

    # 5. done once science feed is recorded
    p["base_links"].append("gear_red:out_science->lab_row:in_science")
    assert buildbook._step_red_and_lab_done(p) is True


def test_planner_candidates_delegates_to_buildbook():
    p = {
        "buildbook_enabled": True,
        "factory": {
            "miners_by_resource": {"coal": 1, "iron-ore": 2, "copper-ore": 1, "stone": 1},
            "by_type": {},
        },
        "power": {"has_grid": False},
        "landmarks": {"water": {"x": 10, "y": 10, "distance": 15}},
    }
    moves = list(planner._candidates(p))
    assert len(moves) == 1
    assert moves[0][0]["skill"] == "build_power"
