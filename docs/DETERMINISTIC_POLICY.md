# Deterministic policy generation

Offline AVC → `.te` / `.fc` updates using **house rules** and optional **sepolgen** interface matching (same stack as `audit2allow -R`).

## Quick start

```bash
# Export AVCs (or use policy_out/avc.log)
bash scripts/dev_generate_policy.sh --skip-export --engine deterministic

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

Without ifgen, the generator still classifies denials and emits **direct** / **fc_fix** / **fc_drift** / **private_port** rules. Base-type allows require sepolgen or **`--allow-degraded`** (recorded as `engine=degraded` in `findings.json`).

## Fast compiles (Podman)

```bash
bash scripts/build_selinux_compile_image.sh
export SELINUX_BUILD_IMAGE=selinux-demo/selinux-build:stream9
```

Subsequent `compile_and_validate.sh` / `--enforce-check` runs use the cached image instead of `dnf install` on every invocation.

## House rules (see `cli/policy_rules.py`)

| Verdict | Meaning |
|---------|---------|
| `fc_fix` | Path under manifest dirs but **no** matching `.fc` regex yet → add directory/file pattern + `restorecon` |
| `fc_drift` | Path already covered by an existing `.fc` regex but wrong label on disk → **`restorecon` only** (no new `.fc` line) |
| `private_port` | `name_bind` on shared port type → app `_port_t` |
| `forbidden` | Refused (`shadow_t`, etc.) — same spirit as CI forbidden patterns |
| `baseline` | Already in existing `.te` |
| `interface` | sepolgen refpolicy macro (when ifgen data present) |
| `direct` | Module-private types / fallback allow |

## Verification

After generation, `dev_generate_policy.sh` runs:

```bash
python3 cli/verify_avc_coverage.py --avc-log policy_out/avc.log \
  --te policy_out/myapp.te --manifest config/myapp.manifest.yml
```

Labeling fixes (`fc_fix`, `fc_drift`) are satisfied via `findings.json`, not allow rules. Shared logic: **`cli/fc_labeling.py`** (also strips redundant lines from LLM `.fc` output).

## Engines

| Command | Engine |
|---------|--------|
| `dev_generate_policy.sh` (default) | `cli/deterministic_gen.py` |
| `dev_generate_policy.sh --engine llm` | LLM (`cli/selinux_gen.py`) |

Fixtures: [`docs/examples/fixtures/deterministic/`](examples/fixtures/deterministic/).
