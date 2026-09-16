# SELinux Policy-as-Code

RHEL admins and application developers ship SELinux policy together: **PRs from dev**, **RPMs + Ansible/AWX on prod**. Only playbooks mutate SELinux on servers.

`myapp` is a **reference app**. Training labs are optional ([docs/README.md](docs/README.md)).

| You are | Start here |
|---------|------------|
| **RHEL admin / SRE** | [docs/admin/RHEL_TWO_HOST.md](docs/admin/RHEL_TWO_HOST.md) → [docs/admin/ANSIBLE_OPERATIONS.md](docs/admin/ANSIBLE_OPERATIONS.md) → [docs/admin/PRODUCTION_READINESS.md](docs/admin/PRODUCTION_READINESS.md) |
| **Application developer** | [Developers](#developers) and [docs/developers/ONBOARDING.md](docs/developers/ONBOARDING.md) |
| **Offline check (any laptop)** | `make check` |

**Security model:** `getenforce` stays **Enforcing**. Only the app domain is permissive during canary soak (`semanage permissive -a <domain>`). Enforce removes that flag after soak gates pass.

```text
Dev (rhel-dev)     AVC → deterministic_gen.py → PR (CI compile + forbidden patterns)
Admin (controller) compile_and_validate.sh → signed RPMs → internal repo
Prod  (rhel-prod)  deploy_canary.yml → soak_monitor.yml → soak_status.yml → enforce_production.yml
```

---

## Admins

Controller (laptop or AWX) SSHes to two RHEL boxes. **No git clone on prod.** Install `selinux-policy-ops` + `<app>-selinux` from a **signed internal yum/dnf repo**. Compile image: set `SELINUX_BUILD_IMAGE` to an internal mirror ([docs/admin/COMPILE_IMAGE.md](docs/admin/COMPILE_IMAGE.md)).

```bash
# Inventories (gitignored)
bash scripts/setup_rhel_hosts.sh write --dev-host rhel-dev.example.com --prod-host rhel-prod.example.com
bash scripts/setup_rhel_hosts.sh ping
bash scripts/setup_rhel_hosts.sh doctor

# Package + publish (see packaging/internal.env.example)
bash packaging/build_rpms.sh
bash packaging/publish_internal.sh

# Prod lifecycle (AWX job templates in docs/admin/ANSIBLE_OPERATIONS.md)
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary   # schedule daily
ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e change_ticket=CHG123
```

Enforce **requires** `change_ticket`. `force_enforce=true` is break-glass only and still needs that ticket (AWX survey defaults `force_enforce` to false). Soak is **net-new** vs installed policy (`sesearch`); `setools-console` is a **hard RPM require**.

Rollback (no API key): `ansible-playbook -i ansible/inventory.production.yml ansible/emergency_rollback.yml --limit canary`

Playbook variables and task order: [ansible/README.md](ansible/README.md). Adoption: [docs/admin/ADOPTION_CHECKLIST.md](docs/admin/ADOPTION_CHECKLIST.md).

---

## Developers

On **rhel-dev** (repo checkout, SELinux Enforcing):

```bash
sudo bash scripts/setup_staging_env.sh          # reference app; skip for your own service
bash scripts/dev_generate_policy.sh --apply     # deterministic engine; optional --llm-summary
bash scripts/assemble_pr_body.sh
gh pr create --body-file policy_out/pr_body.md --label security --label selinux
```

CI must pass `smoke-tests`, `app-manifest`, `forbidden-patterns`, `compile-policy`. CODEOWNERS (`@anurag-saran`) review `selinux/` and `ansible/`.

New app: `bash scripts/selinux_pac_adopt.sh init payments` — [docs/developers/ONBOARDING.md](docs/developers/ONBOARDING.md).

Ports stay in the committed manifest (`selinux_ports`). Probe host/IP is per inventory (`http_probe_host`).

---

## Layout

```text
config/       App manifests (bind ports, probes, domains)
selinux/      Policy source of truth (.te/.fc, policy_version.txt)
ansible/      selinux_pac role — canary, soak, enforce, rollback
packaging/    selinux-policy-ops + <app>-selinux specs; publish_internal.sh
scripts/      setup_rhel_hosts.sh, compile, ops scripts (also in the ops RPM)
docs/admin/   RHEL + Ansible runbooks
docs/developers/  Onboarding, generator, tests
```

---

## Safety

- Never `force_enforce` without a change ticket. Never copy `soak_min_days: 0` from `inventory.dev.yml` onto prod (enforce refuses it on the `production` group).
- Optional LLM polishes `pr_summary.md` only. Legacy `--legacy-full-policy` is emergency/controller-only.
- Host CLI `apply_policy.sh` is **not** the control plane (skips AWX, RPMs, `serial: 1`).

Podman / `--use-vm` is a laptop **backup** when the RHEL boxes are not available: [docs/training/SELINUX_TRAINING_LAB.md](docs/training/SELINUX_TRAINING_LAB.md).
