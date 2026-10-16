"""Engine tests on the random tiny model: no download, no GPU, about a second."""

import pytest
import torch
from PIL import Image

from glassbox.adapters.tiny import TinyAdapter
from glassbox.engine import Engine, InterventionError, outcome


@pytest.fixture(scope="module")
def engine():
    e = Engine(TinyAdapter(), gen_tokens=3)
    img = Image.new("RGB", (64, 64), (200, 0, 0))
    e.load("A", img, "what color?")
    e.load("B", Image.new("RGB", (64, 64), (0, 0, 200)), "what color?")
    return e


def image_positions(e, slot="A"):
    return [t.index for t in e.scenes[slot].prep.tokens if t.kind == "image"]


def test_describe_shapes(engine):
    d = engine.describe(engine.scenes["A"])
    seq = engine.scenes["A"].seq_len
    assert d["grid_size"] == 4
    assert len(d["activity"]) == engine.a.n_layers and len(d["activity"][0]) == seq
    assert len(d["lens"]) == engine.a.n_layers
    assert sum(t["kind"] == "image" for t in d["tokens"]) == 16


def test_no_intervention_is_identity(engine):
    """A hook that edits nothing must reproduce the clean run exactly."""
    s = engine.scenes["A"]
    logits, _, resid = engine._forward(s.prep.inputs, {0: [lambda h: h]})
    assert torch.allclose(logits[-1], s.logits, atol=1e-5)
    assert torch.allclose(resid, s.resid, atol=1e-5)


def test_ripple_starts_at_intervened_layer(engine):
    """Nothing upstream of the edited layer may change; the edited cells must."""
    layer = 2
    r = engine.intervene("A", [{"type": "ablate", "layer": layer, "positions": [3], "mode": "zero"}])
    ripple = torch.tensor(r["ripple"])
    assert ripple[:layer].abs().max() == 0
    assert ripple[layer, 3] > 0.5


def test_patch_everything_reproduces_source(engine):
    """Patching every position at layer 0 from B turns A's downstream run into B's."""
    seq = engine.scenes["A"].seq_len
    r = engine.intervene("A", [{"type": "patch", "layer": 0, "positions": list(range(seq)), "source": "B"}])
    b = engine.describe(engine.scenes["B"])
    assert r["topk"][0] == b["topk"][0]


def test_mean_ablation_uses_same_kind_mean(engine):
    s = engine.scenes["A"]
    pos = image_positions(engine)[:2]
    edits = engine._compile(s, [{"type": "ablate", "layer": 1, "positions": pos}])
    _, _, resid = engine._forward(s.prep.inputs, edits)
    assert torch.allclose(resid[1, pos[0]], s.means["image"][1], atol=1e-5)


def test_steer_adds_scaled_difference(engine):
    s = engine.scenes["A"]
    spec = {"type": "steer", "layer": 1, "positions": [5], "from_text": "red", "to_text": "blue", "scale": 2.0}
    _, _, resid = engine._forward(s.prep.inputs, engine._compile(s, [spec]))
    vec = engine._steer_vector(1, "red", "blue")
    assert torch.allclose(resid[1, 5] - s.resid[1, 5], 2.0 * vec, atol=1e-4)


@pytest.mark.parametrize("spec", [
    {"type": "explode", "layer": 0, "positions": [0]},
    {"type": "ablate", "layer": 99, "positions": [0]},
    {"type": "ablate", "layer": 0, "positions": []},
    {"type": "patch", "layer": 0, "positions": [0], "source": "Z"},
    {"type": "steer", "layer": 0, "positions": [0]},
])
def test_bad_specs_rejected(engine, spec):
    with pytest.raises(InterventionError):
        engine.intervene("A", [spec])


def test_outcome_buckets():
    assert outcome(0.9, 0.88, False) == "nothing"
    assert outcome(0.9, 0.7, False) == "nudge"
    assert outcome(0.9, 0.4, False) == "shove"
    assert outcome(0.9, 0.1, True) == "flip"


def test_lens_tracks_new_answer(engine):
    """After a flip, p_new follows the new answer; without one it equals p_answer."""
    seq = engine.scenes["A"].seq_len
    r = engine.intervene("A", [{"type": "patch", "layer": 0, "positions": list(range(seq)), "source": "B"}])
    top = engine.a.decode([int(engine.scenes["B"].logits.argmax())])
    assert r["new_answer"] == top
    assert r["lens"][-1]["p_new"] == r["topk"][0]["p"]
    d = engine.describe(engine.scenes["A"])
    assert all(row["p_new"] == row["p_answer"] for row in d["lens"])
