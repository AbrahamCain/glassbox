"""Forward passes with hooks: capture the residual stream, apply the player's tools.

Layer L always means "the residual stream right after block L". An intervention
rewrites that stream at some token positions, and everything downstream reacts.

Tools:
  ablate  replace the residual with the mean over same-kind tokens (or zero)
  patch   copy the residual from the same positions in another loaded scene
  steer   add scale * (r(to_text) - r(from_text)), a difference of activations
"""

from __future__ import annotations

from dataclasses import dataclass

import torch

from .adapters import Adapter, Prepared, Token

TOOLS = ("ablate", "patch", "steer")
# How much the clean answer's probability moved. Players predict this before casting.
OUTCOMES = ("nothing", "nudge", "shove", "flip")
LENS_K = 3


def outcome(p_clean: float, p_new: float, flipped: bool) -> str:
    if flipped:
        return "flip"
    moved = abs(p_clean - p_new)
    if moved < 0.05:
        return "nothing"
    return "nudge" if moved < 0.30 else "shove"


@dataclass
class Scene:
    slot: str
    image_name: str | None
    prompt: str
    prep: Prepared
    embed: torch.Tensor  # [seq, d] input to block 0
    resid: torch.Tensor  # [layers, seq, d] clean residual after each block (float32, cpu)
    logits: torch.Tensor  # [vocab] clean next-token logits
    answer_id: int
    generation: str
    means: dict[str, torch.Tensor]  # kind -> [layers, d]

    @property
    def seq_len(self) -> int:
        return self.resid.shape[1]


class InterventionError(ValueError):
    pass


class Engine:
    def __init__(self, adapter: Adapter, gen_tokens: int = 12):
        self.a = adapter
        self.gen_tokens = gen_tokens
        self.scenes: dict[str, Scene] = {}
        self._steer_cache: dict[tuple, torch.Tensor] = {}

    # ---------------------------------------------------------------- forward

    @torch.no_grad()
    def _forward(self, inputs, edits=None, capture=True):
        """Run the model. `edits` maps layer -> list of fn(h[seq, d]) -> h, applied in place
        on a clone. Returns (logits [seq, vocab], embed [seq, d] | None, resid [L, seq, d] | None)."""
        blocks = self.a.blocks()
        edits = edits or {}
        captured: list[torch.Tensor | None] = [None] * len(blocks)
        embed: list[torch.Tensor] = []
        handles = []

        def pre_hook(_mod, args, kwargs):
            h = args[0] if args else kwargs["hidden_states"]
            embed.append(h[0].detach().float().cpu())

        def make_hook(layer):
            def hook(_mod, _args, out):
                h = out[0] if isinstance(out, tuple) else out
                if layer in edits:
                    h = h.clone()
                    for fn in edits[layer]:
                        h[0] = fn(h[0])
                if capture:
                    captured[layer] = h[0].detach().float().cpu()
                if layer in edits:
                    return (h, *out[1:]) if isinstance(out, tuple) else h
                return None

            return hook

        try:
            if capture:
                handles.append(blocks[0].register_forward_pre_hook(pre_hook, with_kwargs=True))
            for i, block in enumerate(blocks):
                if capture or i in edits:
                    handles.append(block.register_forward_hook(make_hook(i)))
            logits = self.a.forward(inputs).float()
        finally:
            for h in handles:
                h.remove()

        if not capture:
            return logits, None, None
        return logits, embed[0], torch.stack(captured)

    @torch.no_grad()
    def _generate(self, inputs, first_logits, edits):
        ids = []
        logits = first_logits
        eos = getattr(self.a, "eos_ids", set())
        for step in range(self.gen_tokens):
            nxt = int(logits.argmax())
            if nxt in eos:
                break
            ids.append(nxt)
            if step == self.gen_tokens - 1:
                break
            inputs = self.a.extend(inputs, nxt)
            logits = self._forward(inputs, edits, capture=False)[0][-1]
        return self.a.decode(ids).strip()

    # ---------------------------------------------------------------- scenes

    def load(self, slot: str, image, prompt: str, image_name: str | None = None) -> dict:
        prep = self.a.prepare(image, prompt)
        logits, embed, resid = self._forward(prep.inputs)
        last = logits[-1]
        # If the model opens with whitespace (" " before "3"), feed it in so the final
        # position is the one that predicts the actual answer.
        for _ in range(3):
            tid = int(last.argmax())
            text = self.a.decode([tid])
            if text.strip() or tid in getattr(self.a, "eos_ids", set()):
                break
            prep.inputs = self.a.extend(prep.inputs, tid)
            prep.tokens.append(Token(len(prep.tokens), text, "text"))
            logits, embed, resid = self._forward(prep.inputs)
            last = logits[-1]
        means = {}
        for kind in ("image", "text", "special"):
            pos = [t.index for t in prep.tokens if t.kind == kind]
            if pos:
                means[kind] = resid[:, pos].mean(dim=1)
        scene = Scene(
            slot, image_name, prompt, prep, embed, resid, last,
            int(last.argmax()), self._generate(prep.inputs, last, {}), means,
        )
        self.scenes[slot] = scene
        return self.describe(scene)

    def describe(self, s: Scene) -> dict:
        prev = torch.cat([s.embed[None], s.resid[:-1]])
        activity = (s.resid - prev).norm(dim=-1) / (prev.norm(dim=-1) + 1e-6)
        return {
            "slot": s.slot,
            "image": s.image_name,
            "prompt": s.prompt,
            "model": self.a.name,
            "n_layers": self.a.n_layers,
            "grid_size": s.prep.grid_size,
            "tokens": [
                {"index": t.index, "text": t.text, "kind": t.kind, "grid": list(t.grid) if t.grid else None}
                for t in s.prep.tokens
            ],
            "answer": self.a.decode([s.answer_id]),
            "generation": s.generation,
            "topk": self._topk(s.logits),
            "lens": self._lens(s.resid, s.answer_id),
            "activity": _round(activity),
        }

    # ---------------------------------------------------------------- tools

    def _steer_vector(self, layer: int, src: str, dst: str) -> torch.Tensor:
        key = (layer, src, dst)
        if key not in self._steer_cache:
            vecs = []
            for text in (src, dst):
                _, _, resid = self._forward(self.a.text_inputs(text))
                vecs.append(resid[layer, -1])
            self._steer_cache[key] = vecs[1] - vecs[0]
        return self._steer_cache[key]

    def _compile(self, scene: Scene, specs: list[dict]):
        edits: dict[int, list] = {}
        n_layers = self.a.n_layers
        for spec in specs:
            tool = spec.get("type")
            if tool not in TOOLS:
                raise InterventionError(f"unknown tool {tool!r}")
            layer = int(spec.get("layer", -1))
            if not 0 <= layer < n_layers:
                raise InterventionError(f"layer {layer} out of range 0..{n_layers - 1}")
            positions = sorted({int(p) for p in spec.get("positions", [])})
            if not positions or positions[0] < 0 or positions[-1] >= scene.seq_len:
                raise InterventionError("positions missing or out of range")
            pos = torch.tensor(positions)

            if tool == "ablate":
                if spec.get("mode", "mean") == "zero":
                    fill = torch.zeros(len(positions), scene.resid.shape[-1])
                else:
                    kinds = [scene.prep.tokens[p].kind for p in positions]
                    fill = torch.stack([scene.means[k][layer] for k in kinds])
                fn = _setter(pos, fill)
            elif tool == "patch":
                src = self.scenes.get(spec.get("source", ""))
                if src is None:
                    raise InterventionError(f"patch source scene {spec.get('source')!r} not loaded")
                if src.seq_len != scene.seq_len:
                    raise InterventionError(
                        f"patch needs identically shaped scenes ({src.seq_len} vs {scene.seq_len} tokens); "
                        "use the same prompt for both")
                fn = _setter(pos, src.resid[layer, pos])
            else:
                src_text, dst_text = spec.get("from_text", ""), spec.get("to_text", "")
                if not src_text or not dst_text:
                    raise InterventionError("steer needs from_text and to_text")
                vec = float(spec.get("scale", 4.0)) * self._steer_vector(layer, src_text, dst_text)
                fn = _adder(pos, vec)
            edits.setdefault(layer, []).append(fn)
        return edits

    def intervene(self, slot: str, specs: list[dict]) -> dict:
        scene = self.scenes.get(slot)
        if scene is None:
            raise InterventionError(f"scene {slot!r} not loaded")
        edits = self._compile(scene, specs)
        logits, _, resid = self._forward(scene.prep.inputs, edits)
        last = logits[-1]

        p_clean = float(torch.softmax(scene.logits, -1)[scene.answer_id])
        p_new = float(torch.softmax(last, -1)[scene.answer_id])
        new_id = int(last.argmax())
        ripple = (resid - scene.resid).norm(dim=-1) / (scene.resid.norm(dim=-1) + 1e-6)
        return {
            "slot": slot,
            "answer": self.a.decode([new_id]),
            "clean_answer": self.a.decode([scene.answer_id]),
            "p_clean_answer": {"before": round(p_clean, 4), "after": round(p_new, 4)},
            "outcome": outcome(p_clean, p_new, new_id != scene.answer_id),
            "generation": self._generate(scene.prep.inputs, last, edits),
            "clean_generation": scene.generation,
            "topk": self._topk(last),
            "new_answer": self.a.decode([new_id]),
            "lens": self._lens(resid, scene.answer_id, new_id),
            "ripple": _round(ripple),
        }

    # ---------------------------------------------------------------- readouts

    def _topk(self, logits: torch.Tensor, k: int = 8) -> list[dict]:
        probs = torch.softmax(logits, -1)
        p, ids = probs.topk(k)
        return [{"token": self.a.decode([int(i)]), "p": round(float(q), 4)} for q, i in zip(p, ids)]

    @torch.no_grad()
    def _lens(self, resid: torch.Tensor, answer_id: int, new_id: int | None = None) -> list[dict]:
        """Logit lens at the final position: what each floor would answer if it were the last.
        `p_answer` tracks the clean answer; `p_new` the answer after an intervention."""
        h = resid[:, -1].to(self.a.device, self.a.dtype)
        probs = torch.softmax(self.a.unembed(h).float(), -1).cpu()
        p, ids = probs.topk(LENS_K)
        return [
            {
                "top": [{"token": self.a.decode([int(i)]), "p": round(float(q), 4)} for q, i in zip(p[L], ids[L])],
                "p_answer": round(float(probs[L, answer_id]), 4),
                "p_new": round(float(probs[L, new_id if new_id is not None else answer_id]), 4),
            }
            for L in range(probs.shape[0])
        ]


def _setter(pos, fill):
    def fn(h):
        h[pos] = fill.to(h.device, h.dtype)
        return h

    return fn


def _adder(pos, vec):
    def fn(h):
        h[pos] = h[pos] + vec.to(h.device, h.dtype)
        return h

    return fn


def _round(t: torch.Tensor) -> list:
    return [[round(float(x), 4) for x in row] for row in t]
