# Ansible operations (AWX / ansible-playbook)

Ansible is the **control plane** for SELinux policy deploy on RHEL hosts. CI and Tekton build RPMs; playbooks install and soak them.

## Playbooks

| Playbook | Purpose |
|----------|---------|
| [`ansible/deploy_canary.yml`](../ansible/deploy_canary.yml) | Install policy, permissive soak, smoke tests |
| [`ansible/soak_monitor.yml`](../ansible/soak_monitor.yml) | Scheduled AVC / net-new threshold check |
| [`ansible/soak_status.yml`](../ansible/soak_status.yml) | Read-only soak facts (enforce readiness) |
| [`ansible/enforce_production.yml`](../ansible/enforce_production.yml) | Soak gate, remove permissive, enforce smoke |
| [`ansible/emergency_rollback.yml`](../ansible/emergency_rollback.yml) | Permissive relief + optional RPM downgrade |
| [`ansible/reset_host_state.yml`](../ansible/reset_host_state.yml) | `semodule -B`, clear permissive |

Role: [`ansible/roles/selinux_pac/`](../ansible/roles/selinux_pac/).

## AWX job templates (recommended)

| Template | Playbook | Schedule |
|----------|----------|----------|
| SELinux – Canary | `deploy_canary.yml` | On release / manual |
| SELinux – Soak monitor | `soak_monitor.yml` | Daily on canary hosts |
| SELinux – Soak status | `soak_status.yml` | Before enforce approval |
| SELinux – Enforce | `enforce_production.yml` | Manual + approval |
| SELinux – Rollback | `emergency_rollback.yml` | Break-glass |

Survey / extra-vars: `app_name`, `app_manifest_path`, `selinux_pac_package`, `force_enforce`, `soak_max_net_new`, `soak_max_avc`.

## Production inventory

Copy [`ansible/inventory.production.example.yml`](../ansible/inventory.production.example.yml). Targets use:

- `selinux_ops_from_package: true`
- `app_manifest_path: /etc/<app>/selinux-manifest.yml`
- No git checkout on hosts

## Soak gates

- **Net-new** (default): `collect_soak_facts.sh` / enforce role use `avc_net_new_count` vs installed policy (`sesearch`).
- **Fail-closed**: without `setools-console`, fall back to raw `avc_count_since_marker`.

See [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) and [ansible/README.md](../ansible/README.md).
