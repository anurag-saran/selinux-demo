# Adoption checklist

Use this when forking or rolling out SELinux Policy-as-Code in your org.

## Repository and CI

- [ ] Replace `@your-org/security-team` in [`.github/CODEOWNERS`](../.github/CODEOWNERS)
- [ ] Enable branch protection: `smoke-tests`, `compile-policy`, `forbidden-patterns`, `app-manifest`, `version-consistency`
- [ ] Mirror SELinux compile image internally ([`docs/DOCKER_HUB_COMPILE_IMAGE.md`](DOCKER_HUB_COMPILE_IMAGE.md))

## Per application

- [ ] Add `config/<app>.manifest.yml` ([`config/README.md`](../config/README.md))
- [ ] Policy under `selinux/<app>/` or `selinux/` with version in `policy_version.txt`
- [ ] Build `<app>-selinux` RPM ([`packaging/build_rpms.sh`](../packaging/build_rpms.sh))

## Ansible / AWX

- [ ] Copy inventory from [`ansible/inventory.production.example.yml`](../ansible/inventory.production.example.yml)
- [ ] Install `selinux-policy-ops` RPM on targets
- [ ] AWX project → `ansible/` path; job templates per [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md)
- [ ] Schedule `soak_monitor.yml` on canary hosts

## Optional

- [ ] Tekton pipelines ([`docs/TEKTON.md`](TEKTON.md)) → RPM → AWX webhook
- [ ] Self-hosted GHA runners `selinux-staging` / `selinux-production` for [`selinux-deploy.yml`](../.github/workflows/selinux-deploy.yml)

## Admin runbook

- [ ] [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) — soak, enforce, incident card
