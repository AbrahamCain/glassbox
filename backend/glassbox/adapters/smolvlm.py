"""SmolVLM (Idefics3 architecture): SigLIP vision encoder -> pixel-shuffle connector -> Llama.

Image splitting is turned off so each image becomes one global tile. At 512px with a
16px patch and pixel-shuffle factor 4, that is 8x8 = 64 image tokens, laid out row-major
(Idefics3Connector.pixel_shuffle keeps raster order), each covering a 64x64 pixel block.
"""

from __future__ import annotations

import io
import math

import torch
from PIL import Image

from .base import Adapter, Prepared, Token, first_attr, pick_device

DEFAULT_ID = "HuggingFaceTB/SmolVLM-256M-Instruct"
# Exact Hub commit the quests were calibrated on. Pinning means a change upstream can't
# silently swap the weights or processor code we load.
DEFAULT_REVISION = "7e3e67edbbed1bf9888184d9df282b700a323964"


def resolve_revision(model_id: str, revision: str | None) -> str:
    """The default model is pinned; any other model must be pinned explicitly."""
    if revision:
        return revision
    if model_id == DEFAULT_ID:
        return DEFAULT_REVISION
    raise ValueError(f"pin {model_id!r} to a commit: --revision <sha> (or 'main' to accept unpinned)")


def square(image: Image.Image, size: int) -> Image.Image:
    """Center-crop to a square and resize, so board cells map exactly onto pixels."""
    image = image.convert("RGB")
    w, h = image.size
    s = min(w, h)
    left, top = (w - s) // 2, (h - s) // 2
    return image.crop((left, top, left + s, top + s)).resize((size, size), Image.BICUBIC)


class SmolVLMAdapter(Adapter):
    def __init__(self, model_id: str = DEFAULT_ID, revision: str | None = None):
        from transformers import AutoModelForImageTextToText, AutoProcessor

        self.name = model_id
        self.revision = resolve_revision(model_id, revision)
        self.device, self.dtype = pick_device()
        self.processor = AutoProcessor.from_pretrained(model_id, revision=self.revision)
        self.processor.image_processor.do_image_splitting = False
        self.tokenizer = self.processor.tokenizer
        self.model = AutoModelForImageTextToText.from_pretrained(model_id, revision=self.revision, dtype=self.dtype)
        self.model.to(self.device).eval()

        self.text_model = first_attr(self.model, "model.text_model", "model.language_model")
        self.image_token_id = self.model.config.image_token_id
        size = getattr(self.processor.image_processor, "max_image_size", None) or {}
        self.image_size = int(size.get("longest_edge", 512))
        self.special_ids = set(self.tokenizer.all_special_ids)
        eou = self.tokenizer.convert_tokens_to_ids("<end_of_utterance>")
        self.eos_ids = {i for i in (self.tokenizer.eos_token_id, eou) if isinstance(i, int) and i >= 0}

    def blocks(self):
        return list(self.text_model.layers)

    def unembed(self, h):
        return self.model.lm_head(self.text_model.norm(h))

    def prepare(self, image, prompt):
        content = ([{"type": "image"}] if image is not None else []) + [{"type": "text", "text": prompt}]
        messages = [{"role": "user", "content": content}]
        text = self.processor.apply_chat_template(messages, add_generation_prompt=True)

        png = None
        if image is not None:
            image = square(image, self.image_size)
            buf = io.BytesIO()
            image.save(buf, format="PNG")
            png = buf.getvalue()
            inputs = self.processor(text=text, images=[image], return_tensors="pt", do_image_splitting=False)
        else:
            inputs = self.processor(text=text, return_tensors="pt")
        inputs = {k: v.to(self.device) for k, v in inputs.items()}
        if "pixel_values" in inputs:
            inputs["pixel_values"] = inputs["pixel_values"].to(self.dtype)

        ids = inputs["input_ids"][0].tolist()
        n_img = sum(1 for i in ids if i == self.image_token_id)
        grid = math.isqrt(n_img)
        if grid * grid != n_img:
            grid = 0  # unexpected layout; the board falls back to a strip

        tokens, k = [], 0
        for idx, tid in enumerate(ids):
            if tid == self.image_token_id:
                cell = (k // grid, k % grid) if grid else (0, k)
                tokens.append(Token(idx, "<img>", "image", cell))
                k += 1
            else:
                kind = "special" if tid in self.special_ids else "text"
                tokens.append(Token(idx, self.tokenizer.decode([tid]), kind))
        return Prepared(inputs, tokens, grid, png)

    def text_inputs(self, text):
        enc = self.tokenizer(text, return_tensors="pt", add_special_tokens=False)
        return {k: v.to(self.device) for k, v in enc.items()}

    def decode(self, ids):
        return self.tokenizer.decode(ids)
