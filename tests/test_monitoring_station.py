"""Unit tests for Round 19: AI Monitoring Station & Spectator HUD."""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def test_station_prototypes_defined():
    data_lua = (REPO_ROOT / "mod" / "data.lua").read_text(encoding="utf-8")
    assert 'name = "ai-monitoring-station"' in data_lua
    assert 'type = "car"' in data_lua
    assert 'energy_source = {' in data_lua
    assert 'type = "void"' in data_lua
    assert 'recipe' in data_lua


def test_station_locale():
    locale_cfg = (REPO_ROOT / "mod" / "locale" / "en" / "locale.cfg").read_text(encoding="utf-8")
    assert "[entity-name]" in locale_cfg
    assert "ai-monitoring-station=AI Monitoring Station" in locale_cfg
    assert "[item-name]" in locale_cfg
    assert "ai-monitoring-station=AI Monitoring Station" in locale_cfg


def test_station_starting_items():
    char_lua = (REPO_ROOT / "mod" / "scripts" / "character.lua").read_text(encoding="utf-8")
    assert '{name = "ai-monitoring-station",count = 1}' in char_lua or '{name = "ai-monitoring-station", count = 1}' in char_lua


def test_station_gui_module():
    station_gui_path = REPO_ROOT / "mod" / "scripts" / "station_gui.lua"
    assert station_gui_path.exists()
    content = station_gui_path.read_text(encoding="utf-8")
    assert "StationGui = {}" in content
    assert "function StationGui.open" in content
    assert "function StationGui.close" in content
    assert "function StationGui.update" in content
    assert 'type = "camera"' in content
    assert "return StationGui" in content


def test_control_and_gui_wiring():
    control_lua = (REPO_ROOT / "mod" / "control.lua").read_text(encoding="utf-8")
    assert 'require("scripts.station_gui")' in control_lua
    assert "defines.events.on_player_driving_changed_state" in control_lua
    assert '"ai-station"' in control_lua

    gui_lua = (REPO_ROOT / "mod" / "scripts" / "gui.lua").read_text(encoding="utf-8")
    assert "StationGui.on_gui_click" in gui_lua
    assert "StationGui.is_open" in gui_lua
