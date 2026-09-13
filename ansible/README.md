# Ansible Playbooks

Ansible orchestrates the **admin deploy lifecycle** for SELinux policy on real RHEL/FCOS hosts. It does **not** install the application for the first time — use [`scripts/setup_staging_env.sh`](../scripts/setup_staging_env.sh) for that.

| Playbook | Purpose |
|----------|---------|
| [`deploy_canary.yml`](deploy_canary.yml) | Install policy, permissive soak start, smoke tests |
| [`enforce_production.yml`](enforce_production.yml) | Soak gate, remove permissive, enforce smoke |
| [`emergency_rollback.yml`](emergency_rollback.yml) | Break-glass permissive + optional module downgrade |

Testing matrix (what each gate checks): [`docs/TESTING.md`](../docs/TESTING.md).

Admin runbook: [`docs/PRODUCTION_READINESS.md`](../docs/PRODUCTION_READINESS.md).

---

## Prerequisites

### Host requirements

- RHEL 9 / CentOS Stream 9 / FCOS with **SELinux enforcing**
- Application already installed (`/opt/myapp`, systemd units, `myapp` user)
- `auditd` running (for AVC gates)
- `policycoreutils`, `policycoreutils-python-utils`, `setools-console` (semantic checks are CI-only; host needs `semanage`, `restorecon`, `ausearch`)

### Controller requirements

```bash
pip install ansible
ansible-galaxy collection install -r ansible/requirements.yml
```

Collections (pinned in [`requirements.yml`](requirements.yml)):

- `community.general` — `selinux_permissive`, `seport`
- `ansible.posix` — (available for future use)

### Inventory

Copy an example inventory and edit hosts:

| File | Use |
|------|-----|
| [`inventory.example.yml`](inventory.example.yml) | Local / lab (`ansible_connection: local`) |
| [`inventory.staging.example.yml`](inventory.staging.example.yml) | Staging runner |
| [`inventory.production.example.yml`](inventory.production.example.yml) | Prod canary + fleet (`canary` / `production` groups) |

```bash
cp ansible/inventory.production.example.yml ansible/inventory.production.yml
# edit ansible_host, ansible_user
```

### Policy package

Build before every deploy — `.pp` is not committed:

```bash
bash scripts/compile_and_validate.sh selinux
ansible-playbook ... -e "policy_pp_path=$(pwd)/selinux/myapp.pp"
```

---

## Shared variables

Set in inventory `vars` or pass with `-e`:

| Variable | Default | Description |
|----------|---------|-------------|
| `app_name` | `myapp` | Module name prefix |
| `domain` | `myapp_t` | Application SELinux domain |
| `install_root` | `/opt/myapp` | Application tree |
| `var_dir` | `/var/lib/myapp` | State directory (`StateDirectory`) |
| `log_dir` | `/var/log/myapp` | Log directory (`LogsDirectory`) |
| `runtime_dir` | `/run/myapp` | Runtime dir (`RuntimeDirectory`) |
| `service_name` | `myapp.service` | Primary systemd unit |
| `policy_pp_path` | `../selinux/myapp.pp` | Compiled module to install |
| `project_root` | repo root | Path to scripts and `selinux/` |
| `app_manifest_path` | `{{ project_root }}/config/{{ app_name }}.manifest.yml` | Passed to `--manifest` on readiness/report/soak scripts |
| `soak_marker_file` | `{{ var_dir }}/selinux_canary_deployed_at` | Epoch file for soak clock |
| `soak_min_days` | `7` | Minimum soak days (enforce gate) |
| `soak_max_avc` | `0` | Max domain AVCs since marker |
| `canary_max_avc` | `0` | Max recent AVCs right after canary deploy |
| `soak_auto_tier` | `false` | Pass `--auto-tier` to `check_soak_ready.sh` |
| `force_enforce` | `false` | Skip soak gate (break-glass) |
| `rollback_target_version` | *(unset)* | Reinstall `policy-history/myapp-{version}.pp` on rollback |

---

## `deploy_canary.yml`

**When:** After policy merge — staging auto-deploy on `main`, or prod canary host before fleet.

**Goal:** Install module, start **permissive soak**, verify labeling and endpoints, record soak marker.

### Task order

| # | Task | Notes |
|---|------|-------|
| 1 | Detect `semanage` | FCOS vs full RHEL path split |
| 2 | Verify `policy_pp_path` exists | Fail with compile hint |
| 3 | Create `policy-history/` | Archive current `.pp` as `myapp-{version}.pp` |
| **block** | | |
| 4 | `semodule -i` | In-place upgrade |
| 5 | `semodule -DB` | Disable dontaudit for soak (**host-wide**) |
| 6 | `seport` 8888 → `myapp_port_t` | When semanage available |
| 7 | `seport` 8889 → `myapp_backend_port_t` | |
| 8 | `selinux_permissive: true` for `myapp_t` | Or FCOS stub overlay |
| 9 | `restorecon -Rv` | `install_root`, `var_dir`, `log_dir`, `runtime_dir` |
| 10 | `verify_file_contexts.sh` | Fail closed on mislabel |
| 11 | Write soak marker (epoch) | Resets soak clock |
| 12 | Restart `myapp-backend` + `myapp` | systemd only |
| 13 | `wait_for_endpoints.sh --manifest {{ app_manifest_path }}` | HTTP + **domain context** |
| 14 | `monitor_avc.sh --since recent` | Fail if &gt; `canary_max_avc` |
| 15 | `post_deploy_report.sh --phase canary --manifest …` | JSON at deploy report path from manifest |
| **rescue** | | |
| R1 | `semodule -B` | Restore dontaudit if block failed |
| R2 | Fail with guidance | | |

### Example

```bash
bash scripts/compile_and_validate.sh selinux
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit canary \
  -e "policy_pp_path=$(pwd)/selinux/myapp.pp"
```

### GitHub Actions

- Merge to `main`: [`.github/workflows/selinux-staging-canary.yml`](../.github/workflows/selinux-staging-canary.yml)
- Manual: **SELinux Policy Deploy** → `canary`

---

## `enforce_production.yml`

**When:** After soak gates pass (7+ days default, or `--auto-tier`).

**Goal:** Remove permissive flag, run app under **enforcing** `myapp_t`, verify endpoints.

Uses **`serial: 1`** — one host at a time for fleet rollouts.

### Task order

| # | Task | Notes |
|---|------|-------|
| 1 | `check_soak_ready.sh --manifest …` | Skipped when `force_enforce=true` |
| 2 | `semodule -B` | Restore dontaudit before production |
| 3 | **block** | |
| 4 | `selinux_permissive: false` | Remove permissive domain |
| 5 | Verify `getenforce` = Enforcing | |
| 6 | Verify domain not in `semanage permissive -l` | |
| 7 | `restorecon` + `verify_file_contexts.sh` | |
| 8 | Restart services | backend first in loop order |
| 9 | `wait_for_endpoints.sh --manifest …` | Full smoke under enforce |
| 10 | `post_deploy_report.sh --phase enforce --manifest …` | |
| **rescue** | | |
| R1 | Restore **permissive** domain | Auto-relief |
| R2 | Restart services | |
| R3 | `wait_for_endpoints.sh --manifest …` | Confirm app back up |
| R4 | Fail with AVC/report guidance | |

### Example

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  --limit production \
  -e "soak_auto_tier=true"

# Break-glass only:
ansible-playbook ... enforce_production.yml -e "force_enforce=true"
```

---

## `emergency_rollback.yml`

**When:** Enforce caused outage, or admin needs immediate permissive relief.

**Goal:** Restore service availability, capture AVCs, optionally downgrade module, reset soak clock.

### Task order

| # | Task | Notes |
|---|------|-------|
| 1 | Optional `semodule -i` prior version | When `rollback_target_version` set |
| 2 | `selinux_permissive: true` | Immediate relief |
| 3 | FCOS stub fallback | When no semanage |
| 4 | `semodule -B` | Restore dontaudit |
| 5 | `restorecon` | |
| 6 | Restart services | |
| 7 | `wait_for_endpoints.sh --manifest …` | |
| 8 | Reset soak marker | **Full re-soak required** |
| 9 | `post_deploy_report.sh --phase rollback --manifest …` | |
| 10 | Export AVCs to `/tmp/emergency_avc.log` | |
| 11 | Optional `selinux_gen.py` emergency patch | Needs `OPENAI_API_KEY` |

### Example

```bash
export OPENAI_API_KEY="..."   # optional
ansible-playbook -i ansible/inventory.production.yml ansible/emergency_rollback.yml \
  --limit canary \
  -e "rollback_target_version=1.1.0"
```

---

## GitHub Actions integration

Workflow: [`.github/workflows/selinux-deploy.yml`](../.github/workflows/selinux-deploy.yml)

| Input | Playbook |
|-------|----------|
| `canary` + `staging` | `deploy_canary.yml` |
| `canary` + `production` | `deploy_canary.yml` (`--limit canary`) |
| `enforce` + `production` | `enforce_production.yml` (Environment approval) |
| `rollback` | `emergency_rollback.yml` |

Requires self-hosted runners:

| Label | Environment |
|-------|-------------|
| `selinux-staging` | `staging` |
| `selinux-production` | `production` |

---

## Ansible vs shell scripts

Ansible **calls** repository scripts — it does not duplicate their logic:

| Script | Called from |
|--------|-------------|
| `verify_file_contexts.sh` | canary, enforce |
| `wait_for_endpoints.sh --manifest {{ app_manifest_path }}` | all three playbooks |
| `monitor_avc.sh` | canary |
| `check_soak_ready.sh --manifest {{ app_manifest_path }}` | enforce |
| `post_deploy_report.sh --manifest {{ app_manifest_path }}` | all three |

For workshop/demo without Ansible, [`scripts/apply_policy.sh`](../scripts/apply_policy.sh) provides a subset of canary behavior.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `policy_pp_path` missing | Run `compile_and_validate.sh` first |
| Canary fails on AVC count | `ausearch --subject myapp_t -m AVC -ts recent`; fix `.te`, redeploy |
| `wait_for_endpoints` exit **4** | `ps -eZ \| grep myapp` — entrypoint mislabeled (`init_t` not `myapp_t`) |
| Enforce rescue triggered | `/var/lib/myapp/selinux_deploy_report.json`, `journalctl -u myapp` |
| `semodule -DB` left host noisy | Failed canary runs `-B` in rescue; rollback runs `-B`; enforce runs `-B` at start |

See [`PRODUCTION_READINESS.md`](../docs/PRODUCTION_READINESS.md) § troubleshooting table.
