# App manifest

Each application onboarded to the SELinux Policy-as-Code pipeline declares an **app manifest** — a YAML file that drives readiness checks, deploy reports, and inventory defaults.

**Why manifests exist:** scripts and Ansible need one place for app name, paths, domains, and HTTP probes — so nothing silently assumes **`myapp`**.

**Where you edit files:** `config/<app>.manifest.yml` in your **git clone** (repo root). **Where validation runs:** same machine as your shell at repo root (`validate_app_manifest.sh`, CI).

**More context:** [ONBOARDING_SECOND_APP.md](../docs/ONBOARDING_SECOND_APP.md), [docs/README.md](../docs/README.md).

## Quick start

1. Copy [`payments.manifest.example.yml`](payments.manifest.example.yml) to `config/<app_name>.manifest.yml`.
2. Fill in paths, systemd units, HTTP probes, and SELinux port types.
3. Scaffold policy on RHEL: `bash scripts/scaffold_sepolicy_module.sh payments payments_t` (see [ONBOARDING_SECOND_APP.md](../docs/ONBOARDING_SECOND_APP.md)).
4. Point scripts and Ansible at it:

```bash
export APP_MANIFEST=config/payments.manifest.yml
bash scripts/wait_for_endpoints.sh --manifest "$APP_MANIFEST"
bash scripts/validate_app_manifest.sh config/payments.manifest.yml
```

Default (when `APP_MANIFEST` is unset): `config/${POLICY_APP:-myapp}.manifest.yml`.

## Schema

| Key | Required | Description |
|-----|----------|-------------|
| `app_name` | yes | Module prefix (`payments` → `payments_t`, `payments_port_t`) |
| `domain` | yes | Primary process domain |
| `paths.install_root` | yes | Application install tree |
| `paths.var_dir` | yes | State directory (`StateDirectory`) |
| `paths.log_dir` | recommended | Log directory (`LogsDirectory`) |
| `paths.runtime_dir` | recommended | Runtime dir (`RuntimeDirectory`) |
| `services.primary.unit` | yes | Main systemd unit |
| `services.primary.domain` | no | Defaults to `domain` |
| `services.backend` | no | Second unit (microservice / sidecar) |
| `http.host` | no | Default `127.0.0.1` |
| `http.port` | yes | App HTTP port for probes |
| `http.endpoints` | yes | Path list (GET, expect HTTP 200) |
| `http.backend.port` | if backend | Backend health port |
| `http.backend.health_path` | if backend | Default `/health` |
| `selinux_ports` | recommended | Port → type for canary `seport` / RPM |
| `integration_tests.command` | no | Documented soak/discovery test command |
| `policy.module_dir` | no | Default `selinux` |
| `deploy.soak_marker_file` | no | Default `{var_dir}/selinux_canary_deployed_at` |
| `deploy.deploy_report_file` | no | Default `{var_dir}/selinux_deploy_report.json` |

## What reads the manifest

| Consumer | Purpose |
|----------|---------|
| [`scripts/wait_for_endpoints.sh`](../scripts/wait_for_endpoints.sh) | systemd units, HTTP probes, domain verification |
| [`scripts/post_deploy_report.sh`](../scripts/post_deploy_report.sh) | Deploy JSON service/domain fields |
| [`scripts/check_soak_ready.sh`](../scripts/check_soak_ready.sh) | Domain context keys in deploy report; optional **`--auto-tier`** with policy pair paths |
| Ansible role / playbooks | `app_manifest_path` inventory var (prod: RPM path under `/etc/myapp/`) |
| [`cli/deterministic_gen.py`](../cli/deterministic_gen.py) | `--manifest` for path → `.fc` labeling rules (`fc_fix` / `fc_drift`) |
| [`scripts/validate_app_manifest.sh`](../scripts/validate_app_manifest.sh) | CI / onboarding validation |

## Designing probes for a new app

1. List SELinux surfaces the app touches (files, ports, IPC, scripts).
2. Map each surface to either:
   - an entry in `http.endpoints` (synthetic probe), or
   - `integration_tests.command` (real test suite under permissive).
3. Always include `services.primary` and real health path(s).
4. Run staging permissive → export AVCs → generate policy (`bash scripts/dev_generate_policy.sh`; default **`deterministic_gen.py`**, optional `--engine llm`).

See [`docs/TESTING.md`](../docs/TESTING.md) for the full test-layer model.

## Ansible inventory

**Lab / checkout on controller:**

```yaml
vars:
  app_name: payments
  policy_artifact_dir: "{{ playbook_dir }}/.."
  app_manifest_path: "{{ policy_artifact_dir }}/config/payments.manifest.yml"
  selinux_ops_from_package: false
  selinux_ops_dir: "{{ playbook_dir }}/../scripts"
  install_root: /opt/payments
  var_dir: /var/lib/payments
  log_dir: /var/log/payments
  domain: payments_t
```

**Production:** install `myapp-selinux` RPM — manifest at **`/etc/myapp/selinux-manifest.yml`** (`app_manifest_path` in [`ansible/inventory.production.example.yml`](../ansible/inventory.production.example.yml)). Module SemVer is read from **`selinux/policy_version.txt`** under `policy_artifact_dir` (not duplicated in inventory).
