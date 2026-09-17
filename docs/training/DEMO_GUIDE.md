# SELinux PaC — optional paced walkthrough

Present the two-host lab with the typewriter scripts. Day-to-day work starts at [README.md](../../README.md).

**Follow:** [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) — especially [Present this lab (three terminals)](../admin/RHEL_TWO_HOST.md#present-this-lab-three-terminals).

| Window | Script | Where you type |
|--------|--------|----------------|
| Mac (Ansible controller) | `bash scripts/demo_e2e_mac.sh` | Repo root on the Mac |
| rhel-dev | `bash scripts/demo_e2e_rhel_dev.sh` | SSH session on the dev VM |
| rhel-prod | `bash scripts/demo_e2e_rhel_prod.sh` | SSH session on the prod VM |

Flags: `--dry-run` (talk track only), `--auto` (no pauses; the Mac script also SSHs and runs the VM talk tracks), `--no-type` (no typewriter).

Optional hands-on labs (on **rhel-dev**, not macOS): [SELINUX_TRAINING_LAB.md](SELINUX_TRAINING_LAB.md).

**Ship path:** [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) → [ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md) → [DENIAL_RESPONSE.md](../admin/DENIAL_RESPONSE.md) → [PRODUCTION_READINESS.md](../admin/PRODUCTION_READINESS.md).
