# Ansible operations (AAP)

**Ansible Automation Platform (AAP)** is the production control plane. Developers PR policy; you **compile and package** RPMs; **Automation Controller job templates** install, soak, and enforce. Do not clone this repo onto production targets.

The same playbooks run under `ansible-playbook` on a laptop until the project is imported into AAP.

**Where commands run:** AAP execution nodes (or `ansible-playbook` on a controller laptop) SSH to inventory hosts. `semodule` / `semanage` / soak scripts run on **RHEL targets**.

Playbook task order and variables: [`ansible/README.md`](../../ansible/README.md). **AAP objects:** [`ansible/aap/`](../../ansible/aap/). **Two RHEL boxes:** [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md). Admin runbook: [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md). Denied file/port after ship: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md). Fork wiring: [ADOPTION_CHECKLIST.md](ADOPTION_CHECKLIST.md).

```text
CLI (rhel-qa)  →  RPM repo (.pp + selinux-policy-ops + <app>-selinux)
                      │
                      ▼
              AAP (Automation Controller)
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
| [`ansible/generate_emergency_patch.yml`](../../ansible/generate_emergency_patch.yml) | Controller + git checkout only — writes `policy_out/` for a PR, never host install |

Role: [`ansible/roles/selinux_pac/`](../../ansible/roles/selinux_pac/). The role loads `app_manifest_path` and registers **ports from `selinux_ports`** (stable across environments). Probe IP is `http.host` in the manifest or inventory `http_probe_host` (changes per env).

Lab-only: `selinux_pac_install_demo_units: true` copies demo systemd units. Production inventories leave this **false**.

## AAP job templates and workflows

Source of truth: [`ansible/aap/`](../../ansible/aap/) (`job_templates.yml`, `workflows.yml`, `survey_enforce.json`). Click-create in Automation Controller (project playbook path `ansible/`).

| Template | Playbook | How it runs |
|----------|----------|-------------|
| SELinux – Canary | `deploy_canary.yml` | Workflow **Release canary** (manual after RPM) |
| SELinux – Soak monitor | `soak_monitor.yml` | **Schedule daily** on `canary` (not a workflow wait node) |
| SELinux – Soak status | `soak_status.yml` | First node of **Promote to enforce** |
| SELinux – Enforce | `enforce_production.yml` | After approval on **Promote to enforce** |
| SELinux – Rollback | `emergency_rollback.yml` | Standalone break-glass — never on the promote graph |

**Workflows:** **Release canary** = Canary. **Promote to enforce** = Soak status → approval → Enforce. Attach an AAP notification template to Soak monitor (job failed) so net-new AVCs page someone without mutating the host. Denial path: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md).

Survey / extra-vars:

Attach [`ansible/aap/survey_enforce.json`](../../ansible/aap/survey_enforce.json) to the **SELinux – Enforce** job template (Automation Controller survey). `change_ticket` is **required**. `force_enforce` defaults to **false**.

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
| `soak_notify_webhook` | *(empty)* | Optional; prefer an AAP notification template on Soak monitor |
| `rollback_dnf_version` | `1.1.1-1` | Optional downgrade on rollback |

## Two-host lab (preferred)

```bash
bash scripts/setup_rhel_hosts.sh write --dev-host DEV --prod-host PROD --user ansible
bash scripts/setup_rhel_hosts.sh ping
```

- **QA** inventory: git checkout on the box + `demo_bootstrap.sh --shopapi-only`; `selinux_ops_dir` / `app_manifest_path` are **on the box** (not `playbook_dir` on the laptop); `soak_min_days: 0` is lab-only. `app_name: shopapi`, `policy_pp_src` → `selinux/shopapi/shopapi.pp`.
- **Prod** inventory: RPMs only (`shopapi-selinux`); `soak_min_days: 7`. Same host is `canary` and `production` until you add a fleet.

Customer talk: [DEMO_GUIDE.md](../training/DEMO_GUIDE.md) (`demo_present.sh`). Two-host generate/canary/soak: [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md) (`bash scripts/demo_e2e_mac.sh`) — clean soak, talk-only enforce, then shopapi `/feature-spool` outage and `emergency_rollback.yml`. Flask is not installed on the VMs.

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

## GitHub Actions (PR review)

[`.github/workflows/selinux-policy-ci.yml`](../../.github/workflows/selinux-policy-ci.yml) runs **`forbidden-patterns`** and **`version-consistency`** on PRs that touch `selinux/`. The deterministic generator already ran `validate_forbidden_patterns.sh`, so those jobs are expected to **pass**. Compile and canary stay on rhel-qa / AAP (`compile_and_validate.sh`, `packaging/build_rpms.sh`, playbooks above). There is no GitHub deploy or staging-canary workflow.

## First-time admin

```bash
bash scripts/setup_rhel_hosts.sh write --dev-host DEV --prod-host PROD
bash scripts/setup_rhel_hosts.sh ping
bash scripts/setup_rhel_hosts.sh doctor
bash scripts/selinux_pac_adopt.sh init myapp
```
