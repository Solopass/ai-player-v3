"""
Stub provider: never calls a model. It plays an obedient one for the soak test's
--no-llm mode (AI_PROVIDER=stub): it sends back the prompt's SUGGESTED MOVES
(the planner's own next steps, see bridge/coach.py prompt_text), or waits when
there are none. The reply is in the format the parser expects (a JSON array),
so every decision comes from the autopilot or the planner.
"""

import json
import re

from . import ProviderConfig

WAIT = '[{"action":"wait"}]'
_SUGGESTED = re.compile(r"SUGGESTED MOVES[^:]*: (\[.*?\]) — ", re.S)


def complete(messages: list[dict], config: ProviderConfig) -> str | None:
    text = str(messages[-1].get("content", "")) if messages else ""
    m = _SUGGESTED.search(text)
    if m:
        try:
            moves = json.loads(m.group(1))
            if isinstance(moves, list) and moves:
                return json.dumps(moves)
        except ValueError:
            pass
    return WAIT
