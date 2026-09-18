# 204 — Deterministic policy

Offline AVC → `.te` / `.fc` updates using **house rules** and optional **sepolgen** interface matching (same stack as `audit2allow -R`). This is the **default** engine in `dev_generate_policy.sh` (no `--engine` flag required).

**Who this is for:** policy authors who want **no API key** and reproducible verdicts (CI uses the same engine).

**Where commands run:** `--explain` and fixture tests work at **repo root** on any OS. Full `dev_generate_policy.sh` with AVC export runs on the **RHEL dev** box ([203-RHEL_TWO_HOST.md](../admin/203-RHEL_TWO_HOST.md)). `sepolgen-ifgen` needs RHEL/Stream with policy devel packages.

**Doc index:** [README.md](../README.md).

Before refpolicy interfaces or raw allows on base types, the generator applies **`config/boolean_hints.yml`** overrides (optional `src_type` / `{domain}` templates), then queries the loaded targeted policy with `sesearch --allow --bool …` (`cli/boolean_hints.py`). All matching booleans are listed (sorted); none is auto-selected when several apply. Policy RPM/version is recorded in the `.te` header and `pr_summary.md`. If neither override nor policy query can run, generation refuses a silent direct allow.

Optional live check: **`bash scripts/run_boolean_query_integration.sh`** (skips when `sesearch` / targeted policy is unavailable).

## Vendor policy pre-flight

`dev_generate_policy.sh` calls `check_vendor_policy()` **before** AVC export or generation. Red Hat already ships policy for JWS (Tomcat), EAP/JBoss, httpd, named, and postgresql. Node.js and Spring Boot typically do not have a vendor module — those proceed.

JWS/EAP SELinux lives in a **separate RPM** (`jws6-tomcat-selinux`, `eap7-selinux` / `eap8-selinux`) that is **not** installed by default. Until it is, Tomcat runs `unconfined_java_t`. An empty `semodule -l` is not proof that no vendor policy exists.

The pre-flight classifies the app into **six situations**. Only `none` proceeds to generation.

| Situation | `action` | Generator | What you do |
|-----------|----------|-----------|-------------|
| `loaded` | `tune` | Exit non-zero | Vendor module is in `semodule -l` (JWS, Tomcat, EAP, …). Re-run with **`--tune-report`** for `semanage fcontext` / `setsebool` / `semanage port` commands. Do **not** generate a duplicate. |
| `package_installed` | `enable` | Exit non-zero | Vendor SELinux RPM is installed but the module is not loaded. Enable/install it; do not generate. |
| `package_available` | `install` | Exit non-zero | Vendor RPM is in the local dnf cache (`jws6-tomcat-selinux`, `eap*-selinux`, …). `dnf install` that package; do not generate. |
| `unconfined` | `install` | Exit non-zero | Process is `unconfined_java_t` / `unconfined_service_t`. Vendor policy exists and is not enabled. |
| `base_policy` | `tune` | Exit non-zero | `httpd` / `named` / `postgresql` covered by `selinux-policy-targeted`. **`--tune-report`** for host commands. Do not generate. |
| `none` | `generate` | Continues | No vendor/base module covers this app (typical for Node / Spring Boot / `shopapi`). |
| `semodule` and `rpm` both missing (laptop) | skip | One skip line, continues | Offline fixtures / `make check` stay green. |

`--tune-report` is read-only: it classifies denials for the **vendor** domain, prints the host commands, writes `policy_out/tune_report.md`, and never writes a `.te`. `direct` / `interface` denials land in a “not resolvable by tuning” section (possible vendor policy gap). On a host with no SELinux tooling it prints a skip notice and exits 0.

`--force "reason"` bypasses the check when the app **genuinely differs** from the vendor one. Bare `--force` is rejected. The reason, overridden situation, and bypassed module/package are recorded in `policy_out/findings.json` (`vendor_override`), `pr_summary.md`, and the PR body (higher-scrutiny banner). There is no network call (local `semodule -l`, `rpm -qa`, `dnf --cacheonly` only).

Admin commands: [302-PRODUCTION_READINESS.md §2.5](../admin/302-PRODUCTION_READINESS.md).

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

Without ifgen, the generator prints a **stderr banner** on every run (`SEPOLGEN INTERFACE MATCHING IS NOT AVAILABLE`) and still classifies **direct** / **fc_fix** / **fc_drift** / **private_port** rules. Base-type allows require sepolgen or explicit **`--allow-degraded`** (extra degraded banner; `engine=degraded` in `findings.json`). Exit code **1** when blockers remain (`forbidden`, `toolchain_required`, `needs_review` without `--allow-needs-review`) unless you only used `--explain`.

Do not confuse missing ifgen with “no interface matched” — the latter is logged when ifgen data exists but no macro fits the denial.

## Compile on RHEL

| | |
|--|--|
| **Where** | **rhel-qa** (or any host with `selinux-policy-devel`) |
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
| `baseline` | Already covered in existing `.te` or baseline macro (e.g. `dev_read_urand` for `random_device_t`). Also **omits** `cgroup_t` filesystem getattr (JVM cgroupfs telemetry) — that type is often undeclared in targeted policy, so a raw allow fails compile. |
| `interface` | sepolgen refpolicy macro (when ifgen data present) |
| `direct` | Module-private types, or sepolgen ran but no macro matched (manual review) |
| `toolchain_required` | Base-type denial with no sepolgen and no `--allow-degraded` — generation blocked |
| `boolean` | Curated YAML override **then** `sesearch --allow --bool …` on loaded policy → **`setsebool -P … on`** (see `host_admin_actions`; policy identity in header / `findings.json`) |
| `needs_review` | Legitimate but domain-weakening (`execmem`, `dac_override`, foreign `process transition`, …). Recorded in findings / `pr_summary.md`; **not** written to the `.te` unless `--allow-needs-review` |

## Verification

After generation, `dev_generate_policy.sh` runs:

```bash
python3 cli/verify_avc_coverage.py --avc-log policy_out/avc.log \
  --te policy_out/myapp.te --manifest config/myapp.manifest.yml
```

Labeling fixes (`fc_fix`, `fc_drift`) are satisfied via `findings.json`, not allow rules. Shared logic: **`cli/fc_labeling.py`** (also strips redundant lines from LLM `.fc` output).

`findings.json` is an object: `sepolgen_status`, `sepolgen_detail`, `generation_blocked`, and `findings` (array of classified rows). Refusal cases (`forbidden`, `toolchain_required`, `needs_review` without `--allow-needs-review`) still write **`findings.json`** and **`pr_summary.md`** with `generation_blocked: true` before exit 1. Older list-only files still work in `verify_avc_coverage.py`.

Golden fixtures: **`bash scripts/run_deterministic_fixtures.sh`** (`make test-fixtures`). `pr_summary.md` includes a **Classification audit (engine)** table for reviewers.

## Engines

| Command | Engine |
|---------|--------|
| `dev_generate_policy.sh` (default) | `cli/deterministic_gen.py` |
| `dev_generate_policy.sh --llm-summary` | above + `cli/summarize_pr.py` (narrative only) |
| Legacy | `cli/selinux_gen.py --legacy-full-policy` (deprecated) |

Fixtures: [`docs/examples/fixtures/deterministic/`](../examples/fixtures/deterministic/) — contiguous **`01`–`13`** AVC directories; **every classification verdict** has at least one golden row (`avc.log` + `expected.json`). Run **`make test-fixtures`**. Cases `08`/`09` use optional `sepolgen_mock.json` so hosts without ifgen still pass. Boolean coverage: `04-boolean-network-connect` and `10-boolean-hint`. `needs_review`: `12-execmem-review`. `cgroup_t` omit: `13-cgroup-omit`.

## After merge (not this CLI)

Deterministic generation stops at a reviewed PR. Production install is **Ansible Automation Platform (AAP)** ([301-ANSIBLE_OPERATIONS.md](../admin/301-ANSIBLE_OPERATIONS.md), objects in [`ansible/aap/`](../../ansible/aap/)): canary → `soak_monitor.yml` (net-new vs installed policy) → enforce. A denial after ship is a **new PR**, not a live host patch ([303-DENIAL_RESPONSE.md](../admin/303-DENIAL_RESPONSE.md)). Compile/RPM from CLI: `bash scripts/compile_and_validate.sh` and [`packaging/build_rpms.sh`](../../packaging/build_rpms.sh).
