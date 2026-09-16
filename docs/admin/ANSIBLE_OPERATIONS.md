# Ansible operations (AWX / ansible-playbook)

Ansible is the **control plane** for SELinux policy on RHEL hosts. Developers PR policy; you **compile and package** RPMs, then playbooks **install, soak, and enforce**. Do not clone this repo onto production targets.

**Where commands run:** `ansible-playbook` on a **controller** (AWX execution node or laptop) with SSH to inventory hosts. `semodule` / `semanage` / soak scripts run on **RHEL targets**.

Playbook task order and variables: [`ansible/README.md`](../../ansible/README.md). **Two RHEL boxes:** [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md). Admin runbook: [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md). Fork wiring: [ADOPTION_CHECKLIST.md](ADOPTION_CHECKLIST.md).

```text
CLI / CI     →  RPM repo (.pp + selinux-policy-ops + <app>-selinux)
                      │
                      ▼
              AWX / ansible-playbook
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
   deploy_canary  soak_monitor  enforce_production
                      │
                      ▼
              selinux-policy-ops on host
              /etc/<app>/selinux-manifest.yml
```

## Playbooks (admin API)

| Playbook | Purpose |
|----------|---------|
| [`ansible/deploy_canary.yml`](../../ansible/deploy_canary.yml) | Install policy, permissive soak, smoke tests |
| [`ansible/soak_monitor.yml`](../../ansible/soak_monitor.yml) | Scheduled AVC / **net-new** threshold check |
| [`ansible/soak_status.yml`](../../ansible/soak_status.yml) | Read-only soak facts (enforce readiness) |
| [`ansible/enforce_production.yml`](../../ansible/enforce_production.yml) | Soak gate, remove permissive, enforce smoke |
| [`ansible/emergency_rollback.yml`](../../ansible/emergency_rollback.yml) | Permissive relief + optional RPM downgrade |
| [`ansible/reset_host_state.yml`](../../ansible/reset_host_state.yml) | `semodule -B`, clear permissive |
| [`ansible/generate_emergency_patch.yml`](../../ansible/generate_emergency_patch.yml) | Controller-only OpenAI patch from AVC log |

Role: [`ansible/roles/selinux_pac/`](../../ansible/roles/selinux_pac/). The role loads `app_manifest_path` and registers **ports from `selinux_ports`** (stable across environments). Probe IP is `http.host` in the manifest or inventory `http_probe_host` (changes per env).

Lab-only: `selinux_pac_install_demo_units: true` copies demo systemd units. Production inventories leave this **false**.

## AWX job templates (recommended)

| Template | Playbook | Schedule |
|----------|----------|----------|
| SELinux – Canary | `deploy_canary.yml` | On release / manual |
| SELinux – Soak monitor | `soak_monitor.yml` | Daily on canary hosts |
| SELinux – Soak status | `soak_status.yml` | Before enforce approval |
| SELinux – Enforce | `enforce_production.yml` | Manual + approval |
| SELinux – Rollback | `emergency_rollback.yml` | Break-glass |

**Workflow:** Canary → (wait) → scheduled Soak monitor → Soak status (pass) → Enforce (approval node).

Survey / extra-vars:

Attach [`ansible/awx/survey_enforce.json`](../../ansible/awx/survey_enforce.json) to the **SELinux – Enforce** job template. `change_ticket` is **required**. `force_enforce` defaults to **false**.

| Var | Typical | Notes |
|-----|---------|-------|
| `change_ticket` | `CHG123` | **Required** on enforce (playbook fails if empty) |
| `app_name` | `myapp` | Also loaded from manifest |
| `app_manifest_path` | `/etc/myapp/selinux-manifest.yml` | Shipped in `<app>-selinux` RPM |
| `selinux_pac_package` | `myapp-selinux-1.1.3` | From `policy_version.txt` |
| `soak_max_net_new` | `0` | Fail soak if net-new access needs exceed this |
| `soak_use_net_new` | `true` | Net-new vs installed policy (`sesearch` required) |
| `force_enforce` | `false` | Break-glass skip soak; **still needs** `change_ticket` |
| `http_probe_host` | canary IP / VIP | Not a bind port; ports stay in the manifest |
| `rollback_dnf_version` | `1.1.1-1` | Optional downgrade on rollback |

## Two-host lab (preferred)

```bash
bash scripts/setup_rhel_hosts.sh write --dev-host DEV --prod-host PROD --user ansible
bash scripts/setup_rhel_hosts.sh ping
```

- **Dev** inventory: git checkout on the box + `setup_staging_env.sh`; `soak_min_days: 0` is lab-only.
- **Prod** inventory: RPMs only; `soak_min_days: 7`. Same host is `canary` and `production` until you add a fleet.

Full walkthrough: [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md). Local Podman is a **backup** if those boxes are not ready.

## Production inventory

Copy [`ansible/inventory.production.example.yml`](../../ansible/inventory.production.example.yml). Targets use:

- `selinux_ops_from_package: true`
- `app_manifest_path: /etc/<app>/selinux-manifest.yml`
- `policy_pp_src: ""` when the module comes only from the RPM
- No git checkout on hosts

Lab / checkout: [`ansible/inventory.dev.example.yml`](../../ansible/inventory.dev.example.yml) (`selinux_ops_from_package: false`). Local-only: [`ansible/inventory.example.yml`](../../ansible/inventory.example.yml).

## Soak gates

- **Net-new (default):** merge AVCs, subtract allows from **installed** policy (`sesearch --allow -s <domain>`), gate on `avc_net_new_count` (default 0). Raw line count is informational (duplicate cron AVCs do not fail the gate).
- **Required toolchain:** `setools-console` is a **Requires:** of `selinux-policy-ops`. Canary, soak, and enforce **fail** if `sesearch` is missing (no silent raw-AVC fallback).
- **Host CLI:** `monitor_avc.sh --manifest … --max-net-new 0 --format json` or `python3 cli/soak_net_new.py --manifest … --avc-file …`.

## Optional: GitHub Actions

GHA [`selinux-deploy.yml`](../../.github/workflows/selinux-deploy.yml) runs the **same playbooks** on self-hosted `selinux-staging` / `selinux-production` runners. Treat it as AWX-equivalent, not a different lifecycle. Compile locally with `bash scripts/compile_and_validate.sh` and [`packaging/build_rpms.sh`](../../packaging/build_rpms.sh).

## First-time admin

```bash
bash scripts/setup_rhel_hosts.sh write --dev-host DEV --prod-host PROD
bash scripts/setup_rhel_hosts.sh ping
bash scripts/setup_rhel_hosts.sh doctor
bash scripts/selinux_pac_adopt.sh init myapp
```
