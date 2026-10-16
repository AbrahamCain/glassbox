"""A randomly initialised tiny Llama. Meaningless outputs, but it exercises the whole
pipeline in about a second on CPU, so tests and client development don't need a GPU.

When given an image it fakes a 4x4 board by prepending 16 tokens tagged as image.
"""

from __future__ import annotations

import io

import torch

from .base import Adapter, Prepared, Token

VOCAB = 256  # byte-level "tokenizer"
GRID = 4


class TinyAdapter(Adapter):
    def __init__(self, n_layers: int = 4, d_model: int = 64, seed: int = 0):
        from transformers import LlamaConfig, LlamaForCausalLM

        torch.manual_seed(seed)
        cfg = LlamaConfig(
            vocab_size=VOCAB, hidden_size=d_model, intermediate_size=d_model * 2,
            num_hidden_layers=n_layers, num_attention_heads=4, num_key_value_heads=4,
            max_position_embeddings=512,
        )
        self.name = f"tiny-llama-{n_layers}L"
        self.device, self.dtype = torch.device("cpu"), torch.float32
        self.model = LlamaForCausalLM(cfg).eval()

    def blocks(self):
        return list(self.model.model.layers)

    def unembed(self, h):
        return self.model.lm_head(self.model.model.norm(h))

    def _ids(self, text: str) -> list[int]:
        return list(text.encode("utf-8", errors="replace"))

    def prepare(self, image, prompt):
        tokens, ids, png = [], [], None
        if image is not None:
            for k in range(GRID * GRID):
                tokens.append(Token(len(ids), "<img>", "image", (k // GRID, k % GRID)))
                ids.append(k)
            buf = io.BytesIO()
            image.convert("RGB").resize((256, 256)).save(buf, format="PNG")
            png = buf.getvalue()
        for b in self._ids(prompt):
            tokens.append(Token(len(ids), chr(b), "text"))
            ids.append(b)
        inputs = {"input_ids": torch.tensor([ids]), "attention_mask": torch.ones(1, len(ids), dtype=torch.long)}
        return Prepared(inputs, tokens, GRID if image is not None else 0, png)

    def text_inputs(self, text):
        return {"input_ids": torch.tensor([self._ids(text)])}

    def decode(self, ids):
        return bytes(i % 256 for i in ids).decode("utf-8", errors="replace")
