# 304 — Adoption checklist

Use this when rolling out **SELinux PaC** in your org. **Ansible Automation Platform (AAP) is the production control plane** ([301-ANSIBLE_OPERATIONS.md](301-ANSIBLE_OPERATIONS.md)).

Trying it first on a laptop: [README — Try it on a Mac](../../README.md#try-it-on-a-mac) (two RHEL VMs + `setup_rhel_hosts.sh`). This checklist is the **customer** path. The two-host lab generates **shopapi** policy into `selinux/shopapi/` on this repo; `selinux/myapp.te` is an offline generator golden.

## Where policy lives

Customer end-state: **policy is tracked with the app**.

| Place | What it holds |
|-------|----------------|
| **Each app GitHub repo** | `selinux/` (`.te` `.fc` `policy_version.txt`), `config/<app>.manifest.yml`, app code. Policy PRs land **here**. |
| **selinux-pac (this repo, or your fork)** | Generator, Policy CI workflow to copy/reuse, AAP playbooks, `selinux-policy-ops` packaging. Not the live allow list for your product. |
| **rhel-qa** | Deploy the candidate **app build**. Collect AVCs. Run `dev_generate_policy.sh`. Compile with `selinux-policy-devel`. Never the laptop; never prod. |
| **rhel-prod** | RPMs + AAP only. **No git clone** of the app or of selinux-pac. |

Copy [`.github/workflows/selinux-policy-ci.yml`](../../.github/workflows/selinux-policy-ci.yml) into the **app** repo (or call it as a reusable workflow). Require `forbidden-patterns` on `selinux/` (platform CODEOWNERS). RPM NVR follows the app’s `policy_version.txt`.

Discovery sequence on QA: [206-ONBOARDING.md](../developers/206-ONBOARDING.md) (unconfined or last module → AVCs → generate → app-repo PR → RPM → AAP).

## Host doctor

```bash
bash scripts/setup_rhel_hosts.sh write --qa-host QA --prod-host PROD
# --dev-host is the same flag (legacy name)
bash scripts/setup_rhel_hosts.sh ping
bash scripts/setup_rhel_hosts.sh doctor
bash scripts/selinux_pac_adopt.sh init <app>
```

Two-host lab (reference `myapp`): [203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md).

## Repository and CI

- [ ] App repo: `selinux/` + manifest; Policy CI on that repo’s PRs
- [ ] Platform CODEOWNERS (or required check) on `selinux/` so app-only merge cannot skip forbidden-patterns
- [ ] This fork: confirm [`.github/CODEOWNERS`](../../.github/CODEOWNERS) for the **tool**
- [ ] Compile policy on **rhel-qa** with `selinux-policy-devel` (`dnf install selinux-policy-devel`)

## Per application (in the **app** repo)

- [ ] Add `config/<app>.manifest.yml` ([`config/README.md`](../../config/README.md)) — **bind ports** in `selinux_ports` (stable across env); **probe host/IP** in inventory
- [ ] Policy under `selinux/<app>/` or `selinux/` with version in `policy_version.txt`
- [ ] Scaffold on QA: `bash scripts/scaffold_sepolicy_module.sh <app> <app>_t` (or the types-only seed path in [203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md) for a first confine)
- [ ] Build `<app>-selinux` RPM from the **app** tree after merge ([`packaging/build_rpms.sh`](../../packaging/build_rpms.sh) pattern)

## Ansible Automation Platform (AAP)

- [ ] Generate inventories: `bash scripts/setup_rhel_hosts.sh write --qa-host … --prod-host …` ([203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md))
- [ ] Copy examples if you prefer: [`ansible/inventory.dev.example.yml`](../../ansible/inventory.dev.example.yml) (QA / discovery; host `rhel-qa`), [`ansible/inventory.production.example.yml`](../../ansible/inventory.production.example.yml)
- [ ] Signed internal RPM repo: `cp packaging/internal.env.example packaging/internal.env` then `bash packaging/publish_internal.sh`
- [ ] `selinux-policy-ops` **Requires** `setools-console` — install both on **prod**
- [ ] AAP project → `ansible/` path; create job templates and workflows from [`ansible/aap/`](../../ansible/aap/)
- [ ] Attach [`ansible/aap/survey_enforce.json`](../../ansible/aap/survey_enforce.json) to the AAP Enforce job template (`change_ticket` required, `force_enforce` default false)
- [ ] Schedule **SELinux – Soak monitor** daily on the prod canary host; attach a Controller notification template (job failed)
- [ ] Production host: **no git clone**; `selinux_ops_from_package: true`
- [ ] Denial after ship: [303-DENIAL_RESPONSE.md](303-DENIAL_RESPONSE.md) (PR on the **app** repo + recanary, not live `semodule -i`)

## Optional

- [ ] Customer talk: [202-DEMO_GUIDE.md](../training/202-DEMO_GUIDE.md) (`demo_present.sh`). Two-host pipeline: [203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md) (reference `myapp` in this clone; say “your repo would hold `selinux/`”)

## Admin runbook

- [ ] [302-PRODUCTION_READINESS.md](302-PRODUCTION_READINESS.md) — soak, enforce, incident card
- [ ] [303-DENIAL_RESPONSE.md](303-DENIAL_RESPONSE.md) — file/port AVC after ship
