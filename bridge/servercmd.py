"""Send console commands to the headless server over RCON.

    python -m bridge.servercmd "/server-save"
    python -m bridge.servercmd --stop        # save, then quit the server
    python -m bridge.servercmd --ping        # exit 0 if RCON answers

Uses the RCON settings from bridge/.env (same as the bridge).
"""

from __future__ import annotations

import sys
import time

from .config import ConfigLoader


def _client():
    from factorio_rcon import RCONClient

    rc = ConfigLoader().get().rcon
    return RCONClient(rc.host, rc.port, rc.password)


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    try:
        client = _client()
    except Exception as e:
        print(f"RCON not reachable: {e}")
        return 1

    if args[0] == "--ping":
        return 0
    if args[0] == "--stop":
        print(client.send_command("/server-save") or "saving...")
        time.sleep(3)  # /server-save returns before the file is written
        try:
            client.send_command("/quit")
        except Exception:
            pass  # the server drops the connection while quitting
        print("server stopping")
        return 0

    print(client.send_command(" ".join(args)) or "(no output)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
