# Ansible Playbooks

Ansible orchestrates the **admin deploy lifecycle** for SELinux policy on real RHEL/FCOS hosts. It does **not** install the application for the first time — use [`scripts/setup_staging_env.sh`](../scripts/setup_staging_env.sh) for that.

**Where commands run:**

| What | Where |
|------|--------|
| `ansible-playbook …` | **Controller** (your laptop or CI runner) with SSH to inventory hosts |
| `semanage`, `semodule`, soak scripts on hosts | **Target RHEL/Stream machines** in inventory |
| `compile_and_validate.sh` before deploy | **Repo root** on controller (often with Podman — [DOCKER_HUB_COMPILE_IMAGE.md](../docs/DOCKER_HUB_COMPILE_IMAGE.md)) |

**Doc index:** [docs/README.md](../docs/README.md).

| Playbook | Purpose |
|----------|---------|
| [`deploy_canary.yml`](deploy_canary.yml) | Install policy, permissive soak start, smoke tests |
| [`soak_monitor.yml`](soak_monitor.yml) | Daily / on-demand AVC + net-new threshold check |
| [`soak_status.yml`](soak_status.yml) | Read-only soak facts before enforce |
| [`enforce_production.yml`](enforce_production.yml) | Soak gate, remove permissive, enforce smoke |
| [`emergency_rollback.yml`](emergency_rollback.yml) | Permissive first; optional `dnf downgrade` |
| [`reset_host_state.yml`](reset_host_state.yml) | `semodule -B` + clear permissive (no module change) |
| [`generate_emergency_patch.yml`](generate_emergency_patch.yml) | Controller-only OpenAI patch from AVC log |

Playbooks delegate to role [`roles/selinux_pac/`](roles/selinux_pac/). Target scripts live in RPM **`selinux-policy-ops`** at **`/usr/libexec/selinux-policy-ops`** (inventory: `selinux_ops_dir`). Demo/lab sets `selinux_ops_from_package: false` and points `selinux_ops_dir` at the checkout `scripts/` tree.

Testing matrix: [`docs/TESTING.md`](../docs/TESTING.md). Admin runbook: [`docs/PRODUCTION_READINESS.md`](../docs/PRODUCTION_READINESS.md). Policy compiles on admin laptops via Podman: pull [`docs/DOCKER_HUB_COMPILE_IMAGE.md`](../docs/DOCKER_HUB_COMPILE_IMAGE.md) (`asaran/selinux-demo-selinux-build:stream9`).

---

## Prerequisites

### Host requirements

- **RHEL 9** (recommended for Red Hat demos), CentOS Stream 9, or FCOS with **SELinux enforcing**
- Application already installed (`/opt/myapp`, systemd units, `myapp` user)
- `auditd` running (for AVC gates)
- `policycoreutils`, `policycoreutils-python-utils` (`semanage`, `restorecon`, `ausearch`)

### Controller requirements

```bash
pip install ansible
ansible-galaxy collection install -r ansible/requirements.yml
```

Collections: `community.general` (`selinux_permissive`, `seport`), `ansible.posix`.

### Inventory

| File | Use |
|------|-----|
| [`inventory.example.yml`](inventory.example.yml) | Local / lab |
| [`inventory.staging.example.yml`](inventory.staging.example.yml) | Staging runner |
| [`inventory.production.example.yml`](inventory.production.example.yml) | Prod canary + fleet |

---

## Policy artifacts and RPMs

Build the module before deploy (`.pp` is not committed). RPM version is taken from **`selinux/policy_version.txt`** when you run [`packaging/build_rpms.sh`](../packaging/build_rpms.sh) (`myapp-selinux-<version>-*.rpm`).

```bash
bash scripts/compile_and_validate.sh selinux
```

**Lab / staging (checkout on host or controller):** pass controller paths — see [`inventory.example.yml`](inventory.example.yml).

```bash
ansible-playbook -i ansible/inventory.example.yml ansible/deploy_canary.yml \
  -e "policy_pp_src=$(pwd)/selinux/myapp.pp" \
  -e "policy_artifact_dir=$(pwd)" \
  -e "selinux_ops_from_package=false" \
  -e "selinux_ops_dir=$(pwd)/scripts" \
  -e "app_manifest_path=$(pwd)/config/myapp.manifest.yml"
```

**Production (no git on target):** install RPMs built from [`packaging/build_rpms.sh`](../packaging/build_rpms.sh) (`selinux-policy-ops`, `myapp-selinux-<version>`). Inventory sets `selinux_ops_from_package: true`, `app_manifest_path: /etc/myapp/selinux-manifest.yml`, and leaves `policy_pp_src` empty when the module comes only from the RPM.

---

## Shared variables

Set in inventory `vars` or pass with `-e`. Role defaults live in [`roles/selinux_pac/defaults/main.yml`](roles/selinux_pac/defaults/main.yml).

| Variable | Typical value | Description |
|----------|---------------|-------------|
| `app_name` | `myapp` | Module name prefix |
| `domain` | `myapp_t` | Application SELinux domain |
| `install_root` | `/opt/myapp` | Application tree |
| `var_dir` | `/var/lib/myapp` | State directory (`StateDirectory`) |
| `log_dir` | `/var/log/myapp` | Log directory (`LogsDirectory`) — **must be set in inventory** (not a self-referential play var) |
| `runtime_dir` | `/run/myapp` | Runtime dir (`RuntimeDirectory`) |
| `service_name` | `myapp.service` | Primary systemd unit |
| `policy_version` | _(from `policy_artifact_dir/policy_version.txt` or `../selinux/policy_version.txt`)_ | SemVer for RPM name and deploy report |
| `selinux_ops_dir` | `/usr/libexec/selinux-policy-ops` | Target path to ops scripts (lab: `…/scripts`) |
| `selinux_ops_from_package` | `true` / `false` | When `true`, role runs `dnf install selinux-policy-ops` (+ app RPM) |
| `policy_artifact_dir` | controller repo or `dist/` | **Controller only** — never used in remote `command` paths |
| `policy_pp_src` | `…/selinux/myapp.pp` | **Controller only** — copied to `policy_staging_path` on target; empty when RPM-only |
| `policy_staging_path` | `/var/lib/selinux-policy-staging/myapp.pp` | Target path for `semodule -i` |
| `app_manifest_path` | `/etc/myapp/selinux-manifest.yml` (prod) or checkout `config/*.manifest.yml` (lab) | Passed to all `--manifest` ops scripts |
| `soak_marker_file` | `{{ var_dir }}/selinux_canary_deployed_at` | Epoch file for soak clock |
| `soak_min_days` | `7` | Minimum soak days (enforce gate) |
| `soak_max_avc` | `0` | Max domain AVCs since marker |
| `canary_max_avc` | `0` | Max recent AVCs right after canary deploy |
| `force_enforce` | `false` | Skip soak gate (break-glass) |
| `rollback_dnf_version` | *(unset)* | e.g. `1.1.1-1` → `dnf downgrade myapp-selinux-…` on emergency rollback |

**Deprecated (do not use on production targets):** `project_root`, `policy_pp_path`, `policy-history/`, `rollback_target_version`.

**Optional blast-radius soak tier (`check_soak_ready.sh` on controller):** pass **`--auto-tier`** with **`--base-policy`** and **`--candidate-policy`** (paths to `.te`/`.pp` for previous vs candidate module). The script calls [`classify_policy_blast_radius.sh`](../scripts/classify_policy_blast_radius.sh) (sesearch rule diff, not `sediff`). On classifier error or `fail_closed` JSON, minimum soak stays at **`soak_min_days`** (default 7) — never shortens the gate on failure. Tier logic is gated by CI job **`blast-radius`** ([`tests/fixtures/blast_radius/`](../tests/fixtures/blast_radius/)).

**Ansible enforce role** uses fixed **`soak_min_days`** via **`collect_soak_facts.sh`** unless you extend the role to pass tiering inputs.

**Deprecated:** hardcoding `policy_version` in inventory — the role loads **`policy_version.txt`** from `policy_artifact_dir` (e.g. `policy_out/`) or **`selinux/policy_version.txt`** beside it.

---

## Directory ownership (who creates what)

| Path | Created by | SELinux labels from |
|------|------------|---------------------|
| `/opt/myapp` | App install / admin | Policy module `.fc` + `restorecon` |
| `/var/lib/myapp`, `/var/log/myapp` | Ansible `file` task before canary/enforce (systemd `StateDirectory`/`LogsDirectory` also apply at service start) | Policy module `.fc` |
| `/run/myapp` | systemd at service start | Policy module `.fc`; `restorecon` **after** restart |
| Ops scripts | **`selinux-policy-ops` RPM** | N/A |
| App manifest | **`myapp-selinux` RPM** → `/etc/myapp/selinux-manifest.yml` | N/A |

---

## `deploy_canary.yml`

**When:** After policy merge — staging auto-deploy on `main`, or prod canary host before fleet.

**Goal:** Install module, start **permissive soak**, verify labeling and endpoints, record soak marker.

Implements role phase **`canary`** ([`roles/selinux_pac/tasks/canary.yml`](roles/selinux_pac/tasks/canary.yml)).

### Task order (summary)

| # | Task | Notes |
|---|------|-------|
| 1 | Install ops + app RPM (optional) | When `selinux_ops_from_package` |
| 2 | Stage `.pp` from controller → `semodule -i` | When `policy_pp_src` set |
| 3 | `semodule -DB` | Host-wide dontaudit off for soak |
| 4 | `seport` 8888 / 8889 | When semanage available |
| 5 | Permissive domain (+ FCOS overlay if needed) | RHEL: `semanage permissive`. FCOS (no `semanage`): install compiled **`selinux/myapp_canary.pp`** from controller (`stub_policy_src`, not under `policy_out/`). Build with `POLICY_MODULE=myapp_canary bash scripts/compile_and_validate.sh selinux`. FCOS also loads **`selinux/myapp_ports.cil`** when `seport` is skipped (8888/8889). |
| 6 | Ensure `var_dir` + `log_dir`; `restorecon` (no pre-restart `/run/myapp`) | |
| 7 | `{{ selinux_ops_dir }}/verify_file_contexts.sh` | |
| 8 | Soak marker; restart services; `restorecon` on `runtime_dir` | |
| 9 | `wait_for_endpoints.sh`, `monitor_avc.sh`, `post_deploy_report.sh` | All under `selinux_ops_dir` |
| **rescue** | `semodule -B` + fail | |

### Example

```bash
bash scripts/compile_and_validate.sh selinux
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit canary
```

(Production inventory uses RPMs; staging/example passes `policy_pp_src` — see inventory files.)

### GitHub Actions

- Merge to `main`: [`.github/workflows/selinux-staging-canary.yml`](../.github/workflows/selinux-staging-canary.yml)
- Manual: **SELinux Policy Deploy** → `canary`

---

## `enforce_production.yml`

**When:** After soak gates pass (**fixed `soak_min_days`**, default 7).

**Goal:** Remove permissive flag, run app under **enforcing** `myapp_t`, verify endpoints.

Role phase **`enforce`**. Uses **`serial: 1`**.

### Task order (summary)

| # | Task | Notes |
|---|------|-------|
| 1 | `collect_soak_facts.sh` → assert days/AVC/report | Skipped when `force_enforce=true` |
| 2 | `semodule -B` | Restore dontaudit before production |
| 3 | Remove permissive; verify enforcing | |
| 4 | Dirs + `restorecon`; verify contexts; restart; runtime `restorecon` | |
| 5 | `wait_for_endpoints.sh` + enforce deploy report | |
| **rescue** | Permissive + restart + endpoint wait + fail | |

### Example

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  --limit production

# Break-glass only:
ansible-playbook ... enforce_production.yml -e "force_enforce=true"
```

---

## `emergency_rollback.yml`

**When:** Enforce caused outage, or admin needs immediate permissive relief.

Role phase **`rollback`**. **Permissive first** (stock modules / `semanage`); optional **`dnf downgrade`**; then `semodule -B`, restorecon, restarts, AVC export. Optional ops scripts if RPM installed.

**No OpenAI on target** — run [`generate_emergency_patch.yml`](generate_emergency_patch.yml) on the **controller** after fetching `/tmp/emergency_avc.log`.

### Example

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/emergency_rollback.yml \
  --limit canary \
  -e "rollback_dnf_version=1.1.1-1"
```

---

## `reset_host_state.yml`

After an **interrupted canary** (host left on `semodule -DB` or permissive): `semodule -B` + clear permissive — **does not** change the installed policy module.

---

## GitHub Actions integration

Workflow: [`.github/workflows/selinux-deploy.yml`](../.github/workflows/selinux-deploy.yml)

| Input | Playbook |
|-------|----------|
| `canary` + `staging` | `deploy_canary.yml` |
| `canary` + `production` | `deploy_canary.yml` (`--limit canary`) |
| `enforce` + `production` | `enforce_production.yml` |
| `rollback` | `emergency_rollback.yml` |

Runners: `selinux-staging` / `selinux-production` with GitHub Environments.

---

## Ops scripts (target)

Installed by **`selinux-policy-ops`** RPM (or checkout when `selinux_ops_from_package: false`):

| Script | Role phase |
|--------|------------|
| `verify_file_contexts.sh` | canary, enforce |
| `wait_for_endpoints.sh` | canary, enforce, rollback (optional) |
| `monitor_avc.sh` | canary |
| `collect_soak_facts.sh` | enforce (soak gate) |
| `post_deploy_report.sh` | canary, enforce, rollback (optional) |

**Controller / CI only:** `compile_and_validate.sh`, `classify_policy_blast_radius.sh`, `check_soak_ready.sh` (manual CLI), `cli/selinux_gen.py`.

Parity guard: [`scripts/validate_rpm_ops_parity.sh`](../scripts/validate_rpm_ops_parity.sh) (CI job `rpm-ops-parity`).

---

## Verification checklist (sign-off)

| Check | How |
|-------|-----|
| Canary without rescue | Clean RHEL 9 host: `ansible-playbook … deploy_canary.yml` → **Report canary status** (no `rescue`) |
| Developer PR handoff | `bash scripts/dev_generate_policy.sh --apply --open-pr` → branch pushed, PR opens |
| No repo on prod target | SSH host with RPMs only + production inventory; canary/enforce complete |
| Packaging drift | `bash scripts/validate_rpm_ops_parity.sh` (CI) |
| Policy compile | `bash scripts/compile_and_validate.sh selinux` |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `policy_pp_src` missing (lab) | Run `compile_and_validate.sh`; pass `-e policy_pp_src=…` |
| Recursive template error on `log_dir` | Set `log_dir` in inventory only — not `log_dir: "{{ log_dir \| default… }}"` in play vars |
| Canary fails on AVC count | `ausearch --subject myapp_t -m AVC -ts recent` |
| `wait_for_endpoints` exit **4** | `ps -eZ \| grep myapp` — domain mismatch |
| Enforce rescue | Deploy report at `{{ var_dir }}/selinux_deploy_report.json` |
| Host noisy after failed canary | Run `reset_host_state.yml` or `semodule -B` + clear permissive |

See [`PRODUCTION_READINESS.md`](../docs/PRODUCTION_READINESS.md) § troubleshooting.
