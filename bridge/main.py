"""
Factorio AI Player Bridge — entry point.

Wires together: ConfigLoader → RCONGateway → FileWatcher → Agent.

Run from the ai-player-v2 root:
    python -m bridge.main

Startup sequence:
  1. Configure logging
  2. Load config (bridge/.env → defaults)
  3. Connect RCON, clear stale pending requests
  4. Enter poll loop:
       - hot-reload config.json on each iteration
       - reconnect RCON if credentials changed
       - hand new requests to Agent, send responses via RCON
"""

import json
import logging
import sys
import time
from pathlib import Path

from . import blueprints, diag
from .agent import Agent, _fallback
from .config import ConfigLoader
from .factorio.rcon import RCONGateway
from .factorio.watcher import FileWatcher

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _setup_logging(verbose: bool, log_dir: Path) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    fmt = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    datefmt = "%H:%M:%S"

    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]

    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_dir / "bridge.log", encoding="utf-8")
        file_handler.setFormatter(logging.Formatter(fmt, datefmt))
        handlers.append(file_handler)
    except OSError as e:
        print(f"[bridge] Warning: could not open log file in {log_dir}: {e}")

    logging.basicConfig(level=level, format=fmt, datefmt=datefmt, handlers=handlers)

    # Quiet the OpenAI and httpx loggers — they're very chatty at DEBUG
    for noisy in ("httpx", "httpcore", "openai._base_client"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    # Phase 1: load config from bridge/.env
    loader = ConfigLoader()
    cfg = loader.get()

    _setup_logging(cfg.verbose, cfg.output_dir)
    log = logging.getLogger("bridge.main")

    log.info("=" * 60)
    log.info("Factorio AI Player Bridge")
    log.info("=" * 60)
    log.info("Output dir : %s", cfg.output_dir)
    log.info("Provider   : %s", cfg.provider)
    log.info("Model      : %s", cfg.model)
    log.info("RCON       : %s:%d", cfg.rcon.host, cfg.rcon.port)
    log.info("=" * 60)

    if not cfg.output_dir.exists():
        log.warning(
            "Output dir does not exist: %s\n"
            "  → Is Factorio running? Is FACTORIO_OUTPUT_DIR set correctly in bridge/.env?",
            cfg.output_dir,
        )

    # Phase 2: connect RCON
    rcon = RCONGateway(cfg.rcon.host, cfg.rcon.port, cfg.rcon.password)
    if not rcon.connect():
        log.warning(
            "RCON connection failed — bridge will keep trying each loop iteration.\n"
            "  → Is Factorio running? Is RCON enabled on port %d?",
            cfg.rcon.port,
        )

    # Timeouts derive from the single source (cfg.timeout = AI_TIMEOUT). The mod
    # and watcher must allow at least as long as the model is given to reply, plus
    # margin for RCON round-trip and prompt assembly.
    TIMEOUT_MARGIN = 60.0
    derived_timeout = cfg.timeout + TIMEOUT_MARGIN

    # Phase 4: create watcher and agent
    watcher = FileWatcher(cfg.output_dir, cfg.poll_interval, request_timeout=derived_timeout)
    agent = Agent()

    # Phase 3: clear stale pending requests left over from a previous session.
    # Order matters: clear the mod's queue first, then purge the matching
    # request files on disk so we don't reply to IDs the mod no longer tracks. (A2)
    if rcon.connected:
        log.info("Clearing stale pending requests from previous session...")
        rcon.clear_pending_requests()
        watcher.purge_all()
        # Push the derived request timeout to the mod (single source = AI_TIMEOUT).
        rcon.set_request_timeout(derived_timeout)

    log.info("Bridge running. Waiting for requests... (Ctrl+C to stop)")

    # Blueprint library: import what the player exported in game (/ai-bp add),
    # then push anything new/changed to the mod. Hash-compared, so a sync with
    # nothing to do is one RCON call.
    BP_SYNC_EVERY = 10.0
    last_bp_sync = 0.0

    def sync_blueprints():
        diag.rotate_logs(cfg.output_dir)
        try:
            added = blueprints.ingest_from_game(cfg.output_dir)
            if added:
                log.info("Imported %d blueprint(s) from the game: %s", len(added), ", ".join(added))
            if rcon.connected:
                pushed, removed = blueprints.sync_to_mod(rcon, blueprints.load_library())
                if pushed or removed:
                    log.info("Blueprint library synced to the mod: %d pushed, %d removed", pushed, removed)
        except Exception as e:      # never let a library problem stop the AI
            log.warning("Blueprint sync failed: %s", e)

    # ---------------------------------------------------------------------------
    # Main loop
    # ---------------------------------------------------------------------------
    try:
        while True:
            # Hot-reload config.json written by Factorio on settings change
            cfg = loader.get()

            if time.monotonic() - last_bp_sync >= BP_SYNC_EVERY:
                last_bp_sync = time.monotonic()
                sync_blueprints()

            # Reconnect RCON if host/port/password changed in-game
            if loader.rcon_changed(cfg):
                log.info("RCON settings changed — reconnecting...")
                rcon.reconnect((cfg.rcon.host, cfg.rcon.port, cfg.rcon.password))

            # Process any new request files
            try:
                ready = watcher.poll()
            except Exception:
                log.exception("Reading request files failed — retrying next poll")
                ready = []
            for req in ready:
                log.info("Processing request %s", req.req_id)

                # One bad request must never stop the bridge: answer it with a
                # safe "wait" so the mod doesn't sit on it, and move on.
                try:
                    actions = agent.decide(req, cfg)
                except Exception as e:
                    log.exception("Request %s crashed the agent — sending a wait", req.req_id)
                    actions = _fallback(f"bridge error: {type(e).__name__}: {e}"[:200])

                sent = rcon.send_ai_response(req.req_id, actions)
                status = getattr(agent, "status", None)
                if sent and status:
                    rcon.query_lua("remote.call('ai_player','set_status',"
                                   f"{blueprints._lua_str(json.dumps(status))})")
                if sent:
                    watcher.ack(req.req_id)
                else:
                    # RCON send failed — return request to pool, retry next poll
                    log.warning(
                        "RCON send failed for request %s — will retry next poll",
                        req.req_id,
                    )
                    watcher.nack(req.req_id)

            time.sleep(cfg.poll_interval)

    except KeyboardInterrupt:
        log.info("Shutting down.")
        sys.exit(0)


if __name__ == "__main__":
    main()
