# Demo Guide — SELinux Policy-as-Code Workshop

This guide is for **presenters**, **new team members**, and **observers** who want to understand what the demo shows, why each step exists, and how to run it without prior SELinux experience.

**New to SELinux?** Start with [SELINUX_BASICS.md](SELINUX_BASICS.md) (contexts, AVCs, enforcing vs permissive).

For production deployment guardrails after the demo, see [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md).

---

## What you are demonstrating

This repository is a **proof of concept** for **Shift-Left SELinux Policy-as-Code**:

1. Application teams run their app on staging with SELinux in **permissive mode** for their domain only (`myapp_t`).
2. Denied operations are logged as **AVC** lines in the audit log — not silent failures.
3. An **AI-assisted CLI** reads those AVCs and proposes updates to version-controlled policy files (`selinux/myapp.te`, `selinux/myapp.fc`).
4. Developers open a **Pull Request** with a plain-English summary for security admins.
5. **CI** blocks over-permissive or invalid policy before merge.
6. **Admins** deploy via **canary** (still permissive), soak and monitor, then **enforce** on production with hard gates.

The demo uses a small Flask **Order Processor** app on port **8888** with endpoints that trigger realistic SELinux activity: writing logs, executing a backup script, and simulating log rotation.

---

## Two roles in the story

| Role | Responsibility in the demo |
|------|----------------------------|
| **Application team** | Run integration tests, export AVCs, generate policy, open PR |
| **Security / RHEL admin** | Review PR table, deploy canary, verify labels, soak, enforce, rollback if needed |

The presenter script [`scripts/demo_present.sh`](../scripts/demo_present.sh) walks through both roles in order so the audience sees the full handoff.

---

## Demo scripts — which one to use

| Script | Best for | Pauses? | Full story? |
|--------|----------|---------|-------------|
| **`demo_present.sh`** | Live workshops, new audiences | Yes (optional `--auto`) | Yes — 10 acts |
| **`run_demo.sh`** | Quick unattended run on native Linux | No | Partial — skips PR assembly narration |
| **`dev_generate_policy.sh`** | Real developer workflow (not a staged demo) | No | Developer path only |

**Recommendation for first-time presenters:** read this guide, rehearse with `--auto --demo-mode`, then present live without `--auto`.

---

## Prerequisites

### All platforms

- Clone this repository
- Python 3.9+ and `pip3 install -r cli/requirements.txt`
- **`OPENAI_API_KEY`** set (unless using `--skip-ai` with existing `policy_out/` files)
- Optional: `OPENAI_BASE_URL` / `OPENAI_API_MODEL` for LiteLLM or other OpenAI-compatible endpoints

### Native Linux (RHEL, Fedora, FCOS VM)

- Root or `sudo` (SELinux policy install requires it)
- SELinux **Enforcing** (or Permissive at OS level — app domain is set permissive separately)
- Packages: `audit`, `policycoreutils-python-utils`, `checkpolicy`, `selinux-policy-devel`, `ansible`, `curl`
- Port **8888** available on localhost

### macOS

- SELinux is **not** available natively — use **Podman Machine**:
  ```bash
  bash scripts/fix_podman.sh
  source ~/.local/share/selinux-demo/podman/env.sh
  ```
- Run the demo with **`--use-vm`** so staging, canary, and enforce happen inside the FCOS/RHEL-like VM

---

## How to run the demo

### First rehearsal (recommended)

Run once without an audience to confirm API key, VM, and timing:

```bash
# Native Linux
export OPENAI_API_KEY="your-key"
sudo bash scripts/demo_present.sh --demo-mode --auto

# macOS
export OPENAI_API_KEY="your-key"
bash scripts/demo_present.sh --use-vm --demo-mode --auto
```

Typical duration: **15–25 minutes** with pauses; **8–12 minutes** with `--auto`.

### Live presentation

```bash
export OPENAI_API_KEY="your-key"
sudo bash scripts/demo_present.sh --demo-mode
```

Press **Enter** at each pause to explain the next act before the commands run.

### Partial demo (time-limited)

Developer + CI story only (acts 1–5, ~8 min):

```bash
sudo bash scripts/demo_present.sh --demo-mode --auto --acts 1-5
```

Admin + guardrails story (acts 6–10, requires prior policy in `policy_out/` or run after acts 1–5):

```bash
sudo bash scripts/demo_present.sh --demo-mode --auto --acts 6-10
```

### No API key (offline rehearsal)

Requires existing `policy_out/myapp.te`, `policy_out/myapp.fc`, and preferably `policy_out/avc.log`:

```bash
sudo bash scripts/demo_present.sh --skip-ai --demo-mode --auto
```

---

## Demo mode vs production

| Topic | Production | Demo (`--demo-mode`) |
|-------|------------|----------------------|
| Permissive soak | **7–14 days** on staging / prod canary | Act 8 **pre-seeds** an 8-day-old marker |
| Enforce gate | `check_soak_ready.sh` must pass | Act 9 uses **`force_enforce=true`** (break-glass) |
| Everything else | Same commands | **Real** — not simulated |

**Say this to the audience:** demo mode shortens only the calendar wait. It does not skip CI, labeling checks, or canary deploy. Never use `force_enforce=true` in real production without documented approval.

---

## Act-by-act walkthrough

Each act prints a blue banner. Below is what happens and what to say.

### Act 1 — Staging (Application team)

**What runs:** `setup_staging_env.sh` installs the Flask app, systemd unit, permissive `myapp_t`, and hits HTTP endpoints.

**Key concepts:**
- **`semanage permissive -a myapp_t`** — only the app domain is permissive; the rest of the OS stays enforcing.
- Endpoints: `/`, `/save-log`, `/run-script`, `/rotate-log` exercise file write, script exec, and log rename.

**Talking point:** *"We intentionally run in permissive mode first so the app keeps working while we collect an accurate list of what SELinux would block."*

---

### Act 2 — AVC export (Application team)

**What runs:** Audit log lines matching `myapp` paths are saved to `policy_out/avc.log`.

**Key concepts:**
- **AVC** = Access Vector Cache denial logged by the kernel
- These lines are the **input** to the AI policy generator — not guesswork

**Talking point:** *"Every line here is evidence from our integration tests, not a generic template policy."*

**Show:** `wc -l policy_out/avc.log` or `head policy_out/avc.log`

---

### Act 3 — AI policy generation (Application team)

**What runs:** `cli/selinux_gen.py` merges AVCs into existing `selinux/myapp.te` / `.fc`, bumps `policy_version.txt`, writes `policy_out/pr_summary.md`.

**Key concepts:**
- Policy is **merged** into existing module — not replaced blindly
- Output includes structured **`pr_summary`** sections (network, filesystem, exec, denials)

**Talking point:** *"The CLI is guardrailed — CI will reject wildcards and allows to shadow_t, unconfined_t, sysadm_t."*

**Show:** `head -30 policy_out/pr_summary.md`

---

### Act 4 — PR handoff (Application team → Admin)

**What runs:** `assemble_pr_body.sh` fills the GitHub PR template with summary, AVC excerpt, policy version.

**Key concepts:**
- PR body lands in `policy_out/pr_body.md`
- Template includes **admin Pass/Reject table** mapped to CI job names

**Talking point:** *"The developer doesn't paste free-form text — the pipeline assembles what admins need to sign off."*

**Show:** `grep -E '^###|Admin|forbidden' policy_out/pr_body.md | head -20`

---

### Act 5 — CI gates (Automatic on PR)

**What runs:** `validate_forbidden_patterns.sh` + `compile_and_validate.sh` on `policy_out/`.

**Key concepts:**
- **forbidden-patterns** — blocks `allow myapp_t *:*`, high-privilege types, broad `var_t:file write`
- **compile-policy** — builds `myapp.pp` with `checkmodule`

**Talking point:** *"Admins shouldn't review syntax errors — CI catches those before merge."*

---

### Act 6 — Canary deploy (Admin)

**What runs:** `ansible/deploy_canary.yml` — installs `.pp`, `semanage permissive -a myapp_t`, `restorecon`, restarts systemd service, smoke-tests endpoints.

**Key concepts:**
- Policy module is installed but domain stays **permissive** for soak
- Marker file written: `/var/myapp/selinux_canary_deployed_at`

**Talking point:** *"We deploy the real module early, but we don't enforce until we've watched production-like workloads."*

---

### Act 7 — Production guardrails (Admin)

**What runs:** `verify_file_contexts.sh` + `monitor_avc.sh`.

**Key concepts:**
- **`restorecon -Rv -n`** dry-run — fails if files would be relabeled (mislabeled data dirs crash apps)
- **`monitor_avc.sh`** — daily admin command during soak

**Talking point:** *"The most common production surprise is wrong file labels on existing data — we verify before restart."*

---

### Act 8 — Soak period (Admin)

**What runs:** Explains 7–14 day soak. In `--demo-mode`, pre-seeds an old marker and runs `check_soak_ready.sh` successfully.

**Key concepts:**
- Weekly cron, logrotate, cert renewals may only fire after days
- **`check_soak_ready.sh`** blocks enforce until soak + zero domain AVCs (by default)

**Talking point:** *"In production we wait a full business cycle. Demo mode only skips the calendar — not the other checks."*

Without `--demo-mode`, this act **shows the gate failing** if canary was just deployed — that is expected.

---

### Act 9 — Enforce (Admin)

**What runs:** `ansible/enforce_production.yml` removes permissive flag (`semanage permissive -d myapp_t`), verifies labels, restarts service, smoke-tests.

**In demo mode:** passes `force_enforce=true` so the step completes in one session.

**Talking point:** *"After enforce, any missing permission becomes a hard denial — that's why soak and monitoring matter."*

**Show:** `semanage permissive -l` (should not list `myapp_t`) and `curl http://127.0.0.1:8888/`

---

### Act 10 — Emergency rollback (Admin)

**What runs:** Prints commands only (does not execute rollback in the workshop).

**Key concepts:**
1. **`semanage permissive -a myapp_t`** — instant relief, no reboot
2. Export AVCs → feed **`emergency_rollback.yml`** → optional AI patch

**Talking point:** *"If enforce causes an outage, the first move is permissive domain — not disabling SELinux globally."*

---

## Architecture diagram (for slides)

```text
┌──────────────┐    AVC logs     ┌──────────────┐    PR + CI    ┌──────────────┐
│  Flask app   │ ──────────────► │ selinux_gen  │ ────────────► │ GitHub PR    │
│  (myapp_t)   │                 │ + assemble   │               │ + admin review│
└──────────────┘                 └──────────────┘               └──────┬───────┘
       ▲                                                                │
       │                     canary → soak → enforce                     │
       └────────────────────────────────────────────────────────────────┘
```

---

## Key files to know

| Path | Purpose |
|------|---------|
| `app/app.py` | Demo application |
| `selinux/myapp.te` | Type enforcement (rules) — source of truth |
| `selinux/myapp.fc` | File context labels |
| `selinux/policy_version.txt` | SemVer bumped on each generation |
| `policy_out/avc.log` | Exported denials (input to AI) |
| `policy_out/pr_summary.md` | Plain-English summary for admins |
| `policy_out/pr_body.md` | Assembled GitHub PR body |
| `ansible/deploy_canary.yml` | Permissive canary deploy |
| `ansible/enforce_production.yml` | Remove permissive + enforce |
| `ansible/emergency_rollback.yml` | Outage response |
| `.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md` | Admin review template |

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---------|--------------|-----|
| `OPENAI_API_KEY not set` | Missing env var | `export OPENAI_API_KEY=...` or use `--skip-ai` |
| `Run as root` | Native Linux needs sudo | `sudo bash scripts/demo_present.sh ...` |
| `Podman VM unreachable` | Machine not started | `bash scripts/fix_podman.sh` then `podman machine start` |
| No AVC lines exported | App not run / auditd off | Re-run act 1; check `systemctl status auditd` |
| AI generation fails | API/network/model | Check `OPENAI_BASE_URL`; retry or `--skip-ai` |
| `compile_and_validate.sh` fails | Podman needed on macOS for compile | Acts 5–6 on VM; or compile inside VM |
| Enforce fails (no demo mode) | Soak gate | Use `--demo-mode` for workshops, or wait 7+ days |
| Port 8888 in use | Another process | Stop conflicting service or change app port in policy |
| `ansible-playbook not found` | Missing package | Install ansible; or demo falls back to `apply_policy.sh` |

---

## Presenter checklist

Before the session:

- [ ] Rehearse with `--demo-mode --auto` once on your platform (Linux or `--use-vm`)
- [ ] Confirm `OPENAI_API_KEY` works (or prepare `--skip-ai` artifacts)
- [ ] Terminal font size readable for audience
- [ ] Know which acts you'll skip if short on time (`--acts 1-7` is a good default)

During the session:

- [ ] Introduce the two roles (app team vs admin)
- [ ] Call out **`--demo-mode`** honestly before act 8
- [ ] Show `pr_summary.md` and PR template table at act 4
- [ ] Emphasize port **8888** uses **`unreserved_port_t`** (not `http_port_t`)

After the session:

- [ ] Point admins to [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md)
- [ ] Point developers to `dev_generate_policy.sh` and README self-service table

---

## Quick command reference

```bash
# Full paced workshop
sudo bash scripts/demo_present.sh --demo-mode

# Rehearsal
sudo bash scripts/demo_present.sh --demo-mode --auto

# macOS
bash scripts/demo_present.sh --use-vm --demo-mode

# Fast unattended (no narration)
sudo bash scripts/run_demo.sh

# Help
bash scripts/demo_present.sh --help
```

---

## Related documentation

- [SELINUX_BASICS.md](SELINUX_BASICS.md) — **start here if you're new to SELinux**
- [README.md](../README.md) — project overview and command table
- [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) — RHEL admin runbook (soak, canary hosts, enforce gates)
- [selinux_policy_review.md](../.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md) — PR template admins review
