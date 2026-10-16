"""Model adapters map an architecture onto the common schema the game understands.

The engine and the Godot client only ever see: a stack of residual blocks, an
unembedding, and a token list where each token is tagged as image / text / special
(image tokens carry their (row, col) on the patch board). Supporting a new model
means writing one adapter, nothing else.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import torch
from torch import nn


@dataclass
class Token:
    index: int
    text: str
    kind: str  # "image" | "text" | "special"
    grid: tuple[int, int] | None = None


@dataclass
class Prepared:
    inputs: dict[str, torch.Tensor]
    tokens: list[Token]
    grid_size: int = 0  # side length of the image-token board, 0 for text-only
    image_png: bytes | None = None  # exactly the pixels the model sees
    extra: dict = field(default_factory=dict)


def first_attr(obj, *paths: str):
    """Return the first dotted attribute path that exists (layouts shift between versions)."""
    for path in paths:
        cur = obj
        try:
            for part in path.split("."):
                cur = getattr(cur, part)
        except AttributeError:
            continue
        return cur
    raise AttributeError(f"none of {paths} found on {type(obj).__name__}")


class Adapter(ABC):
    name: str
    model: nn.Module
    device: torch.device
    dtype: torch.dtype

    @abstractmethod
    def blocks(self) -> list[nn.Module]:
        """Residual blocks of the language model, in order."""

    @abstractmethod
    def unembed(self, h: torch.Tensor) -> torch.Tensor:
        """Final norm + LM head: residual [..., d] -> logits [..., vocab]."""

    @abstractmethod
    def prepare(self, image, prompt: str) -> Prepared:
        """Build model inputs for an (optional) PIL image and a user prompt."""

    @abstractmethod
    def text_inputs(self, text: str) -> dict[str, torch.Tensor]:
        """Bare text inputs (no chat template), used to build steering vectors."""

    @abstractmethod
    def decode(self, ids: list[int]) -> str: ...

    def forward(self, inputs: dict[str, torch.Tensor]) -> torch.Tensor:
        """Logits for the whole sequence, [seq, vocab]."""
        return self.model(**inputs).logits[0]

    def extend(self, inputs: dict[str, torch.Tensor], token_id: int) -> dict[str, torch.Tensor]:
        """Append one token (greedy generation without a KV cache)."""
        out = dict(inputs)
        tok = torch.tensor([[token_id]], device=inputs["input_ids"].device)
        out["input_ids"] = torch.cat([inputs["input_ids"], tok], dim=1)
        if "attention_mask" in inputs:
            one = torch.ones_like(tok, dtype=inputs["attention_mask"].dtype)
            out["attention_mask"] = torch.cat([inputs["attention_mask"], one], dim=1)
        return out

    @property
    def n_layers(self) -> int:
        return len(self.blocks())


def pick_device() -> tuple[torch.device, torch.dtype]:
    if torch.cuda.is_available():
        return torch.device("cuda"), torch.bfloat16
    return torch.device("cpu"), torch.float32
