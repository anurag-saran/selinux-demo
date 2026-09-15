# Documentation map (start here)

All guides in this folder use the same **beginner-friendly pattern** where it matters:

| Pattern | Meaning |
|---------|---------|
| **Why** | What real problem this step solves |
| **Where** | Which machine and directory (Mac vs Linux VM vs RHEL server vs repo root) |
| **What / good sign** | What the command does and how you know it worked |
| **Checkpoint** | A question you should be able to answer before moving on (labs and some runbooks) |

**Terms** like domain, AVC, `.te`, and **`semanage`** are defined in [SELINUX_BASICS.md](SELINUX_BASICS.md) and repeated in short glossaries where you need them.

---

## Recommended reading order

| Step | Document | Time | You need |
|------|----------|------|----------|
| 1 | [SELINUX_BASICS.md](SELINUX_BASICS.md) §1–7 | ~20 min read | Nothing — concepts only |
| 2 | [SELINUX_TRAINING_LAB.md](SELINUX_TRAINING_LAB.md) | ~90–120 min | SELinux Linux or [Podman VM on macOS](SELINUX_TRAINING_LAB.md#running-on-macos) |
| 3 | [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md) | ~30–45 min | Optional while doing step 2 |
| 4 | [DEMO_GUIDE.md](DEMO_GUIDE.md) | Workshop | Staging host or `--use-vm` on Mac |
| 5 | [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) | Admin checklist | RHEL/Fedora fleet |

**Contributors (no SELinux on laptop):** from repo root run `make check` — see [TESTING.md](TESTING.md) §1.6.

---

## Find the right guide

| Document | Best for |
|----------|----------|
| [SELINUX_BASICS.md](SELINUX_BASICS.md) | First-time SELinux: labels, policy files, permissive soak |
| [SELINUX_TRAINING_LAB.md](SELINUX_TRAINING_LAB.md) | Hands-on commands before the workshop |
| [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md) | Repo layout and which script to run when |
| [DEMO_GUIDE.md](DEMO_GUIDE.md) | Presenting or following the 10-act workshop |
| [TESTING.md](TESTING.md) | CI, `make check`, integration endpoints |
| [DETERMINISTIC_POLICY.md](DETERMINISTIC_POLICY.md) | Offline AVC → policy engine (default) |
| [DOCKER_HUB_COMPILE_IMAGE.md](DOCKER_HUB_COMPILE_IMAGE.md) | Compile policy in a container (Mac or CI) |
| [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) | Canary → soak → enforce on real servers |
| [SELINUX_BEST_PRACTICES.md](SELINUX_BEST_PRACTICES.md) | How to write policy this repo accepts |
| [ONBOARDING_SECOND_APP.md](ONBOARDING_SECOND_APP.md) | Second app (`payments`) manifest + module |
| [examples/README.md](examples/README.md) | Curated PR samples for offline demos |

Repo entry point: [../README.md](../README.md). App manifest schema: [../config/README.md](../config/README.md). Ansible playbooks: [../ansible/README.md](../ansible/README.md).
