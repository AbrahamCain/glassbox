from .base import Adapter, Prepared, Token


def load_adapter(spec: str, revision: str | None = None) -> Adapter:
    """`tiny` for the random test model, otherwise a Hugging Face model id (pinned to `revision`)."""
    if spec == "tiny":
        from .tiny import TinyAdapter

        return TinyAdapter()
    if "smolvlm" in spec.lower():
        from .smolvlm import SmolVLMAdapter

        return SmolVLMAdapter(spec, revision)
    raise ValueError(f"no adapter for {spec!r} yet; add one in glassbox/adapters/")


__all__ = ["Adapter", "Prepared", "Token", "load_adapter"]
