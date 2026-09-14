# SELinux Policy-as-Code — Best Practices

This guide captures **design principles and anti-patterns** enforced in this repository after production-readiness review. It answers: *what does “correct” look like here, and why?*

| You are… | Read this for… | Then use… |
|----------|----------------|-----------|
| **Policy author / app developer** | How to write `.te`/`.fc` and pass CI | [README.md](../README.md), [DETERMINISTIC_POLICY.md](DETERMINISTIC_POLICY.md), [cli/prompt_templates.py](../cli/prompt_templates.py) |
| **Security / admin reviewer** | PR review checklist and gates | [PR template](../.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md), §Review checklist below |
| **RHEL admin running deploy** | Step-by-step rollout | [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md), [ansible/README.md](../ansible/README.md) |
| **Testing / CI author** | Endpoint matrix, smoke tests, gates | [TESTING.md](TESTING.md) |
| **New to SELinux concepts** | Labels, soak, permissive domains | [SELINUX_BASICS.md](SELINUX_BASICS.md) |

Current module version: read **`selinux/policy_version.txt`** (SemVer). Keep the `policy_module(myapp, …)` line in **`selinux/myapp.te`** in sync — CI job **`version-consistency`** fails on drift. Do not duplicate the version in Ansible inventory or the RPM spec (spec uses `Version: %{modver}` from `build_rpms.sh`).

---

## 1. Policy authoring

### Do

| Practice | Why | In this repo |
|----------|-----|--------------|
| Use **refpolicy interfaces** | Survives base-policy churn; reviewers recognize intent | `logging_send_syslog_msg`, `corecmd_exec_shell`, `files_search_*`, `logging_log_filetrans`, `init_daemon_run_dir`, `init_daemon_domain` |
| Declare **dedicated port types** | Least privilege — not every unreserved port | `myapp_port_t` (8888), `myapp_backend_port_t` (8889) + `semanage port` in canary/RPM `%post` |
| Use **dedicated log type** | logrotate and app writes without over-broad `var_lib_t` | `myapp_log_t` under `/var/log/myapp`; systemd `LogsDirectory=myapp` |
| **Daemon baseline block** | Explicit once-reviewed allows every Python service needs | `files_read_etc_files`, `sysnet_read_config`, `kernel_read_system_state`, `dev_read_urand` |
| TCP client to backend | Correct permission class | `allow myapp_t myapp_backend_port_t:tcp_socket name_connect` |
| Unix socket to backend | Peer connection | `allow myapp_t myapp_backend_t:unix_stream_socket connectto` |
| `policy_module()` syntax | Required for refpolicy Makefile compile | Top of every `.te` |
| Incremental allows from AVCs | Least privilege | AI prompt: net-new rows only |

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| Raw `allow myapp_t syslogd_t:unix_stream_socket connectto` | Incomplete vs `logging_send_syslog_msg`; misses `devlog_t` / dgram paths |
| `allow myapp_t unreserved_port_t:tcp_socket name_bind` | Binds **any** high port — not just 8888 |
| `allow myapp_t myapp_backend_t:tcp_socket connectto` | **`connectto` is not valid on `tcp_socket`** — use `name_connect` to port type |
| `allow myapp_t *:*` or `self:*` | CI forbidden; unbounded blast radius |
| `allow … bin_t:file execute` | CI forbidden; label app binaries with dedicated exec types |
| `audit2allow` output pasted verbatim | Wildcards, wrong classes, no interfaces |
| `domain_auto_trans(myapp_t, script_t, myapp_t)` | Self-transition no-op; use `execute_no_trans` or separate helper domain |

**Compile rule:** build with the refpolicy devel **Makefile**, not raw `checkmodule` on macro `.te` files:

```bash
bash scripts/lib/selinux_build_image.sh ensure   # pull-first UBI 9 compile image
bash scripts/compile_and_validate.sh selinux
# Uses scripts/lib/compile_policy.sh → make -f /usr/share/selinux/devel/Makefile
```

Build target OS: **RHEL 9 / UBI 9** ([`DOCKER_HUB_COMPILE_IMAGE.md`](DOCKER_HUB_COMPILE_IMAGE.md)). Default image: `docker.io/asaran/selinux-demo-selinux-build:ubi9`.

---

## 2. File labeling (`.fc`)

### Do

| Practice | Example |
|----------|---------|
| FHS data path | `/var/lib/myapp(/.*)?` → `myapp_var_lib_t` |
| FHS log path | `/var/log/myapp(/.*)?` → `myapp_log_t` |
| FHS runtime socket | `/run/myapp(/.*)?` → `myapp_var_run_t` (`files_pid_file`) |
| Narrow venv entrypoint | `/opt/myapp/venv/bin/python[0-9.]*` → `myapp_exec_t`; rest → `myapp_lib_t` |
| Directory patterns **without** `--` | `--` means regular file only — breaks dir/socket labeling |
| `restorecon` after install | Labels persist across relabel; survives policy upgrade |

```bash
restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp
bash scripts/verify_file_contexts.sh --log-dir /var/log/myapp   # uses matchpathcon -V
```

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| `chcon` in playbooks or setup scripts | Lost on `restorecon`, relabel, or `/.autorelabel` boot |
| Entire venv as `myapp_exec_t` | Every `.so` becomes entrypoint-capable |
| Data under non-FHS `/var/myapp` | Harder to relabel; non-standard for RHEL admins |
| Skipping venv in verify | Misses mislabeled Python entrypoint |

**systemd:** `StateDirectory=myapp`, `LogsDirectory=myapp`, and `RuntimeDirectory=myapp` create `/var/lib/myapp`, `/var/log/myapp`, and `/run/myapp` with correct ownership before the app starts. App unit `ReadWritePaths` must include `/run/myapp` when `ProtectSystem=strict` is set.

---

## 3. Build, CI, and PR review

### Layered gates

```text
1. grep forbidden patterns     →  validate_forbidden_patterns.sh (fast pre-filter)
2. version SSOT                →  validate_version_consistency.sh (`version-consistency`)
3. refpolicy Makefile compile  →  compile-policy job (artifact upload)
4. semantic sesearch checks    →  validate_policy_semantics.sh (what policy *means*)
5. blast-radius fixtures       →  run_blast_radius_fixtures.sh (`blast-radius`)
6. PR policy access delta      →  policy_module_diff.sh + `policy-diff-comment` on PRs
7. staging canary + smoke      →  selinux-staging-canary.yml
8. ansible-lint                  →  pinned collection versions
```

### Do

| Practice | Script / job |
|----------|--------------|
| Rebuild `.pp` from `.te`/`.fc` in CI | `compile-policy` |
| CI builds `.pp` as artifact only | `compile-policy` job upload (not committed) |
| Assert no shadow/unlabeled/foreign entrypoint | `validate_policy_semantics.sh` (container-only; `--direct`) |
| Verify service runs in expected domain | `wait_for_endpoints.sh` domain-context check |
| Tier soak by blast radius | `classify_policy_blast_radius.sh` + fixtures in [`tests/fixtures/blast_radius/`](../tests/fixtures/blast_radius/) (CI **`blast-radius`**); optional `check_soak_ready.sh --auto-tier` on controller (fail-closed) |
| Include policy access delta in PR body | `assemble_pr_body.sh` + `policy_module_diff.sh` (sesearch / merge-base; not `sediff` on `.pp`) |
| Lint shell and YAML | `shellcheck`, `yamllint`, `ansible-lint` in CI |

### Don’t

| Anti-pattern | Gap |
|--------------|-----|
| Grep-only security boundary | Misses `files_read_all_files()`, spaced colons, interface-expanded allows |
| Committing `.te` without recompiling `.pp` | Drift — invalid rules can hide in stale binary |
| Compiling on Fedora for RHEL deploy | Module version / libsepol mismatch at `semodule -i` |

---

## 4. Deploy and module lifecycle

### Do

| Practice | Where |
|----------|-------|
| **`semodule -i` in-place upgrade** | `deploy_canary.yml`, `apply_policy.sh` — no remove-then-install gap |
| **Per-domain permissive only** during soak | `semanage permissive -a myapp_t`; OS stays Enforcing |
| **`semodule -DB` at canary start** | Surfaces dontaudit-hidden denials during soak |
| **`semodule -B` on canary failure / rollback / before enforce** | Restores dontaudit baseline — host-wide change |
| Register ports at deploy | `community.general.seport` in canary playbook |
| Unified endpoint smoke | `wait_for_endpoints.sh` (6 HTTP paths + backend + **domain context**) |
| Deploy feedback JSON | `/var/lib/myapp/selinux_deploy_report.json` |
| Rollback via RPM | `dnf downgrade myapp-selinux-<version>` (`rollback_dnf_version` inventory var) |
| Enforce **block/rescue** | Auto-restore permissive if smoke fails mid-enforce |

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| `semodule -r` before every upgrade | Window where domain/types missing; running process contexts invalid |
| `setenforce 0` for app outages | Disables OS-wide protection — use `semanage permissive -a myapp_t` |
| `force_enforce=true` without approval | Skips soak gate |
| Manual `python app.py` for staging tests | Wrong domain transition vs systemd |
| Enforce without prior canary on host | `enforce_production.yml` assumes policy already installed |

**Packaging path (production-grade):** [`packaging/myapp-selinux.spec`](../packaging/myapp-selinux.spec) — RPM with `%selinux_modules_install`, relabel macros, port registration in `%post`.

---

## 5. Soak, monitoring, and enforce gates

### Do

| Practice | Detail |
|----------|--------|
| **7–14 day soak** after canary | Capture cron, logrotate, cert renewals |
| **`ausearch --input-logs --subject myapp_t`** | Counts rotated logs; filters by subject domain |
| Include **`SELINUX_ERR`** events | Not just `-m avc` — constraint / invalid context failures |
| Daily **`monitor_avc.sh --max-avc 0`** | During soak |
| **`check_soak_ready.sh`** before enforce | Soak days + event count + deploy report endpoint pass; optional **`--auto-tier`** with base/candidate policy paths |
| Canary AVC gate | `canary_max_avc: 0` default in `deploy_canary.yml` |
| Reset soak clock on policy change | New marker after redeploy or rollback |

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| Substring grep `myapp_t` in audit.log | False positives (`myapp_tmp_t`); misses multiline events |
| `ausearch` without `--input-logs` on 7-day soak | Rotated logs drop early denials → false “zero AVCs” |
| Zero AVCs without endpoint coverage | Low traffic ≠ safe policy — require deploy report pass |
| `ausearch -ts recent` for soak | ~10 minutes — fine post-canary only, not for soak gate |

---

## 6. Rollback and incident response

### Do

| Practice | Command / artifact |
|----------|-------------------|
| Immediate relief | `semanage permissive -a myapp_t` (via `emergency_rollback.yml`) |
| Version rollback | `-e rollback_dnf_version=1.1.1-1` on emergency rollback (`dnf downgrade myapp-selinux-*`) |
| Export AVCs after outage | `/tmp/emergency_avc.log` in rollback playbook |
| App team triage | [PRODUCTION_READINESS.md §12.5](PRODUCTION_READINESS.md) — health JSON, deploy report |
| Full recovery loop | permissive → policy PR → canary → soak → enforce |

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| Rollback | Permissive relief first; optional `dnf downgrade myapp-selinux-*` — not app-writable policy-history |
| Re-deploy app code alone | SELinux denial needs policy fix |
| Broad local `allow` rules | Bypasses review; reintroduces audit2allow anti-patterns |

---

## 7. AI policy generation

The CLI follows the same rules as hand-written policy. See [`cli/prompt_templates.py`](../cli/prompt_templates.py):

- Prefer refpolicy **interfaces** (embedded allowlist in system prompt)
- Ban raw syslog / `unreserved_port_t` / `bin_t` patterns
- FHS `.fc` template without `--` on directories
- Compile-retry on `policy_module()` / macro errors

**Human review is mandatory** — AI output passes CI but does not replace admin sign-off.

---

## 8. Review checklist (admins)

Use with the [PR template](../.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md):

- [ ] `.te` uses refpolicy interfaces, not audit2allow-style raw allows
- [ ] Port 8888 / 8889 use `myapp_port_t` / `myapp_backend_port_t`, not `unreserved_port_t`
- [ ] `.fc` uses FHS paths; no `--` on directory patterns; venv split exec/lib
- [ ] CI: `forbidden-patterns`, `compile-policy`, `policy-semantics`, `version-consistency`, `blast-radius`, `ansible-lint` pass
- [ ] Version bump: `selinux/policy_version.txt` and matching `policy_module(myapp, …)` in `.te` only (no duplicate version in spec/inventory)
- [ ] `verify_file_contexts.sh` passes after `restorecon` (includes `/var/log/myapp`)
- [ ] Canary plan: `semodule -DB`, endpoint smoke, **domain context** in deploy report, soak marker
- [ ] Enforce plan: `collect_soak_facts.sh` gate (or manual `check_soak_ready.sh`), `semodule -B`, block/rescue tested or briefed
- [ ] Developers can run `dev_generate_policy.sh --enforce-check` before opening PR
- [ ] Rollback owner knows `emergency_rollback.yml`, optional `rollback_dnf_version`, and `reset_host_state.yml` for interrupted canary

---

## 9. Related docs

| Guide | Role |
|-------|------|
| [TESTING.md](TESTING.md) | Endpoint probes, smoke_test.py, CI and deploy gates |
| [../ansible/README.md](../ansible/README.md) | Ansible playbook task order and variables |
| [SELINUX_BASICS.md](SELINUX_BASICS.md) | Concepts and beginner mistakes |
| [DEMO_GUIDE.md](DEMO_GUIDE.md) | Workshop acts 1–10 |
| [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) | Admin runbook — soak, canary, enforce, rollback |
| [README.md](../README.md) | Commands, CI, GitHub Actions |
