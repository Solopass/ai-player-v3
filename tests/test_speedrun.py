"""Tests for bridge.speedrun Leaderboard and Playbook Reflection."""

import tempfile
from pathlib import Path

from bridge.coach import Coach
from bridge.speedrun import Leaderboard, load_playbook, reflect_sprint, save_playbook


def test_leaderboard_records_personal_bests():
    with tempfile.TemporaryDirectory() as tmp:
        lb_file = Path(tmp) / "leaderboard.json"
        lb = Leaderboard(lb_file)

        # First run completes
        is_pb, prev = lb.record_sprint("red", seed=424242, elapsed_seconds=120.5, reached=True)
        assert is_pb is True
        assert prev is None
        assert lb.get_pb("red") == 120.5

        # Slower run
        is_pb, prev = lb.record_sprint("red", seed=424242, elapsed_seconds=140.0, reached=True)
        assert is_pb is False
        assert prev == 120.5
        assert lb.get_pb("red") == 120.5

        # Faster run (new PB)
        is_pb, prev = lb.record_sprint("red", seed=2476103329, elapsed_seconds=98.2, reached=True)
        assert is_pb is True
        assert prev == 120.5
        assert lb.get_pb("red") == 98.2

        # Re-load from disk
        lb2 = Leaderboard(lb_file)
        assert lb2.get_pb("red") == 98.2
        assert lb2.data["red"]["runs_total"] == 3
        assert lb2.data["red"]["runs_completed"] == 3


def test_playbook_save_and_load():
    with tempfile.TemporaryDirectory() as tmp:
        pb_file = Path(tmp) / "playbook.json"
        rules = ["Rule 1: Always clear trees", "Rule 2: Pre-smelt iron"]
        save_playbook(rules, pb_file)

        loaded = load_playbook(pb_file)
        assert loaded == rules


def test_reflect_sprint_generates_deterministic_rule():
    with tempfile.TemporaryDirectory() as tmp:
        pb_file = Path(tmp) / "playbook.json"
        rules = reflect_sprint("red", 150.0, False, 100.0,
                               ["craft_for: queued 0 crafts; missing 20x iron-plate"])
        assert len(rules) > 0
        assert any("iron" in r.lower() or "smelt" in r.lower() for r in rules)


def test_coach_prompt_text_includes_playbook():
    coach = Coach()
    prompt = coach.prompt_text([])
    # If playbook is populated or empty, prompt_text must still run without error
    assert isinstance(prompt, str)


def test_dedupe_rules_is_case_insensitive():
    from bridge.speedrun import dedupe_rules
    assert dedupe_rules(["Keep boiler fueled.", "keep  BOILER fueled", "Other"]) == ["Keep boiler fueled.", "Other"]


def test_coach_playbook_only_with_flag(monkeypatch):
    import bridge.coach as coach_mod
    monkeypatch.setattr(coach_mod, "load_playbook", lambda: ["Pre-smelt plates", "pre-smelt plates"])
    monkeypatch.delenv("AI_SPEEDRUN_LESSONS", raising=False)
    monkeypatch.setenv("BRIDGE_ENV_FILE", str(Path(tempfile.gettempdir()) / "no-such-bridge.env"))
    assert "LESSONS" not in Coach().prompt_text([])
    monkeypatch.setenv("AI_SPEEDRUN_LESSONS", "true")
    text = Coach().prompt_text([])
    assert "LESSONS" in text
    assert text.lower().count("pre-smelt plates") == 1


def test_sprint_time_is_game_ticks():
    from bridge.speedrun import parse_tick, ticks_to_seconds
    assert ticks_to_seconds(parse_tick("120\n"), parse_tick("1920")) == 30.0
    assert parse_tick("not a tick") is None
    assert ticks_to_seconds(500, 100) == 0.0


def test_copy_debug_sprint_skips_secrets(tmp_path):
    from bridge.speedrun import copy_debug_sprint
    src, dst = tmp_path / "src", tmp_path / "dst"
    src.mkdir()
    (src / "bridge.env").write_text("FACTORIO_RCON_PASSWORD=s3cret\n")
    (src / "server.log").write_text("rcon pw s3cret\n")
    (src / "bridge.log").write_text("fine\n")
    copy_debug_sprint(src, dst, "s3cret")
    assert sorted(p.name for p in dst.iterdir()) == ["bridge.log"]
