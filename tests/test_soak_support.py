"""Soak-test support: the stub provider and the BRIDGE_ENV_FILE override."""

from bridge.config import ConfigLoader
from bridge.factorio.api import parse_response
from bridge.providers import ProviderConfig, get_provider


def test_stub_provider_waits_in_parser_format():
    cfg = ProviderConfig(provider="stub")
    reply = get_provider(cfg)([{"role": "user", "content": "x"}], cfg)
    assert parse_response(reply) == [{"action": "wait"}]


def test_stub_provider_follows_the_suggested_moves():
    from bridge.coach import Coach
    steps = [({"skill": "tend"}, "why one"), ({"skill": "gather", "item": "coal", "count": 50}, "why two")]
    prompt = "STATE... " + Coach().prompt_text(steps)
    cfg = ProviderConfig(provider="stub")
    reply = get_provider(cfg)([{"role": "system", "content": "s"}, {"role": "user", "content": prompt}], cfg)
    assert parse_response(reply) == [e for e, _ in steps]


def test_env_file_override(tmp_path, monkeypatch):
    env = tmp_path / "soak.env"
    env.write_text("AI_PROVIDER=stub\nFACTORIO_RCON_PORT=4242\nFACTORIO_RCON_PASSWORD=pw\n"
                   f"FACTORIO_OUTPUT_DIR={tmp_path}\n")
    monkeypatch.setenv("BRIDGE_ENV_FILE", str(env))
    cfg = ConfigLoader().get()
    assert cfg.provider == "stub" and cfg.rcon.port == 4242 and cfg.rcon.password == "pw"
    assert cfg.output_dir == tmp_path


def test_mod_config_cannot_override_env_file_rcon(tmp_path, monkeypatch):
    env = tmp_path / "soak.env"
    env.write_text(f"AI_PROVIDER=stub\nFACTORIO_RCON_HOST=127.0.0.1\nFACTORIO_RCON_PORT=4242\n"
                   f"FACTORIO_RCON_PASSWORD=pw\nFACTORIO_OUTPUT_DIR={tmp_path}\n")
    (tmp_path / "config.json").write_text('{"provider":"openai","rcon_port":27015,"rcon_password":"","rcon_host":"x"}')
    monkeypatch.setenv("BRIDGE_ENV_FILE", str(env))
    cfg = ConfigLoader().get()
    assert (cfg.provider, cfg.rcon.host, cfg.rcon.port, cfg.rcon.password) == ("stub", "127.0.0.1", 4242, "pw")


def _soak():
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent / "ingame"))
    import run_soak
    return run_soak


def _sample(minute, **kw):
    s = {"minute": minute, "techs": 3, "research_current": "logistics", "unfuelled": 0, "kills": 5,
         "magazines": 100, "reflex": {"state": "idle", "deaths": 0}, "lost": {}, "spawners_home": 2,
         "combat_mode": "defend"}
    s.update(kw)
    return s


def test_kill_summary_compares_before_and_after_the_kill():
    soak = _soak()
    samples = [_sample(19), _sample(21, kills=9, techs=4, reflex={"state": "fighting", "deaths": 0, "bridge_offline": True}),
               _sample(30, kills=20, techs=6, unfuelled=1, reflex={"state": "idle", "deaths": 1})]
    k = soak.kill_summary(samples, 20)
    assert (k["techs_at_kill"], k["techs_end"], k["kills_end"], k["unfuelled_max_after"]) == (3, 6, 20, 1)
    assert k["bridge_offline_seen"] and k["ai_deaths_after"] == 1
    assert k["reflex_states_after"] == ["fighting", "idle"]
    assert soak.kill_summary(samples, None) is None


def test_combat_summary_totals_losses_and_nests():
    soak = _soak()
    samples = [_sample(1), _sample(60, lost={"stone-furnace": 2, "lab": 1}, spawners_home=0,
                                   reflex={"state": "idle", "deaths": 1, "nests_cleared": 3})]
    c = soak.combat_summary(samples)
    assert c["entities_lost_total"] == 3 and c["ai_deaths"] == 1 and c["nests_cleared"] == 3
    assert (c["spawners_near_home_start"], c["spawners_near_home_end"]) == (2, 0)
