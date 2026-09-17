# Deterministic policy generation

Offline AVC → `.te` / `.fc` updates using **house rules** and optional **sepolgen** interface matching (same stack as `audit2allow -R`). This is the **default** engine in `dev_generate_policy.sh` (no `--engine` flag required).

**Who this is for:** policy authors who want **no API key** and reproducible verdicts (CI uses the same engine).

**Where commands run:** `--explain` and fixture tests work at **repo root** on any OS. Full `dev_generate_policy.sh` with AVC export runs on the **RHEL dev** box ([RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md)). `sepolgen-ifgen` needs RHEL/Stream with policy devel packages.

**Doc index:** [README.md](../README.md).

Before refpolicy interfaces or raw allows on base types, the generator applies **`config/boolean_hints.yml`** overrides (optional `src_type` / `{domain}` templates), then queries the loaded targeted policy with `sesearch --allow --bool …` (`cli/boolean_hints.py`). All matching booleans are listed (sorted); none is auto-selected when several apply. Policy RPM/version is recorded in the `.te` header and `pr_summary.md`. If neither override nor policy query can run, generation refuses a silent direct allow.

Optional live check: **`bash scripts/run_boolean_query_integration.sh`** (skips when `sesearch` / targeted policy is unavailable).

## Quick start

| | |
|--|--|
| **Where** | **Repo root** |
| **Why** | Regenerate `policy_out/` from committed `selinux/` + a fixture or existing `avc.log` without calling an LLM |

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

| | |
|--|--|
| **Where** | RHEL / CentOS Stream **VM or server** with `sudo` — not macOS |
| **Why** | Builds `/var/lib/sepolgen/interface_info` so the generator can suggest refpolicy **interface** macros instead of raw allows |

```bash
sudo dnf install -y policycoreutils-devel setools-console
sudo sepolgen-ifgen
# → /var/lib/sepolgen/interface_info
```

Without ifgen, the generator prints a **stderr banner** on every run (`SEPOLGEN INTERFACE MATCHING IS NOT AVAILABLE`) and still classifies **direct** / **fc_fix** / **fc_drift** / **private_port** rules. Base-type allows require sepolgen or explicit **`--allow-degraded`** (extra degraded banner; `engine=degraded` in `findings.json`). Exit code **1** when blockers remain (`forbidden`, `toolchain_required`) unless you only used `--explain`.

Do not confuse missing ifgen with “no interface matched” — the latter is logged when ifgen data exists but no macro fits the denial.

## Compile on RHEL

| | |
|--|--|
| **Where** | **rhel-dev** (or any host with `selinux-policy-devel`) |
| **Why** | `checkmodule` / refpolicy Makefile need the devel package — not macOS |

```bash
sudo dnf install -y selinux-policy-devel setools-console
bash scripts/compile_and_validate.sh selinux
```

`dev_generate_policy.sh`, `compile_and_validate.sh`, `validate_policy_semantics.sh`, and blast-radius classification use the same native Makefile path.

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
| `boolean` | Curated YAML override **then** `sesearch --allow --bool …` on loaded policy → **`setsebool -P … on`** (see `host_admin_actions`; policy identity in header / `findings.json`) |

## Verification

After generation, `dev_generate_policy.sh` runs:

```bash
python3 cli/verify_avc_coverage.py --avc-log policy_out/avc.log \
  --te policy_out/myapp.te --manifest config/myapp.manifest.yml
```

Labeling fixes (`fc_fix`, `fc_drift`) are satisfied via `findings.json`, not allow rules. Shared logic: **`cli/fc_labeling.py`** (also strips redundant lines from LLM `.fc` output).

`findings.json` is an object: `sepolgen_status`, `sepolgen_detail`, `generation_blocked`, and `findings` (array of classified rows). Refusal cases (`forbidden`, `toolchain_required`) still write **`findings.json`** with `generation_blocked: true` before exit 1. Older list-only files still work in `verify_avc_coverage.py`.

Golden fixtures: **`bash scripts/run_deterministic_fixtures.sh`** (`make test-fixtures`). `pr_summary.md` includes a **Classification audit (engine)** table for reviewers.

## Engines

| Command | Engine |
|---------|--------|
| `dev_generate_policy.sh` (default) | `cli/deterministic_gen.py` |
| `dev_generate_policy.sh --llm-summary` | above + `cli/summarize_pr.py` (narrative only) |
| Legacy | `cli/selinux_gen.py --legacy-full-policy` (deprecated) |

Fixtures: [`docs/examples/fixtures/deterministic/`](../examples/fixtures/deterministic/) — contiguous **`01`–`11`** AVC directories; **every classification verdict** has at least one golden row (`avc.log` + `expected.json`). Run **`make test-fixtures`**. Cases `08`/`09` use optional `sepolgen_mock.json` so hosts without ifgen still pass. Boolean coverage: `04-boolean-network-connect` and `10-boolean-hint`.

## After merge (not this CLI)

Deterministic generation stops at a reviewed PR. Production install is **Ansible Automation Platform (AAP)** ([ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md), objects in [`ansible/aap/`](../../ansible/aap/)): canary → `soak_monitor.yml` (net-new vs installed policy) → enforce. A denial after ship is a **new PR**, not a live host patch ([DENIAL_RESPONSE.md](../admin/DENIAL_RESPONSE.md)). Compile/RPM from CLI: `bash scripts/compile_and_validate.sh` and [`packaging/build_rpms.sh`](../../packaging/build_rpms.sh).
