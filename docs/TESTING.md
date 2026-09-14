# Testing Guide

This document is the **single reference** for how this repository tests SELinux policy — from developer laptop checks through production enforce gates.

| You are… | Start here | Then |
|----------|------------|------|
| **App developer** | §1 Integration endpoints | §1.5 App manifest, §2 Local smoke tests |
| **Policy author opening a PR** | §4 CI on pull requests | §5 Shell gate scripts |
| **Admin / SRE** | §6 Staging and production gates | [`ansible/README.md`](../ansible/README.md), [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md) |

Related: endpoint SELinux concepts in [`SELINUX_BASICS.md`](SELINUX_BASICS.md) §9; workshop flow in [`DEMO_GUIDE.md`](DEMO_GUIDE.md) Acts 1–10.

---

## 1. Integration endpoints (the core test suite)

The Flask app exposes **six HTTP endpoints** on port **8888**. Each endpoint is a deliberate probe of one SELinux permission surface. They are exercised by:

- Developers during staging (`curl`, Act 1 in the demo)
- [`scripts/wait_for_endpoints.sh`](../scripts/wait_for_endpoints.sh) (canary, enforce, rollback)
- [`scripts/smoke_test.py`](../scripts/smoke_test.py) (`test_flask_endpoints`)
- [`scripts/run_demo.sh`](../scripts/run_demo.sh)

**Requires:** `myapp-backend.service` running for `/probe-backend` and `/notify-socket` (Tier 6).

| Endpoint | SELinux surface | Primary types / rules | Typical failure without policy |
|----------|-----------------|----------------------|--------------------------------|
| `GET /` | TCP bind + listen on **8888** | `myapp_port_t`, `corenet_tcp_bind_generic_node` | `name_bind` denial on port |
| `GET /save-log` | Append to **`/var/log/myapp/data.log`** | `myapp_log_t`, `logging_log_filetrans`, path traversal | write to wrong log type or missing `search` on path |
| `GET /run-script` | Execute **`/opt/myapp/bin/backup.sh`** | `myapp_script_exec_t`, `execute_no_trans` | exec on unlabeled script or `bin_t` if script calls `/usr/bin/*` |
| `GET /rotate-log` | Rename + create log files | `myapp_log_t` rename/create | logrotate-style deny under enforce |
| `GET /probe-backend` | Outbound TCP to **127.0.0.1:8889** | `myapp_backend_port_t` `name_connect`, `getopt` on `self:tcp_socket` | client connect denial |
| `GET /notify-socket` | Unix stream to **`/run/myapp/notify.sock`** | `myapp_backend_t` `connectto`, `myapp_var_run_t` | socket path or `/run` sandbox deny |

**Design constraints baked into the app:**

- `backup.sh` uses **bash builtins only** — CI forbids `allow … bin_t:file execute`.
- App listens on **8888** (non-default) — forces dedicated port type, not blanket `unreserved_port_t`.
- Services start via **systemd** — domain transition matches production (`init_daemon_domain`).

**Manual run (staging host):**

```bash
for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do
  curl -sf "http://127.0.0.1:8888${path}" | head -c 120
  echo
done
curl -sf http://127.0.0.1:8889/health
```

---

## 1.5 App manifest (onboarding new apps)

The demo’s six endpoints are **myapp-specific**. For a new application, copy [`config/payments.manifest.example.yml`](../config/payments.manifest.example.yml) to `config/<app_name>.manifest.yml` and declare paths, systemd units, HTTP probes, and SELinux domains. See [`config/README.md`](../config/README.md) for the full schema.

**Validate locally / in CI:**

```bash
bash scripts/validate_app_manifest.sh config/myapp.manifest.yml
python3 scripts/lib/app_manifest.py shell-export config/myapp.manifest.yml
```

**Consumers:** `wait_for_endpoints.sh`, `post_deploy_report.sh`, and `check_soak_ready.sh` accept `--manifest PATH` (or `APP_MANIFEST`). Ansible passes `app_manifest_path` from inventory. When no manifest is present, scripts fall back to built-in myapp defaults.

**Production model:** keep real integration tests under permissive (`integration_tests.command` in the manifest); use manifest HTTP probes for deploy/canary smoke only — do not auto-generate business-logic tests from policy.

---

## 2. `scripts/smoke_test.py` (CI: `smoke-tests`)

Runs on **every PR** on Ubuntu — **no SELinux required** for most tests.

```bash
python3 scripts/smoke_test.py              # default: backend required for flask test
python3 scripts/smoke_test.py --no-require-backend   # skip Tier 6 backend in flask test
SMOKE_REQUIRE_BACKEND=0 python3 scripts/smoke_test.py
```

| Test name | What it verifies |
|-----------|------------------|
| `prompts` | AI user prompt includes domain, existing `.te`, AVC summary structure |
| `avc_parsing` | `parse_avc_line`, dedup, domain filter |
| `perm_merge` | Duplicate AVC lines merge permissions on same src/tgt/class |
| `type_extraction_dedup` | `system_r` vs `object_r` in scontext normalize to same type |
| `subtract_existing` | Net-new detection skips permissions already in `.te` |
| `net_new_detection` | Partial overlap — only missing perms flagged net-new |
| `preprocess_stats` | Raw vs merged AVC counts for LLM input |
| `prompt_uses_summary` | Prompt contains Net-new / Already covered sections |
| `no_changes_needed_summary` | Fully covered AVCs produce no-change summary |
| `policy_json_validation` | AI JSON shape, forbidden patterns, PR summary headings |
| `version_bump` | SemVer bump in `policy_version.txt` |
| `flask_endpoints` | All six HTTP paths return 200 (`ok` in body); rewrites paths to temp dirs |
| `assemble_pr_body` | `assemble_pr_body.sh` fills PR template placeholders |
| `verify_file_contexts_skip` | `--skip-if-unavailable` exits 0 without SELinux tools |
| `check_soak_ready_gate` | Soak script fails on missing/recent marker, passes on 8-day-old marker |
| `monitor_avc_skip` | `monitor_avc.sh --skip-if-unavailable` exits 0 |
| `demo_present_help` | Demo presenter script `--help` works |
| `app_manifest` | Validates demo + example manifests; `shell-export` emits expected keys |

---

## 3. Developer local checks (before PR)

| Step | Command | Needs SELinux host? |
|------|---------|---------------------|
| CLI + flask smoke | `python3 scripts/smoke_test.py` | No |
| Forbidden patterns | `bash scripts/validate_forbidden_patterns.sh selinux` | No |
| Compile | `bash scripts/compile_and_validate.sh selinux` | Podman or RHEL devel |
| Semantic assertions | `bash scripts/validate_policy_semantics.sh selinux` | Podman |
| Staging + AVC export | `sudo bash scripts/setup_staging_env.sh` + curl endpoints | Yes |
| AI generate | `bash scripts/dev_generate_policy.sh --use-vm --apply` | Yes (or `--use-vm`) |
| **Enforce-check** | `bash scripts/dev_generate_policy.sh --apply --enforce-check` | Yes (root or `--use-vm`) |

**`--enforce-check`** compiles the candidate `.pp`, removes permissive on `myapp_t`, runs `wait_for_endpoints.sh` (including domain-context verification), and prints recent AVCs on failure.

---

## 4. CI on pull requests

Workflow: [`.github/workflows/selinux-policy-ci.yml`](../.github/workflows/selinux-policy-ci.yml)

| Job | Script / action | Pass criteria |
|-----|-----------------|---------------|
| `smoke-tests` | `python3 scripts/smoke_test.py` | All smoke tests pass (incl. deterministic fixtures) |
| `app-manifest` | `scripts/validate_app_manifest.sh` | Demo + onboarding example manifests validate |
| `forbidden-patterns` | `scripts/validate_forbidden_patterns.sh selinux` | No wildcards, shadow_t, bin_t execute, etc. |
| `shellcheck` | `shellcheck scripts/*.sh scripts/lib/*.sh` | No shellcheck errors |
| `yamllint` | `yamllint ansible/ .github/workflows/` | YAML style clean |
| `compile-policy` | `scripts/compile_and_validate.sh selinux` | `.pp` builds on CentOS Stream 9; artifact uploaded |
| `ansible-lint` | `ansible-lint ansible/*.yml` | Playbooks lint clean |
| `policy-semantics` | `scripts/validate_policy_semantics.sh selinux` | No shadow/unlabeled/foreign entrypoint (container `--direct` sesearch) |

Compiled `selinux/myapp.pp` is a **CI artifact only** — not committed to Git.

---

## 5. Shell gate scripts (staging / production)

These run on **SELinux hosts** (Ansible playbooks call them; admins can run manually).

| Script | When | Pass criteria |
|--------|------|---------------|
| [`verify_file_contexts.sh`](../scripts/verify_file_contexts.sh) | Before service restart after `semodule -i` | `matchpathcon -V`; `restorecon -Rv -n` shows no changes under data/log paths |
| [`wait_for_endpoints.sh`](../scripts/wait_for_endpoints.sh) | After canary / enforce / rollback restart | systemd active; **MainPID domain** matches manifest; HTTP probes from manifest (demo: six paths + backend health) |
| [`monitor_avc.sh`](../scripts/monitor_avc.sh) | Daily during soak; canary post-deploy window | Domain AVC count ≤ threshold (default **0**) |
| [`check_soak_ready.sh`](../scripts/check_soak_ready.sh) | Manual pre-enforce check on host (Ansible uses **`collect_soak_facts.sh`**) | Marker age ≥ min days; AVC count ≤ max; deploy report pass + **domain_context_verified** |
| [`post_deploy_report.sh`](../scripts/post_deploy_report.sh) | End of canary / enforce / rollback | Writes deploy report JSON (path from manifest or default) |
| [`validate_app_manifest.sh`](../scripts/validate_app_manifest.sh) | CI / onboarding | YAML schema + required fields |
| [`classify_policy_blast_radius.sh`](../scripts/classify_policy_blast_radius.sh) | Controller-only blast radius (`sediff`) | 1 / 3 / 7 day recommendation (not wired to enforce `--auto-tier`) |

**Exit codes for `wait_for_endpoints.sh`:** `0` pass; `1` systemd; `2` HTTP; `4` domain mismatch.

---

## 6. Staging and production gates

### Merge to `main` (automatic)

Workflow: [`.github/workflows/selinux-staging-canary.yml`](../.github/workflows/selinux-staging-canary.yml)

1. **`staging-canary`** — compile + `ansible/deploy_canary.yml` on self-hosted `selinux-staging` runner
2. **`staging-endpoint-smoke`** — `wait_for_endpoints.sh` + deploy report exists

### Production (manual — admin)

Workflow: [`.github/workflows/selinux-deploy.yml`](../.github/workflows/selinux-deploy.yml) or manual `ansible-playbook`.

| Phase | Playbook | Key tests embedded |
|-------|----------|-------------------|
| Canary | `deploy_canary.yml` | `verify_file_contexts`, `wait_for_endpoints`, `monitor_avc` (recent window), deploy report |
| Soak | *(manual)* | Daily `monitor_avc.sh`; optional manual `check_soak_ready.sh` on host |
| Enforce | `enforce_production.yml` | `collect_soak_facts.sh`, `semodule -B`, enforce domain, `wait_for_endpoints`, deploy report |
| Rollback | `emergency_rollback.yml` | permissive relief, `wait_for_endpoints`, deploy report, AVC export |

Full Ansible task order and variables: [`ansible/README.md`](../ansible/README.md).

Admin runbook with pass/fail examples: [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md) §5–12.

---

## 7. Test layer summary

```text
Layer 1  smoke_test.py + forbidden-patterns     PR / laptop (no SELinux)
Layer 2  compile + policy-semantics + ansible-lint   PR (Podman)
Layer 3  six HTTP endpoints + AVC export      staging discovery (permissive)
Layer 4  deploy_canary + wait_for_endpoints   staging/prod canary host
Layer 5  monitor_avc + check_soak_ready       soak period
Layer 6  enforce_production + wait_for_endpoints   production cutover
Layer 7  emergency_rollback                   outage response
```

---

## 8. What is *not* tested automatically

| Gap | Mitigation |
|-----|------------|
| Real **logrotate** cron as `logrotate_t` | Run system logrotate on staging during soak; `.fc` + `create` in `app/logrotate.d/myapp` |
| **RPM upgrade** relabel path | Test `packaging/myapp-selinux.spec` on a throwaway VM |
| Fleet-wide **serial enforce** | `enforce_production.yml` uses `serial: 1` — test on canary host first |
| AVC **classification** under `semodule -DB` (noise vs real) | Manual review; future gate — see [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md) |
