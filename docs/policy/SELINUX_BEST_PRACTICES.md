# SELinux PaC — Best Practices

This guide captures **design principles and anti-patterns** enforced in this repository after production-readiness review. It answers: *what does “correct” look like here, and why?*

| You are… | Read this for… | Then use… |
|----------|----------------|-----------|
| **Policy author / app developer** | How to write `.te`/`.fc` and pass CI | [README.md](../../README.md), [DETERMINISTIC_POLICY.md](../developers/DETERMINISTIC_POLICY.md), [cli/prompt_templates.py](../../cli/prompt_templates.py) |
| **Security / admin reviewer** | PR review checklist and gates | [PR template](../../.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md), §Review checklist below |
| **RHEL admin running deploy** | Step-by-step rollout | [ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md), [PRODUCTION_READINESS.md](../admin/PRODUCTION_READINESS.md), [ansible/README.md](../../ansible/README.md) |
| **Testing / CI author** | Endpoint matrix, smoke tests, gates | [TESTING.md](../developers/TESTING.md) |
| **New to SELinux concepts** | Labels, soak, permissive domains | [SELINUX_BASICS.md](SELINUX_BASICS.md) |

**Doc index and reading order:** [README.md](../README.md).

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
| Incremental allows from AVCs | Least privilege | Deterministic generator: net-new rows only (`findings.json`) |
| Use vendor/base policy when it exists | Duplicate `jws6_tomcat` / `jboss_t` / `httpd_t` is worse than no custom module | `check_vendor_policy()` in `dev_generate_policy.sh` refuses JWS, EAP, httpd, named, postgresql |

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| Generate a custom module for JWS/Tomcat, EAP/JBoss, or httpd | Vendor/base policy already confines these; install `jws6-tomcat-selinux` / `eap*-selinux` or tune booleans. The generator refuses unless `--force`. |
| Quietly add `allow … self:process execmem` (or `dac_override`) | Domain-weakening; generator classifies `needs_review` and exits until `--allow-needs-review` after confirming the AVC |
| Raw `allow myapp_t syslogd_t:unix_stream_socket connectto` | Incomplete vs `logging_send_syslog_msg`; misses `devlog_t` / dgram paths |
| `allow myapp_t unreserved_port_t:tcp_socket name_bind` | Binds **any** high port — not just 8888 |
| `allow myapp_t myapp_backend_t:tcp_socket connectto` | **`connectto` is not valid on `tcp_socket`** — use `name_connect` to port type |
| `allow myapp_t *:*` or `self:*` | CI forbidden; unbounded blast radius |
| `allow … bin_t:file execute` | CI forbidden; label app binaries with dedicated exec types |
| `audit2allow` output pasted verbatim | Wildcards, wrong classes, no interfaces |
| `domain_auto_trans(myapp_t, script_t, myapp_t)` | Self-transition no-op; use `execute_no_trans` or separate helper domain |

**Compile rule:** build with the refpolicy devel **Makefile**, not raw `checkmodule` on macro `.te` files:

```bash
bash scripts/compile_and_validate.sh selinux
# Uses scripts/lib/compile_policy.sh → make -f /usr/share/selinux/devel/Makefile
```

Build on **RHEL 9** with `selinux-policy-devel` (rhel-qa).

---

## 2. File labeling (`.fc`)

### Do

| Practice | Example |
|----------|---------|
| FHS data path | `/var/lib/myapp(/.*)?` → `myapp_var_lib_t` |
| FHS log path | `/var/log/myapp(/.*)?` → `myapp_log_t` |
| FHS runtime socket | `/run/myapp(/.*)?` **and** `/var/run/myapp(/.*)?` → `myapp_var_run_t` (RHEL `file_contexts.subs` maps `/run` → `/var/run`) |
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

**systemd:** `StateDirectory=myapp`, `LogsDirectory=myapp`, and `RuntimeDirectory=myapp` create `/var/lib/myapp`, `/var/log/myapp`, and `/run/myapp` with correct ownership before the app starts. App unit `ReadWritePaths` must include `/run/myapp` when `ProtectSystem=strict` is set. **`NoNewPrivileges=true` blocks SELinux `type_transition`** (`init_t` → `myapp_t`) on RHEL — keep it false for labeled daemons. **`ExecStart` must be the labeled script** (`/opt/myapp/backend_stub.py` → `myapp_backend_exec_t`); starting venv `python` keeps the process in `myapp_t`.

---

## 3. Build, CI, and PR review

### Layered gates

```text
1. grep forbidden patterns     →  validate_forbidden_patterns.sh (GHA `forbidden-patterns`; generator already ran this)
2. version SSOT                →  validate_version_consistency.sh (GHA `version-consistency`)
3. refpolicy Makefile compile  →  compile_and_validate.sh on rhel-qa
4. semantic sesearch checks    →  validate_policy_semantics.sh on rhel-qa
5. blast-radius fixtures       →  make test-fixtures (laptop; no SELinux)
6. PR policy access delta      →  assemble_pr_body.sh + policy_module_diff.sh
7. canary + soak + enforce     →  AAP (or ansible-playbook from the Mac)
```

### Do

| Practice | Script / job |
|----------|--------------|
| Rebuild `.pp` from `.te`/`.fc` on rhel-qa | `compile_and_validate.sh` (not committed) |
| Assert no shadow/unlabeled/foreign entrypoint | `validate_policy_semantics.sh` on rhel-qa (`--direct`) |
| Verify service runs in expected domain | `wait_for_endpoints.sh` domain-context check |
| Tier soak by blast radius | `classify_policy_blast_radius.sh` + fixtures in [`tests/fixtures/blast_radius/`](../../tests/fixtures/blast_radius/) (`make test-fixtures`); optional `check_soak_ready.sh --auto-tier` on controller (fail-closed) |
| Include policy access delta in PR body | `assemble_pr_body.sh` + `policy_module_diff.sh` (sesearch / merge-base; not `sediff` on `.pp`) |
| Lint shell and YAML | `make check` (`shellcheck`, `yamllint`, `ansible-lint` when installed) |

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
| Register ports at deploy | `community.general.seport` loop from manifest `selinux_ports` |
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

**Packaging path (production-grade):** [`packaging/myapp-selinux.spec`](../../packaging/myapp-selinux.spec) — RPM with `%selinux_modules_install`, relabel macros, port registration in `%post`.

---

## 5. Soak, monitoring, and enforce gates

### Do

| Practice | Detail |
|----------|--------|
| **7–14 day soak** after canary | Capture cron, logrotate, cert renewals |
| **`ausearch --input-logs --subject myapp_t`** | Counts rotated logs; filters by subject domain |
| Include **`SELINUX_ERR`** events | Not just `-m avc` — constraint / invalid context failures |
| Daily **`soak_monitor.yml`** (or `monitor_avc.sh --max-net-new 0`) | Net-new vs **installed** policy; raw AVC count is informational |
| **`collect_soak_facts.sh` / `soak_status.yml`** before enforce | Soak days + net-new (or raw AVC if `sesearch` missing) + deploy report |
| Canary AVC gate | `canary_max_avc: 0` default in `deploy_canary.yml` |
| Reset soak clock on policy change | New marker after redeploy or rollback |

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| Substring grep `myapp_t` in audit.log | False positives (`myapp_tmp_t`); misses multiline events |
| `ausearch` without `--input-logs` on 7-day soak | Rotated logs drop early denials → false “zero AVCs” |
| Zero raw AVC lines as the soak gate | Duplicate cron denials fail the gate; use **net-new** vs installed policy |
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
| App team triage | [PRODUCTION_READINESS.md §12.5](../admin/PRODUCTION_READINESS.md) — health JSON, deploy report |
| Full recovery loop | permissive → policy PR → canary → soak → enforce |

### Don’t

| Anti-pattern | Why it fails |
|--------------|--------------|
| Rollback | Permissive relief first; optional `dnf downgrade myapp-selinux-*` — not app-writable policy-history |
| Re-deploy app code alone | SELinux denial needs policy fix |
| Broad local `allow` rules | Bypasses review; reintroduces audit2allow anti-patterns |

---

## 7. AI policy generation (optional)

Default policy is **`cli/deterministic_gen.py`**. Optional **`cli/summarize_pr.py`** polishes `pr_summary.md` only. Legacy all-in-one LLM (`cli/selinux_gen.py --legacy-full-policy`) is for emergency rollback patches on the **controller**, not day-to-day `.te` authoring.

The LLM path follows the same house rules as hand-written policy. See [`cli/prompt_templates.py`](../../cli/prompt_templates.py):

- Prefer refpolicy **interfaces** (embedded allowlist in system prompt)
- Ban raw syslog / `unreserved_port_t` / `bin_t` patterns
- FHS `.fc` template without `--` on directories
- Compile-retry on `policy_module()` / macro errors

**Human review is mandatory** — generated output passes CI but does not replace admin sign-off.

The generator also **refuses to duplicate vendor policy**. Pointing it at JWS or EAP without `--force` exits non-zero; install `jws6-tomcat-selinux` / `eap*-selinux` (or tune the loaded module) instead. See [DETERMINISTIC_POLICY.md](../developers/DETERMINISTIC_POLICY.md).

---

## 8. Review checklist (admins)

Use with the [PR template](../../.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md):

- [ ] `.te` uses refpolicy interfaces, not audit2allow-style raw allows
- [ ] Port 8888 / 8889 use `myapp_port_t` / `myapp_backend_port_t`, not `unreserved_port_t`
- [ ] `.fc` uses FHS paths; no `--` on directory patterns; venv split exec/lib
- [ ] CI: `forbidden-patterns` and `version-consistency` pass (generator already ran forbidden-patterns)
- [ ] Compile on rhel-qa: `compile_and_validate.sh` + `validate_policy_semantics.sh`
- [ ] Version bump: `selinux/policy_version.txt` and matching `policy_module(myapp, …)` in `.te` only (no duplicate version in spec/inventory)
- [ ] `verify_file_contexts.sh` passes after `restorecon` (includes `/var/log/myapp`)
- [ ] Canary plan: `semodule -DB`, endpoint smoke, **domain context** in deploy report, soak marker
- [ ] Enforce plan: `collect_soak_facts.sh` / `soak_status.yml` (net-new), `semodule -B`, block/rescue tested or briefed
- [ ] Developers can run `dev_generate_policy.sh --enforce-check` before opening PR
- [ ] Rollback owner knows `emergency_rollback.yml`, optional `rollback_dnf_version`, and `reset_host_state.yml` for interrupted canary
- [ ] AAP workflows mapped from [`ansible/aap/`](../../ansible/aap/) ([ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md))
- [ ] Prod denial path is a PR ([DENIAL_RESPONSE.md](../admin/DENIAL_RESPONSE.md)), not live `semodule -i`

---

## 9. Related docs

| Guide | Role |
|-------|------|
| [TESTING.md](../developers/TESTING.md) | Endpoint probes, smoke_test.py, CI and deploy gates |
| [ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md) | AAP workflows (`ansible/aap/`) and soak monitor |
| [DENIAL_RESPONSE.md](../admin/DENIAL_RESPONSE.md) | File/port AVC after ship → PR |
| [../ansible/README.md](../../ansible/README.md) | Ansible playbook task order and variables |
| [SELINUX_BASICS.md](SELINUX_BASICS.md) | Concepts and beginner mistakes |
| [DEMO_GUIDE.md](../training/DEMO_GUIDE.md) | Three-app customer talk (`demo_present.sh`) |
| [PRODUCTION_READINESS.md](../admin/PRODUCTION_READINESS.md) | Admin runbook — soak, canary, enforce, rollback |
| [README.md](../../README.md) | Commands, CI, Ansible pointer |
