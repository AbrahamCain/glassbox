"""WebSocket server the Godot client talks to.

Every message is JSON: {"id": n, "op": "...", ...}. Replies echo the id:
{"id": n, "ok": true, "data": {...}} or {"id": n, "ok": false, "error": "..."}.

ops:
  hello                                  model info
  list_scenes                            scenes/scenes.json
  load_scene  {slot, scene} | {slot, image, prompt}
  intervene   {slot, interventions: [...]}   see engine.py for the tool specs
  log         {record}                   appended to logs/plays.jsonl
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import time
import traceback
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from PIL import Image

from .adapters import load_adapter
from .engine import OUTCOMES, TOOLS, Engine, InterventionError

ROOT = Path(__file__).resolve().parents[2]
SCENES = ROOT / "scenes"
LOGS = ROOT / "logs"

# Loopback only: the backend runs model code on request and has no authentication.
HOST = "127.0.0.1"

app = FastAPI()
engine: Engine | None = None
lock = asyncio.Lock()  # one forward pass at a time on the GPU


def scene_list() -> list[dict]:
    path = SCENES / "scenes.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else []


def resolve_image(name: str | None):
    if not name:
        return None
    path = (SCENES / name).resolve()
    if SCENES.resolve() not in path.parents or not path.is_file():
        raise InterventionError(f"image {name!r} not found in scenes/")
    return Image.open(path)


def handle(msg: dict) -> dict:
    op = msg.get("op")
    if op == "hello":
        return {"model": engine.a.name, "n_layers": engine.a.n_layers, "tools": TOOLS, "outcomes": OUTCOMES}
    if op == "list_scenes":
        return {"scenes": scene_list()}
    if op == "load_scene":
        image, prompt = msg.get("image"), msg.get("prompt")
        if msg.get("scene"):
            match = [s for s in scene_list() if s["name"] == msg["scene"]]
            if not match:
                raise InterventionError(f"unknown scene {msg['scene']!r}")
            image, prompt = match[0].get("image"), prompt or match[0]["prompt"]
        if not prompt:
            raise InterventionError("load_scene needs a prompt")
        data = engine.load(msg.get("slot", "A"), resolve_image(image), prompt, image)
        png = engine.scenes[data["slot"]].prep.image_png
        data["image_png"] = base64.b64encode(png).decode() if png else None
        return data
    if op == "intervene":
        return engine.intervene(msg.get("slot", "A"), msg.get("interventions", []))
    if op == "log":
        LOGS.mkdir(exist_ok=True)
        with open(LOGS / "plays.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": time.time(), **msg.get("record", {})}) + "\n")
        return {}
    raise InterventionError(f"unknown op {op!r}")


@app.websocket("/ws")
async def ws(socket: WebSocket):
    await socket.accept()
    try:
        while True:
            msg = json.loads(await socket.receive_text())
            reply = {"id": msg.get("id")}
            try:
                async with lock:
                    reply["data"] = await asyncio.to_thread(handle, msg)
                reply["ok"] = True
            except InterventionError as e:
                reply.update(ok=False, error=str(e))
            except Exception as e:  # keep the session alive; show the error in-game
                traceback.print_exc()
                reply.update(ok=False, error=f"{type(e).__name__}: {e}")
            await socket.send_text(json.dumps(reply))
    except WebSocketDisconnect:
        pass


def main():
    global engine
    import uvicorn

    p = argparse.ArgumentParser()
    p.add_argument("--model", default="HuggingFaceTB/SmolVLM-256M-Instruct", help="HF id, or 'tiny'")
    p.add_argument("--revision", help="Hub commit to load (the default model is already pinned)")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--gen-tokens", type=int, default=12)
    args = p.parse_args()

    print(f"loading {args.model} ...")
    engine = Engine(load_adapter(args.model, args.revision), gen_tokens=args.gen_tokens)
    print(f"ready: {engine.a.n_layers} layers on {engine.a.device}")
    uvicorn.run(app, host=HOST, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
