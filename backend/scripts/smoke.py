"""Load a real model, run every starter scene, and try each tool once. Run before playing
to check the model downloads, fits in VRAM, and answers the scenes sensibly."""

import argparse
import json
import sys
import time
from pathlib import Path

import torch
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from glassbox.adapters import load_adapter  # noqa: E402
from glassbox.engine import Engine  # noqa: E402

SCENES = Path(__file__).resolve().parents[2] / "scenes"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="HuggingFaceTB/SmolVLM-256M-Instruct")
    args = p.parse_args()

    t = time.time()
    e = Engine(load_adapter(args.model))
    print(f"loaded {e.a.name}: {e.a.n_layers} layers on {e.a.device} in {time.time() - t:.1f}s")

    for s in json.loads((SCENES / "scenes.json").read_text()):
        t = time.time()
        d = e.load(s["name"], Image.open(SCENES / s["image"]), s["prompt"])
        n_img = sum(tok["kind"] == "image" for tok in d["tokens"])
        print(f"  {s['name']:<22} grid={d['grid_size']} img_tokens={n_img} seq={len(d['tokens'])} "
              f"answer={d['answer']!r} p={d['topk'][0]['p']:.2f} gen={d['generation']!r} ({time.time() - t:.2f}s)")

    a, b = "red circle", "blue circle"
    img = [t.index for t in e.scenes[a].prep.tokens if t.kind == "image"]
    mid = e.a.n_layers // 3
    for name, spec in [
        ("ablate all image tokens", {"type": "ablate", "layer": mid, "positions": img}),
        ("patch image red<-blue", {"type": "patch", "layer": mid, "positions": img, "source": b}),
        ("steer red->blue", {"type": "steer", "layer": mid, "positions": img, "from_text": " red",
                             "to_text": " blue", "scale": 4}),
    ]:
        t = time.time()
        r = e.intervene(a, [spec])
        print(f"  L{mid} {name:<26} -> {r['answer']!r} ({r['outcome']}, p_red "
              f"{r['p_clean_answer']['before']:.2f}->{r['p_clean_answer']['after']:.2f}) "
              f"gen={r['generation']!r} ({time.time() - t:.2f}s)")
    if torch.cuda.is_available():
        print(f"peak VRAM {torch.cuda.max_memory_allocated() / 2**30:.2f} GiB")


if __name__ == "__main__":
    main()
