# SELinux PaC — optional paced walkthrough

Present the two-host lab with the typewriter scripts. Day-to-day work starts at [README.md](../../README.md).

**Follow:** [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) — especially [Present this lab (three terminals)](../admin/RHEL_TWO_HOST.md#present-this-lab-three-terminals).

## Run it end to end

Both VMs up (`192.168.64.6` / `192.168.64.5`). From the Mac, `ssh ansible@…` to each without a password prompt. Repo root: `/Users/asaran/projects/selinux-pac`.

Re-run on the same VMs: `bash scripts/reset_demo_vms.sh` then start [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) at Part 1.

**Customer talk (press Enter):**

```bash
# Window 1 — Mac
cd /Users/asaran/projects/selinux-pac
bash scripts/demo_e2e_mac.sh

# Window 2 — when the Mac says switch
ssh ansible@192.168.64.6
# then: bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part app
# later: --part generate   and   --part generate --skip-export

# Window 3 — when the Mac says switch
ssh ansible@192.168.64.5
# then, in order: bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app
#   --part rpms  --part soak  --part soak-avc  --part fail  --part restore  --part retest
```

**Rehearsal (one window):** `bash scripts/demo_e2e_mac.sh --auto --no-type`

**Talk-only:** `--dry-run`. **7-day refuse instead of talk-only enforce:** `DEMO_PROD_FORCE_ENFORCE=false bash scripts/demo_e2e_mac.sh`.

| Window | Script | Where you type |
|--------|--------|----------------|
| Mac (Ansible controller) | `bash scripts/demo_e2e_mac.sh` | Repo root on the Mac |
| rhel-qa | `bash scripts/demo_e2e_rhel_qa.sh --part app` then `--part generate` (later `--skip-export`) | SSH session on the QA VM |
| rhel-prod | `bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app` then `--part rpms`, `--part soak`, `--part soak-avc`, `--part fail`, `--part restore`, `--part retest` | SSH session on the prod VM |

Flags: `--dry-run` (talk track only), `--auto` (no pauses; the Mac script also SSHs and runs the VM talk tracks), `--no-type` (no typewriter).

Talk-only prod enforce (default): `force_enforce=true` plus `-e change_ticket=DEMO` so the recording can treat a **clean** soak as complete. `inventory.production.yml` still has `soak_min_days: 7`. To show the 7-day refuse instead:

```bash
DEMO_PROD_FORCE_ENFORCE=false bash scripts/demo_e2e_mac.sh
```

GitHub PR after generate (Mac, needs `gh auth login`): `bash scripts/demo_open_generated_pr.sh` opens the PR on **[anurag-saran/myapp](https://github.com/anurag-saran/myapp)**. CI jobs **forbidden-patterns** and **version-consistency** on that repo should pass — the generator already ran the forbidden-pattern check. Do not use `open_demo_policy_pr.sh` (frozen 1.1.1 snapshot).

---

## Two-act story the scripts tell

| Act | What you show |
|-----|----------------|
| **1 — from scratch** | On rhel-qa: app **unconfined** (empty AVC log) → create domain live → second curls produce `myapp_t` AVCs → generate first real `.te` in **~/myapp** → copy to Mac → **GitHub PR on anurag-saran/myapp** (CI `forbidden-patterns` green) → canary/enforce on QA → RPMs on prod → canary → **soak: HTTP 200, AVC file clean** (`soak_monitor` passes) → talk-only prod enforce (treat soak as complete) |
| **2 — outage, restore, PaC** | `curl /feature-spool` on **rhel-prod** returns **500** → `emergency_rollback.yml` (`myapp_t` permissive; host still Enforcing) → app **200** again → copy AVC log to rhel-qa → generate `--skip-export` → **second PR** → recanary prod (`soak_monitor` should pass) → curl succeeds under the new module |

Do **not** canary the committed `1.1.x` module before generate. Do **not** overlay or mention `selinux/stub/` (training labs only).

---

## `selinux/` on rhel-qa (say this **after** `write_domain_seed.sh` in `--part app`)

Full table: [RHEL_TWO_HOST.md §2f](../admin/RHEL_TWO_HOST.md#2f-create-the-confined-domain-then-collect-avcs).

| Path | One line |
|------|----------|
| `myapp.te` / `.fc` | After the live seed: types + labels. After `--apply`: generated allows. Git 1.1.3 is CI only — do not load it. |
| `policy_version.txt` | Lockstep with `policy_module()`; RPM/PR bump |
| `myapp.pp` | Compiled on rhel-qa only (gitignored) |
| `myapp_ports.cil` | Optional FCOS portcon; RHEL canary uses seport |
| `myapp_canary.te` / `.fc` | Optional overlay without semanage; not this talk |
| `payments/` | Second onboarded app; not this talk |
| `policy_out/` | `avc.log`, candidate `.te`/`.fc`, `pr_body.md` |

---

Optional hands-on labs (on **rhel-qa**, not macOS): [SELINUX_TRAINING_LAB.md](SELINUX_TRAINING_LAB.md). Those labs may still mention a training stub; the customer talk track does not.

**Ship path:** [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) → [ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md) → [DENIAL_RESPONSE.md](../admin/DENIAL_RESPONSE.md) → [PRODUCTION_READINESS.md](../admin/PRODUCTION_READINESS.md).
