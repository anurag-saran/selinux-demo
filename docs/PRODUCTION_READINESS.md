# Production Readiness Runbook (RHEL Admin)

High-blast-radius SELinux policy changes require **per-domain permissive soak**, **path labeling verification**, and **phased rollout** before removing the permissive flag. This runbook maps production guardrails to repo commands.

**New to SELinux?** Read [SELINUX_BASICS.md](SELINUX_BASICS.md) first.

## Pre-production testing matrix

| Phase | Goal | Command / playbook |
| --- | --- | --- |
| **Syntax and compilation** | `.te` / `.fc` compile without errors | `bash scripts/compile_and_validate.sh selinux` |
| **Forbidden patterns** | No wildcards or high-privilege allows | `bash scripts/validate_forbidden_patterns.sh selinux` |
| **Path labeling** | On-disk contexts match `.fc` before restart | `bash scripts/verify_file_contexts.sh` |
| **Staging canary** | Permissive domain + integration smoke | Merge to `main` → staging canary workflow, or `ansible-playbook ansible/deploy_canary.yml -i ansible/inventory.staging.yml` |
| **Permissive soak** | Capture weekly cron, logrotate, restarts (7–14 days) | `semanage permissive -a myapp_t` + daily `bash scripts/monitor_avc.sh` |
| **Production canary host** | Deploy to one node before fleet | `ansible-playbook ... deploy_canary.yml -i ansible/inventory.production.yml --limit canary` |
| **Enforce gate** | Soak elapsed and zero domain AVCs | `bash scripts/check_soak_ready.sh` (called by `enforce_production.yml`) |
| **Production enforce** | Remove permissive domain | `ansible-playbook ansible/enforce_production.yml` |
| **Outage response** | Instant relief + AVC capture | `ansible-playbook ansible/emergency_rollback.yml` |

## Recommended rollout sequence

```text
PR merge → staging canary (auto)
         → staging soak 7–14 days (monitor_avc daily)
         → prod canary host (--limit canary)
         → prod canary soak + monitor_avc
         → enforce fleet (soak gate must pass)
```

Production is **never** auto-enforced on merge.

## Phase 1 — Per-domain permissive soak

Enable permissive mode **only** for the application domain (OS stays enforcing):

```bash
sudo semanage permissive -a myapp_t
```

**Duration:** 7 to 14 days to capture edge workloads (weekly backups, log rotation, certificate renewals, systemd restarts).

The canary playbook records a deploy timestamp at `{{ var_dir }}/selinux_canary_deployed_at`. Production enforce refuses to run until soak requirements pass (unless `force_enforce=true` break-glass).

## Phase 2 — Path labeling verification

After `semodule -i`, existing files may retain old contexts. Verify before restarting the service:

```bash
sudo bash scripts/verify_file_contexts.sh \
  --install-root /opt/myapp \
  --var-dir /var/myapp \
  --app-name myapp
```

This runs `matchpathcon` on key paths and fails if `restorecon -Rv -n` would relabel anything under the data directory (venv checks are narrowed for FCOS).

Always run verification immediately after policy install and before `systemctl restart`.

## Phase 3 — Systemd and cron attestation

Staging tests must use **systemd**, not manual `python app.py`:

```bash
sudo systemctl restart myapp.service
sudo systemctl is-active myapp.service
curl -sf http://127.0.0.1:8888/rotate-log
```

**Cron (optional soak test on staging):**

```bash
# Example: daily backup script under myapp_t
echo '0 2 * * * root /opt/myapp/bin/backup.sh' | sudo tee /etc/cron.d/myapp-backup-smoke
```

PoC validates log rotation via HTTP `/rotate-log`. Real `logrotate` cron requires capturing AVCs from `logrotate_t` and extending policy — not included in the PoC module.

**Monitoring agents (Datadog, Promtail, Prometheus):** org-specific domains — verify manually during soak if agents read `/var/myapp`.

## Phase 4 — Daily AVC monitoring

During soak, run daily (cron example):

```bash
# /etc/cron.d/myapp-selinux-monitor
0 8 * * * root /opt/myapp/scripts/monitor_avc.sh --domain myapp_t --max-avc 0 >> /var/log/myapp_avc_monitor.log 2>&1
```

Or from the repo on the host:

```bash
bash scripts/monitor_avc.sh --domain myapp_t --paths /opt/myapp,/var/myapp --max-avc 0
```

## Phase 5 — Production canary host groups

Copy [`ansible/inventory.production.example.yml`](../ansible/inventory.production.example.yml) to `ansible/inventory.production.yml`.

```bash
# 1. Canary node only (permissive + policy install)
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit canary \
  -e "policy_pp_path=$(pwd)/selinux/myapp.pp"

# 2. Daily monitoring on canary during soak
bash scripts/monitor_avc.sh --domain myapp_t --marker-file /var/myapp/selinux_canary_deployed_at

# 3. Optional: permissive rollout to full fleet before enforce
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit production \
  -e "policy_pp_path=$(pwd)/selinux/myapp.pp"

# 4. Enforce (soak gate runs automatically)
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e "policy_pp_path=$(pwd)/selinux/myapp.pp"

# Break-glass only:
ansible-playbook ... enforce_production.yml -e "force_enforce=true"
```

## Phase 6 — Emergency rollback

If enforce causes an outage:

1. `semanage permissive -a myapp_t` (via `emergency_rollback.yml`) — no reboot
2. Export AVCs: `ausearch -m avc -ts recent > /tmp/prod_outage_denials.log`
3. Feed log to AI generator: `ansible-playbook ansible/emergency_rollback.yml`

See [`ansible/emergency_rollback.yml`](../ansible/emergency_rollback.yml).

## Enforce pre-checks (automated)

`enforce_production.yml` runs before removing permissive:

1. `check_soak_ready.sh` — minimum soak days + AVC count threshold
2. `verify_file_contexts.sh` — labeling dry-run
3. `systemctl restart` + endpoint smoke tests

## CI mapping (developer PR)

| Admin PR table row | CI job |
| --- | --- |
| No over-permissive grants | `forbidden-patterns` |
| Compilation test | `compile-policy` |
| Canary readiness | staging canary on merge |
