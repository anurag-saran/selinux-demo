# Deterministic policy generation

Offline AVC → `.te` / `.fc` updates using **house rules** and optional **sepolgen** interface matching (same stack as `audit2allow -R`). This is the **default** engine in `dev_generate_policy.sh` (no `--engine` flag required).

## Quick start

```bash
# Export AVCs (or use policy_out/avc.log) — deterministic is already the default
bash scripts/dev_generate_policy.sh --skip-export

# Classify only (no API, no compile) — good for demos / review
python3 cli/deterministic_gen.py --explain \
  --avc-log docs/examples/fixtures/deterministic/01-mislabeled-var-lib/avc.log \
  --manifest config/myapp.manifest.yml \
  --existing-te selinux/myapp.te \
  --existing-fc selinux/myapp.fc
```

## RHEL one-time setup (interface matching)

```bash
sudo dnf install -y policycoreutils-devel setools-console
sudo sepolgen-ifgen
# → /var/lib/sepolgen/interface_info
```

Without ifgen, the generator prints a **stderr banner** on every run (`SEPOLGEN INTERFACE MATCHING IS NOT AVAILABLE`) and still classifies **direct** / **fc_fix** / **fc_drift** / **private_port** rules. Base-type allows require sepolgen or explicit **`--allow-degraded`** (extra degraded banner; `engine=degraded` in `findings.json`). Exit code **1** when blockers remain (`forbidden`, `toolchain_required`) unless you only used `--explain`.

Do not confuse missing ifgen with “no interface matched” — the latter is logged when ifgen data exists but no macro fits the denial.

## Fast compiles (Podman / Red Hat demo)

**Demo default:** pull pre-built **CentOS Stream 9** image from Docker Hub (seconds):

```bash
bash scripts/lib/selinux_build_image.sh pull
# or: bash scripts/lib/selinux_build_image.sh ensure   # pull → local build if needed
export SELINUX_BUILD_IMAGE=docker.io/asaran/selinux-demo-selinux-build:stream9   # optional override
```

Details: [DOCKER_HUB_COMPILE_IMAGE.md](DOCKER_HUB_COMPILE_IMAGE.md). Local build (~2–4 min): `bash scripts/build_selinux_compile_image.sh`. Maintainers publish with `scripts/publish_selinux_compile_image.sh` (Hub token via env only).

**Automatic:** `dev_generate_policy.sh`, `compile_and_validate.sh`, and `compile_module.sh` call **`ensure_selinux_build_image`** (`SELINUX_BUILD_IMAGE_PULL=1` by default).

After the image exists, these use **make-only** container runs (no per-invocation `dnf`):

- `compile_policy_module` / `compile_and_validate.sh`
- `validate_policy_semantics.sh`
- `policy_module_diff.sh` (PR access delta)
- `classify_policy_blast_radius.sh`
- `cli/selinux_gen.py` container compile (via `compile_module.sh`)

## House rules (see `cli/policy_rules.py`)

| Verdict | Meaning |
|---------|---------|
| `fc_fix` | Path under manifest dirs but **no** matching `.fc` regex yet → add directory/file pattern + `restorecon` |
| `fc_drift` | Path already covered by an existing `.fc` regex but wrong label on disk → **`restorecon` only** (no new `.fc` line) |
| `private_port` | `name_bind` on shared port type → app `_port_t` |
| `forbidden` | Refused (`shadow_t`, etc.) — same spirit as CI forbidden patterns |
| `baseline` | Already covered in existing `.te` or baseline macro (e.g. `dev_read_urand` for `random_device_t`) |
| `interface` | sepolgen refpolicy macro (when ifgen data present) |
| `direct` | Module-private types, or sepolgen ran but no macro matched (manual review) |
| `toolchain_required` | Base-type denial with no sepolgen and no `--allow-degraded` — generation blocked |

## Verification

After generation, `dev_generate_policy.sh` runs:

```bash
python3 cli/verify_avc_coverage.py --avc-log policy_out/avc.log \
  --te policy_out/myapp.te --manifest config/myapp.manifest.yml
```

Labeling fixes (`fc_fix`, `fc_drift`) are satisfied via `findings.json`, not allow rules. Shared logic: **`cli/fc_labeling.py`** (also strips redundant lines from LLM `.fc` output).

`findings.json` is an object: `sepolgen_status`, `sepolgen_detail`, and `findings` (array of classified rows). Older list-only files still work in `verify_avc_coverage.py`.

## Engines

| Command | Engine |
|---------|--------|
| `dev_generate_policy.sh` (default) | `cli/deterministic_gen.py` |
| `dev_generate_policy.sh --engine llm` | LLM (`cli/selinux_gen.py`) |

Fixtures: [`docs/examples/fixtures/deterministic/`](examples/fixtures/deterministic/) — nine AVC directories; each has `avc.log` + `expected.json`. CI runs `deterministic_verdict_fixture_coverage` (all eight verdicts) and `deterministic_fixture_classify`. Cases `08`/`09` use optional `sepolgen_mock.json` so CI does not require host ifgen.
