# Adoption checklist

Use this when forking or rolling out **SELinux PaC** in your org. **Ansible Automation Platform (AAP) is the production control plane** ([ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md)).

Trying it first on a laptop: [README — Try it on a Mac](../../README.md#try-it-on-a-mac) (two RHEL VMs + `setup_rhel_hosts.sh`). This checklist is the **customer** path.

## Host doctor

```bash
bash scripts/setup_rhel_hosts.sh write --dev-host DEV --prod-host PROD
bash scripts/setup_rhel_hosts.sh ping
bash scripts/setup_rhel_hosts.sh doctor
bash scripts/selinux_pac_adopt.sh init <app>
```

Two-host layout: [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md).

## Repository and CI

- [ ] Confirm [`.github/CODEOWNERS`](../../.github/CODEOWNERS) (`@anurag-saran` or your platform team)
- [ ] Enable branch protection: `forbidden-patterns`, `version-consistency` ([`selinux-policy-ci.yml`](../../.github/workflows/selinux-policy-ci.yml); generator already ran the forbidden-pattern check)
- [ ] Compile policy on RHEL with `selinux-policy-devel` (`dnf install selinux-policy-devel`)

## Per application

- [ ] Add `config/<app>.manifest.yml` ([`config/README.md`](../../config/README.md)) — **bind ports** in `selinux_ports` (stable across env); **probe host/IP** in inventory
- [ ] Policy under `selinux/<app>/` or `selinux/` with version in `policy_version.txt`
- [ ] Scaffold: `bash scripts/scaffold_sepolicy_module.sh <app> <app>_t`
- [ ] Build `<app>-selinux` RPM ([`packaging/build_rpms.sh`](../../packaging/build_rpms.sh))

## Ansible Automation Platform (AAP)

- [ ] Generate inventories: `bash scripts/setup_rhel_hosts.sh write --dev-host … --prod-host …` ([RHEL_TWO_HOST.md](RHEL_TWO_HOST.md))
- [ ] Copy examples if you prefer: [`ansible/inventory.dev.example.yml`](../../ansible/inventory.dev.example.yml), [`ansible/inventory.production.example.yml`](../../ansible/inventory.production.example.yml)
- [ ] Signed internal RPM repo: `cp packaging/internal.env.example packaging/internal.env` then `bash packaging/publish_internal.sh`
- [ ] `selinux-policy-ops` **Requires** `setools-console` — install both on **prod**
- [ ] AAP project → `ansible/` path; create job templates and workflows from [`ansible/aap/`](../../ansible/aap/)
- [ ] Attach [`ansible/aap/survey_enforce.json`](../../ansible/aap/survey_enforce.json) to the AAP Enforce job template (`change_ticket` required, `force_enforce` default false)
- [ ] Schedule **SELinux – Soak monitor** daily on the prod canary host; attach a Controller notification template (job failed)
- [ ] Production host: **no git clone**; `selinux_ops_from_package: true`
- [ ] Denial after ship: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md) (PR + recanary, not live `semodule -i`)

## Optional

- [ ] Two-host talk track: [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md) / [DEMO_GUIDE.md](../training/DEMO_GUIDE.md)

## Admin runbook

- [ ] [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) — soak, enforce, incident card
- [ ] [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md) — file/port AVC after ship
