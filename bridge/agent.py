"""
Router agent (v3).

Agent.decide() builds the small router prompt from raw perception, calls the
LLM, parses + validates the response into a list of skill/primitive entries,
and returns it. Skills are validated against api.SKILLS, primitives against
api.ACTIONS (see factorio/api.py). The coach (bridge/coach.py) keeps turn
memory across calls and replaces moves that keep failing with the planner's
next step (bridge/planner.py).
"""

import logging
import time
from dataclasses import replace

from . import blueprints, goals, planner
from .coach import Coach
from .config import BridgeConfig
from .factorio.api import parse_response
from .factorio.watcher import PendingRequest
from .metrics import STATUS_OK, STATUS_PARSE_ERROR, STATUS_TIMEOUT, record_exchange
from .prompt import build_messages
from .providers import get_provider
from .transcript import log_exchange

log = logging.getLogger(__name__)


def _fallback(reason: str) -> list[dict]:
    """Safe response so the mod never hangs; the summary states the real reason."""
    return [
        {"action": "wait"},
        {"action": "summary", "text": f"No action this turn — {reason}."},
    ]


class Agent:
    def __init__(self):
        self.coach = Coach()
        self.status = None

    def decide(self, req: PendingRequest, config: BridgeConfig) -> list[dict]:
        provider_cfg = config.to_provider_config()
        complete = get_provider(provider_cfg)

        payload = req.payload
        self.status = None      # set below once the model has been asked
        if "perception" not in payload:
            log.error("Request %s: no 'perception' in payload — fallback", req.req_id)
            return _fallback("internal error: request had no perception")

        perception = payload["perception"]
        # Blueprints for the planet the AI is on (planet builds are tagged by name).
        try:
            usable = blueprints.for_surface(blueprints.load_library(), perception)
        except Exception as e:
            log.warning("Blueprint library failed to load: %s", e)
            usable = {}
        goal_text = ""
        if config.goals:
            try:
                goal_text = goals.describe(perception, usable)
            except Exception as e:      # a goal bug must never stop the AI
                log.warning("Goal ladder failed: %s", e)
        # Coach/planner bugs must never stop the AI: on error, play without them.
        suggestion, coach_text = None, ""
        try:
            self.coach.observe(payload)
            suggestion = planner.next_step(perception, self.coach.blocked())
            coach_text = self.coach.prompt_text(suggestion)
        except Exception:
            log.exception("Coach/planner failed — continuing without them")
        messages = build_messages(payload, config.system_prefix, goal_text, coach_text)
        # place_blueprint may only name blueprints the mod holds and that fit
        # this planet.
        in_mod = set(perception.get("blueprint_library") or [])
        provider_cfg = replace(provider_cfg, blueprint_names=sorted(in_mod & set(usable)))

        log.info("Routing request %s via %s (model=%s)",
                 req.req_id, provider_cfg.provider, provider_cfg.model)
        t0 = time.monotonic()
        content = complete(messages, provider_cfg)
        elapsed = time.monotonic() - t0
        # For the in-game panel (main.py pushes it with set_status).
        self.status = {
            "goal": goal_text.split("\n", 1)[0].removeprefix("CURRENT GOAL ").strip() or "(goal ladder off)",
            "model": provider_cfg.model,
            "seconds": round(elapsed, 1),
            "answered": content is not None,
        }

        if content is None:
            log.error("Request %s: no response after %.1fs (timeout=%.0fs) — fallback. "
                      "Raise AI_TIMEOUT or use a faster model.",
                      req.req_id, elapsed, provider_cfg.timeout)
            actions = self._guard(req.req_id, [], payload, suggestion) or _fallback(
                f"model did not respond within {provider_cfg.timeout:.0f}s (raise AI_TIMEOUT or use a faster model)")
            log_exchange(config.output_dir, req.req_id, messages, None, elapsed, actions)
            record_exchange(config.output_dir, req.req_id, payload, None, STATUS_TIMEOUT,
                            elapsed, provider_cfg.provider, provider_cfg.model)
            return actions

        log.info("Request %s: response in %.1fs (%d chars)", req.req_id, elapsed, len(content))
        log.debug("Request %s raw: %s", req.req_id, content[:600])

        entries = parse_response(content)
        if entries is None:
            log.warning("Request %s: could not parse skills/actions — fallback. Raw: %s",
                        req.req_id, content[:600])
            log_exchange(config.output_dir, req.req_id, messages, content, elapsed, None)
            record_exchange(config.output_dir, req.req_id, payload, None, STATUS_PARSE_ERROR,
                            elapsed, provider_cfg.provider, provider_cfg.model)
            return self._guard(req.req_id, [], payload, suggestion) or _fallback(
                "could not parse a valid skill/action array from the model's reply")

        entries = self._guard(req.req_id, entries, payload, suggestion)
        entries = self._label_chat(entries, provider_cfg.provider)
        log.info("Request %s: %d entr(ies) [%s]", req.req_id, len(entries),
                 ", ".join(e.get("skill") or e.get("action", "?") for e in entries))
        log_exchange(config.output_dir, req.req_id, messages, content, elapsed, entries)
        record_exchange(config.output_dir, req.req_id, payload, entries, STATUS_OK,
                        elapsed, provider_cfg.provider, provider_cfg.model)
        return entries

    def _guard(self, req_id: str, entries: list[dict], payload: dict, suggestion) -> list[dict]:
        try:
            out, why = self.coach.guard(entries, payload, suggestion)
        except Exception:
            log.exception("Coach guard failed — sending the model's answer as is")
            return entries
        if why:
            log.warning("Request %s override: %s", req_id, why)
        if out == [{"action": "wait"}] and not entries:
            return []                   # let the caller's fallback explain why
        return out

    @staticmethod
    def _label_chat(entries: list[dict], provider: str) -> list[dict]:
        """Prefix each chat action's message with the provider name."""
        labels = {"anthropic": "[Claude]", "openai": "[GPT]", "lmstudio": "[Local]", "custom": "[Custom]"}
        label = labels.get(provider, "[AI]")
        for e in entries:
            if e.get("action") == "chat" and e.get("message"):
                e["message"] = f"{label} {e['message']}"
        return entries
