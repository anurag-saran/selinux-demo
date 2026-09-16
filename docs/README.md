# Documentation map (start here)

This tree is the **admin + developer tool**. Training labs are optional.

| Pattern | Meaning |
|---------|---------|
| **Why** | What real problem this step solves |
| **Where** | Which machine and directory (controller vs RHEL server vs repo root) |
| **What / good sign** | What the command does and how you know it worked |

**Terms** like domain, AVC, `.te`, and **`semanage`** are defined in [SELINUX_BASICS.md](policy/SELINUX_BASICS.md).

---

## Recommended reading order

| Step | Document | You need |
|------|----------|----------|
| 1 | [RHEL_TWO_HOST.md](admin/RHEL_TWO_HOST.md) | Two RHEL boxes + Ansible from a controller |
| 2 | [ANSIBLE_OPERATIONS.md](admin/ANSIBLE_OPERATIONS.md) | AAP / ansible-playbook (control plane) |
| 3 | [DENIAL_RESPONSE.md](admin/DENIAL_RESPONSE.md) | File or port denied after ship |
| 4 | [PRODUCTION_READINESS.md](admin/PRODUCTION_READINESS.md) | Soak, enforce, rollback, incident card |
| 5 | [ONBOARDING.md](developers/ONBOARDING.md) | Point a developer at a new app |
| 6 | [ADOPTION_CHECKLIST.md](admin/ADOPTION_CHECKLIST.md) | CODEOWNERS, RPM repo, branch protection |
| 7 | [SELINUX_BASICS.md](policy/SELINUX_BASICS.md) §1–7 | Optional — SELinux concepts |
| 8 | [SELINUX_TRAINING_LAB.md](training/SELINUX_TRAINING_LAB.md) / [DEMO_GUIDE.md](training/DEMO_GUIDE.md) | Optional training (`--demo-mode` skips 7-day soak) |

**Contributors (no SELinux on laptop):** from repo root run `make check` — see [TESTING.md](developers/TESTING.md) §1.6.

---

## Find the right guide

| Document | Best for |
|----------|----------|
| [RHEL_TWO_HOST.md](admin/RHEL_TWO_HOST.md) | **Two RHEL boxes** (dev + prod); Podman backup |
| [ANSIBLE_OPERATIONS.md](admin/ANSIBLE_OPERATIONS.md) | **AAP hub** — `ansible/aap/` workflows, soak, enforce |
| [DENIAL_RESPONSE.md](admin/DENIAL_RESPONSE.md) | Prod AVC: rollback or soak-fail → PR, not live patch |
| [PRODUCTION_READINESS.md](admin/PRODUCTION_READINESS.md) | Canary → soak (net-new) → enforce on real servers |
| [ONBOARDING.md](developers/ONBOARDING.md) | Point a developer at a second app (`payments`) |
| [ADOPTION_CHECKLIST.md](admin/ADOPTION_CHECKLIST.md) | Fork/org wiring: CODEOWNERS, inventories, RPMs |
| [SELINUX_BEST_PRACTICES.md](policy/SELINUX_BEST_PRACTICES.md) | How to write policy this repo accepts |
| [SELINUX_BASICS.md](policy/SELINUX_BASICS.md) | First-time SELinux: labels, policy files, permissive soak |
| [CODE_WALKTHROUGH.md](training/CODE_WALKTHROUGH.md) | Repo layout and which script to run when |
| [TESTING.md](developers/TESTING.md) | CI, `make check`, integration endpoints (staged + batch) |
| [DETERMINISTIC_POLICY.md](developers/DETERMINISTIC_POLICY.md) | Offline AVC → policy engine (default) |
| [COMPILE_IMAGE.md](admin/COMPILE_IMAGE.md) | Internal compile image + signed RPM repo |
| [SELINUX_TRAINING_LAB.md](training/SELINUX_TRAINING_LAB.md) | Optional hands-on labs (not the ship path) |
| [DEMO_GUIDE.md](training/DEMO_GUIDE.md) | Optional 10-act walkthrough (`--demo-mode` skips calendar soak) |
| [examples/README.md](examples/README.md) | Curated PR samples for offline demos |

Repo entry point: [../README.md](../README.md). App manifest schema: [../config/README.md](../config/README.md). Ansible playbooks: [../ansible/README.md](../ansible/README.md). New app: `bash scripts/selinux_pac_adopt.sh init <app>`.
