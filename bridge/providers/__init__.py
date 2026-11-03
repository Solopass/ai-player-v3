"""
LLM provider interface.

All providers implement the same complete() signature so agent.py
is provider-agnostic. ProviderConfig carries everything provider-specific.

Supported providers:
  "lmstudio"  — openai_compat.py  (LM Studio, Ollama, vLLM, llama.cpp server)
  "openai"    — openai_compat.py  (api.openai.com with real key)
  "custom"    — openai_compat.py  (any OpenAI-compatible endpoint)
  "anthropic" — anthropic.py      (Claude via api.anthropic.com)
  "stub"      — stub.py           (always waits; for the soak test's no-LLM mode)
"""

from dataclasses import dataclass, field


@dataclass
class ProviderConfig:
    provider: str = "lmstudio"
    model: str = "local-model"
    url: str = "http://localhost:1234/v1"
    api_key: str = "lm-studio"
    timeout: float = 120.0
    max_tokens: int = 8192
    temperature: float = 0.7
    reasoning_effort: str = ""
    enable_thinking: bool | None = None
    json_schema: bool = False
    # Set per request by the agent: library blueprints the mod holds, used as
    # the place_blueprint name enum in the schema.
    llm_layout: bool = False
    ghosts: int = 1
    blueprint_names: list[str] = field(default_factory=list)


def get_provider(config: ProviderConfig):
    """Return the complete() callable for the given provider."""
    if config.provider == "anthropic":
        from .anthropic import complete
    elif config.provider == "stub":
        from .stub import complete
    else:
        from .openai_compat import complete
    return complete
