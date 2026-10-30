"""
OpenAI-compatible provider.

Covers: LM Studio, Ollama, llama.cpp server, vLLM, OpenAI, and any other
endpoint that implements the OpenAI chat completions API.

LM Studio exposes http://localhost:1234/v1 by default.
The api_key is required by the SDK but ignored by local servers — use any string.
"""

import logging
from . import ProviderConfig

log = logging.getLogger(__name__)


def complete(messages: list[dict], config: ProviderConfig) -> str | None:
    """
    Send a chat completion request to an OpenAI-compatible endpoint.

    messages: standard OpenAI format — [{"role": "system"|"user"|"assistant", "content": str}]
    Returns the assistant content string, or None on failure.
    """
    try:
        from openai import OpenAI, APIError, APITimeoutError, APIConnectionError
    except ImportError:
        log.error("openai package not installed — run: pip install openai")
        return None

    client = OpenAI(
        base_url=config.url,
        api_key=config.api_key,
        timeout=config.timeout,
        # No retries: the SDK retries timeouts twice by default, and each retry
        # re-submits the full prompt and restarts the local model's generation —
        # so a slow model never finishes and one "turn" silently costs
        # 3 × timeout seconds. One clean attempt; the mod re-requests next tick.
        max_retries=0,
    )

    # gpt-oss on llama.cpp reads reasoning_effort via the chat template kwargs;
    # other servers take the top-level field. Send both — unknown keys are ignored.
    # Gemma 4 / Qwen3.5 templates read enable_thinking instead.
    extra_body: dict = {}
    template_kwargs: dict = {}
    if config.reasoning_effort:
        extra_body["reasoning_effort"] = config.reasoning_effort
        template_kwargs["reasoning_effort"] = config.reasoning_effort
    if config.enable_thinking is not None:
        template_kwargs["enable_thinking"] = config.enable_thinking
    if template_kwargs:
        extra_body["chat_template_kwargs"] = template_kwargs

    # Constrained decoding: the server can only emit a valid skill/action array.
    kwargs = {}
    if config.json_schema:
        from ..schema import response_format
        kwargs["response_format"] = response_format(blueprint_names=config.blueprint_names)

    try:
        response = client.chat.completions.create(
            model=config.model,
            messages=messages,
            max_tokens=config.max_tokens,
            temperature=config.temperature,
            extra_body=extra_body or None,
            **kwargs,
        )
        if not response.choices:
            log.error(
                "LM Studio returned no choices (model=%s). "
                "Is the model loaded and the server running?",
                config.model,
            )
            return None
        content = response.choices[0].message.content
        if response.choices[0].finish_reason == "length":
            log.warning("Reply hit max_tokens (%d) and was cut off (model=%s) — raise AI_MAX_TOKENS",
                        config.max_tokens, config.model)
        if content is None:
            log.error("response.choices[0].message.content is None (model=%s)", config.model)
            return None
        log.debug("provider=openai_compat tokens_used=%s", response.usage)
        return content

    except APITimeoutError:
        log.error("Request timed out after %.0fs (model=%s)", config.timeout, config.model)
    except APIConnectionError as e:
        log.error("Cannot reach %s: %s", config.url, e)
    except APIError as e:
        log.error("API error %s: %s", e.status_code, e.message)

    return None
