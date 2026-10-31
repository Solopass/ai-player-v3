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
