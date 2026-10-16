"""Security tests for the backend's attack surface: a WebSocket server that opens files
named by the client and loads model code from the Hugging Face Hub."""

import re

import pytest

from glassbox import server
from glassbox.adapters.smolvlm import DEFAULT_ID, DEFAULT_REVISION, resolve_revision
from glassbox.adapters.tiny import TinyAdapter
from glassbox.engine import Engine, InterventionError


@pytest.fixture(scope="module", autouse=True)
def tiny_engine():
    server.engine = Engine(TinyAdapter(), gen_tokens=2)
    yield
    server.engine = None


@pytest.mark.parametrize("name", [
    "../README.md",
    "../../backend/glassbox/server.py",
    "..\\..\\README.md",
    "/etc/passwd",
    "C:\\Windows\\win.ini",
    "scenes.json/../../README.md",
    "does_not_exist.png",
])
def test_image_paths_cannot_escape_scenes_dir(name):
    with pytest.raises(InterventionError):
        server.resolve_image(name)


def test_scene_image_loads():
    assert server.resolve_image("red_circle.png") is not None


def test_traversal_via_load_scene_op_is_rejected():
    with pytest.raises(InterventionError):
        server.handle({"op": "load_scene", "slot": "A", "image": "../README.md", "prompt": "x"})


@pytest.mark.parametrize("msg", [
    {"op": "exec"},
    {"op": "load_scene", "scene": "no such scene"},
    {"op": "load_scene", "slot": "A"},
    {"op": "intervene", "slot": "nope", "interventions": []},
])
def test_bad_requests_raise_clean_errors(msg):
    with pytest.raises(InterventionError):
        server.handle(msg)


def test_server_binds_loopback_only():
    assert server.HOST == "127.0.0.1"


def test_default_model_is_pinned_to_a_commit():
    assert re.fullmatch(r"[0-9a-f]{40}", DEFAULT_REVISION)
    assert resolve_revision(DEFAULT_ID, None) == DEFAULT_REVISION


def test_other_models_must_be_pinned_explicitly():
    with pytest.raises(ValueError):
        resolve_revision("someone/some-model", None)
    assert resolve_revision("someone/some-model", "abc123") == "abc123"
