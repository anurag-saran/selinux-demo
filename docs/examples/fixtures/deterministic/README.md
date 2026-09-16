# Deterministic generator fixtures

Each directory has `avc.log` + `expected.json` (golden `verdict` / `tgt` rows). Optional:

- **`case.meta.json`** — `exit_code` (default 0), `stderr_substrings` for blocked runs
- **`sepolgen_mock.json`** — in-process mock for CI hosts without `sepolgen-ifgen` (`behavior`: `match` | `no_match`)

**Where to run:** **repo root** on any OS (no SELinux required). Full suite: `make test-fixtures` or `bash scripts/run_deterministic_fixtures.sh`.

**Why:** CI compares generator output to `expected.json` so verdict logic cannot drift silently.

CI runs all cases via **`bash scripts/run_deterministic_fixtures.sh`** (and `smoke_test.py` in **`smoke-tests`**). Job: **`deterministic-fixtures`**.

| Case | Verdict exercised |
|------|-------------------|
| `01-mislabeled-var-lib` | **`fc_drift`** — path already covered by `/var/lib/myapp(/.*)?`; fix is `restorecon` |
| `02-port-bind` | **`private_port`** — `name_bind` on generic port type |
| `03-shadow-read` | **`forbidden`** — refuses `shadow_t` (exit 1) |
| `04-boolean-network-connect` | **`boolean`** — policy query path (sesearch mock; empty curated hints) |
| `11-private-getopt` | **`direct`** — module-private `myapp_port_t` |
| `05-baseline-covered` | **`baseline`** — `dev_read_urand` macro covers `random_device_t` (no explicit allow line) |
| `06-fc-missing-line` | **`fc_fix`** — app path under `install_root` with no matching `.fc` regex yet |
| `07-toolchain-required` | **`toolchain_required`** — base-type allow blocked without sepolgen (exit 1) |
| `08-interface-match` | **`interface`** — mocked refpolicy macro (`sepolgen_mock.json`) |
| `09-direct-no-interface` | **`direct`** — sepolgen ran but no macro matched (`no_match` mock) |
| `10-boolean-hint` | **`boolean`** — curated override in `config/boolean_hints.yml` (offline; no live policy) |

Run classification without writing policy:

| | |
|--|--|
| **Where** | **Repo root** |
| **Why** | Learn one verdict (`fc_drift`, `boolean`, etc.) without running staging |

```bash
python3 cli/deterministic_gen.py --explain \
  --avc-log docs/examples/fixtures/deterministic/01-mislabeled-var-lib/avc.log \
  --manifest config/myapp.manifest.yml \
  --existing-te selinux/myapp.te \
  --existing-fc selinux/myapp.fc
```

On RHEL dev hosts, run once: **`sepolgen-ifgen`** (requires `policycoreutils-devel`) so live interface matching works. Without it, every generator run prints a **stderr banner** (`SEPOLGEN INTERFACE MATCHING IS NOT AVAILABLE`); base-type AVCs exit **1** unless you pass **`--allow-degraded`** (extra degraded banner; `engine=degraded` in `findings.json`).

**Fast compiles:** pull **`docker.io/asaran/selinux-demo-selinux-build:stream9`** from Docker Hub (published). See [DOCKER_HUB_COMPILE_IMAGE.md](../../../DOCKER_HUB_COMPILE_IMAGE.md).
