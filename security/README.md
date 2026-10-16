# DevSecOps Pipeline

Every push and pull request runs `.github/workflows/ci.yml` (workflow name **ci**), which has three jobs:

| Job | Stage | Tool | Gate |
|-----|-------|------|------|
| tests | Unit tests | pytest (engine, on a random tiny model) | Any failing test |
| | Security tests | pytest ([`test_security.py`](../backend/tests/test_security.py)) | Path traversal out of `scenes/`, non-loopback bind, unpinned model, unclean errors on bad requests |
| godot | Build check | Godot 4.7.2 headless import + `--check-only` on every script | Any script parse or load error |
| sast-sca-secrets | SAST | Bandit | Medium or high severity in non-test code |
| | SAST | Semgrep (`p/python`) | Report only |
| | SCA | pip-audit on the exact installed versions | Any known-vulnerable dependency, torch included |
| | Secrets | Gitleaks with [`gitleaks.toml`](./gitleaks.toml), full git history | Any secret in any commit |

## Threat model, briefly

The backend is a WebSocket server that runs model code on request and opens image files named
by the client. It has no authentication, so it binds to `127.0.0.1` only and is tested for that.
Image names are resolved inside `scenes/` and anything that escapes it is rejected. Model weights
and processor code come from the Hugging Face Hub, so the default model is pinned to an exact
commit, and any other model must be pinned explicitly (`--revision`).

## Tuning decisions

- **No container or DAST stage.** Glassbox ships no container image or web service. The only
  network surface is the loopback WebSocket, which the security tests cover directly.
- **Model pinning (Bandit B615).** Bandit flagged the unpinned `from_pretrained` calls. They now
  load `DEFAULT_REVISION`, the commit the quests were calibrated on, rather than suppressing the check.
- **pip-audit audits the installed environment, not `requirements.txt`.** The CPU torch wheel is
  versioned `x.y.z+cpu`, which PyPI's advisory lookup doesn't recognise, so a requirements-file audit
  silently skips torch. CI installs the real environment, strips local version tags, and audits the
  exact versions. This found vulnerable setuptools pulled in by torch, now required at `>=83`.
- **Gitleaks scans history.** The repo is public, so a secret committed and later deleted would
  still be exposed. There's no allowlist: Glassbox has no credential-like fixtures.
- **Semgrep is report-only** while a baseline is established, matching the portfolio repo.
  Promoting it to a gate is a one-line change.
