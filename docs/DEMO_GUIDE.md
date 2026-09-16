# Demo Guide — SELinux Policy-as-Code Workshop

This guide helps **newcomers**, **presenters**, and **observers** understand and run the live demo — even with no prior SELinux or GitOps experience.

**How to read this guide:**

| You are… | Read first | Then |
|----------|------------|------|
| **Completely new to SELinux** | [SELINUX_BASICS.md](SELINUX_BASICS.md) sections 1–7 (~15 min) | **[SELINUX_TRAINING_LAB.md](SELINUX_TRAINING_LAB.md)** (commands + outputs), then this guide sections 1–4 |
| **Watching a colleague present** | Sections 1–4 below | Follow along during the 10 acts |
| **Presenting the workshop** | Whole guide + rehearse with `--auto --demo-mode` | Presenter checklist (section 13) |
| **Running the app team workflow after the demo** | [README.md](../README.md) developer section | `dev_generate_policy.sh` |

**Learning path:** [SELINUX_BASICS.md](SELINUX_BASICS.md) (concepts) → **[SELINUX_TRAINING_LAB.md](SELINUX_TRAINING_LAB.md)** (hands-on) → **this guide** (workshop) → [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) (admin rollout). **All docs:** [README.md](README.md).

---

## 1. What you will see — story in plain English

This demo shows how an application team and a security admin work together to update SELinux policy safely:

1. A small Flask app runs on a Linux host with SELinux **on** — the **whole OS stays Enforcing** (`getenforce`).
2. Only the app domain (`myapp_t`) is set **permissive** — the app keeps working, but its denials are **logged** (SSH, cron, and other domains stay fully enforcing).
3. Integration tests hit all HTTP endpoints in order; **`policy_out/avc.log`** is shown after the run (export or offline fixture).
4. **Deterministic policy CLI** merges AVCs into Git-ready `.te`/`.fc`; optional **LLM** polishes `pr_summary.md` only.
5. A **Pull Request body** is assembled with a plain-English summary for admins.
6. **CI** checks the policy compiles and blocks dangerous rules.
7. An admin **deploys a canary** — real policy installed, domain still permissive.
8. **Guardrails** verify file labels and monitor for new denials.
9. After a **soak period** (days in production; minutes in demo mode), the admin **enforces** — denials now block the app if policy is incomplete.
10. If something breaks, **rollback** puts the domain back to permissive instantly.

The presenter script [`scripts/demo_present.sh`](../scripts/demo_present.sh) walks through all of this with pauses between steps.

---

## 2. Demo vocabulary (for newbies)

| Term | Plain English |
|------|---------------|
| **Policy module** | The compiled SELinux rules for our app (`myapp.pp`), built from `.te` + `.fc` files |
| **Domain / `myapp_t`** | The SELinux label on the **running** Flask process |
| **AVC** | A log line when SELinux blocks (or would block) an operation — evidence for policy updates |
| **Permissive (domain)** | App keeps running; denials are logged only (`semanage permissive -a myapp_t`) |
| **semanage** | Linux command that edits SELinux’s **live policy database** (per-domain permissive, ports, booleans) — not the same as editing `.te` in Git |
| **Enforce** | Remove permissive — denials now **block** the app (`semanage permissive -d myapp_t`) |
| **Canary deploy** | Install real policy on a host, but keep the domain permissive while you watch for problems |
| **Soak** | Run in permissive canary for **7–14 days** (production) to catch weekly jobs, cron, logrotate |
| **PR handoff** | Assembled markdown (`policy_out/pr_body.md`) admins review — curated sample: [`docs/examples/pr_body.example.md`](examples/pr_body.example.md) |
| **CI** | Automated checks on every PR: compile policy + block wildcards and high-privilege allows |
| **Demo mode (`--demo-mode`)** | Workshop shortcut — skips the 7-day calendar wait only; everything else is real |
| **`getenforce`** | Whole-system SELinux mode — stays **Enforcing** throughout this demo |
| **`avc.log` filter** | Only **myapp-related** denials exported — not every domain on the host |

Confused about labels, `.te`/`.fc`, `restorecon`, or the two-layer model? See [SELINUX_BASICS.md §7–7.5](SELINUX_BASICS.md).

Endpoint and CI test reference: [TESTING.md](TESTING.md). Ansible playbook details: [../ansible/README.md](../ansible/README.md).

---

## 3. The demo app and HTTP endpoints

The **Order Processor** is a Flask app on port **8888**. Each endpoint exercises different SELinux rules:

| Endpoint | What it does | SELinux activity |
|----------|--------------|------------------|
| `GET /` | Health check | Minimal — confirms app is up |
| `GET /save-log` | Appends a line to `/var/log/myapp/data.log` | `myapp_t` writes to `myapp_log_t` (via `logging_log_filetrans`) |
| `GET /run-script` | Runs `/opt/myapp/bin/backup.sh` | `myapp_t` executes `myapp_script_exec_t`; script uses **bash builtins only** (no `/usr/bin/date` or other `bin_t` helpers — forbidden by CI) |
| `GET /rotate-log` | Renames `data.log`, creates new file | rename/create under `myapp_log_t` |
| `GET /probe-backend` | HTTP client to local backend on port **8889** | outbound `tcp_socket` `connectto` `myapp_backend_t`; client needs `getopt` on `self:tcp_socket` and read-only `cert_t` access for Python `urllib` |
| `GET /notify-socket` | Unix stream client to `/run/myapp/notify.sock` | `unix_stream_socket connectto` `myapp_backend_t`; backend (`myapp_backend_t`) creates the socket under `myapp_var_run_t` |

**Backend stub:** `myapp-backend.service` runs `backend_stub.py` as user **`myapp`** in domain **`myapp_backend_t`** (separate from Flask). It listens on **`:8889/health`** and creates **`/run/myapp/notify.sock`**. Both units declare `RuntimeDirectory=myapp` and `RuntimeDirectoryPreserve=yes` so `/run/myapp` survives backend-only restarts.

**Note:** `/rotate-log` simulates log rotation from Flask in `myapp_t`. It does **not** run system `logrotate` as `logrotate_t` — real production soak must exercise actual schedulers.

Full SELinux walkthrough of `/save-log`: [SELINUX_BASICS.md §9](SELINUX_BASICS.md).

**Act 1 flow:** [`scripts/lib/integration_probes.sh`](../scripts/lib/integration_probes.sh) curls all six paths + backend health in **one pass**, then Act 1 prints **`wc -l`** and **`head -1`** of **`policy_out/avc.log`** (live export on Mac VM, or offline fixture with `--skip-ai`). Act 2 narrates the same file for policy generation.

---

## 4. Two roles in the story

| Role | Responsibility in the demo |
|------|----------------------------|
| **Application team** | Run staging tests, export AVCs, generate policy, assemble PR body |
| **Security / RHEL admin** | Review PR summary, deploy canary, verify labels, soak, enforce, rollback if needed |

Acts 1–5 = app team story. Acts 6–10 = admin story. The presenter script covers both so the audience sees the full handoff.

---

## 5. Which script should I run?

| Script | Best for | Pauses? | Full story? |
|--------|----------|---------|-------------|
| **`run_demo_prep.sh`** | Rehearsal / showcase with **talking points** (no flags) | Yes | Yes — acts 1–10 + typed show commands |
| **`demo_present.sh`** | Live workshops, first-time audiences | Yes (skip with `--auto`) | Yes — 10 acts |
| **`run_demo.sh`** | Quick unattended run on native Linux | No | Partial — skips PR narration |
| **`dev_generate_policy.sh`** | Real developer workflow (not a staged demo) | No | Developer path only |

**Demo prep (recommended first run):** from repo root, no flags — built-in demo-mode, offline fixtures, and Podman VM on macOS. Act 1 uses **staged integration probes** (see §3).

```bash
bash scripts/run_demo_prep.sh
```

Or `make demo-prep`. Talking points print before each act; show commands are typed for you after each act (Act 1 includes an AVC peek after `/save-log`). Hands-on prep: `make training-lab` — Lab 7 runs the same staged probe flow.

```mermaid
flowchart TD
  Start[Want to run the demo?] --> Live{Live audience?}
  Live -->|yes| Present["demo_present.sh --demo-mode"]
  Live -->|no rehearsal| Auto["demo_present.sh --demo-mode --auto"]
  Start --> Quick[run_demo.sh for fast unattended run]
  Present --> MacOS{On macOS?}
  Auto --> MacOS
  MacOS -->|yes| UseVM[Add --use-vm flag]
  MacOS -->|no| Sudo[Use sudo on native Linux]
```

**First-time presenters:** rehearse with `--demo-mode --auto` once, then present live without `--auto`.

---

## 6. Prerequisites

### All platforms

- Clone this repository
- Python 3.9+ and `pip3 install -r cli/requirements.txt`
- **`OPENAI_API_KEY`** set (unless using `--skip-ai`, which stages [`docs/examples/fixtures/skip_ai/`](../examples/fixtures/skip_ai/))
- Optional: `OPENAI_BASE_URL` / `OPENAI_API_MODEL` for LiteLLM or other OpenAI-compatible endpoints

**Don't have an API key?** Use `--skip-ai` — fixtures populate `policy_out/` with a deterministic baseline→generated diff (see `docs/examples/fixtures/skip_ai/README.md`). For live AVC classification without any API, the default engine is **`deterministic_gen.py`** ([`DETERMINISTIC_POLICY.md`](DETERMINISTIC_POLICY.md)).

### Native Linux (RHEL, Fedora, FCOS VM)

- Root or `sudo` (SELinux policy install requires it)
- SELinux **Enforcing** at OS level (app domain set permissive separately — see Basics §7)
- Packages: `audit`, `policycoreutils-python-utils`, `checkpolicy`, `selinux-policy-devel`, `ansible`, `curl`
- Acts **6–10** need Ansible collections: `ansible-galaxy collection install -r ansible/requirements.yml` (or let `demo_present.sh` / `run_demo_prep.sh` install them before act 6)
- Port **8888** free on localhost

### macOS

SELinux does **not** run natively on macOS. Use **Podman Machine** — same flow as the training lab.

| Step | Where | Why |
|------|--------|-----|
| `bash scripts/fix_podman.sh` | Mac Terminal, **repo root** | Install/start Podman + Linux VM |
| `source ~/.local/share/selinux-demo/podman/env.sh` | Same Mac shell (repeat in new windows) | Put Podman on `PATH` |
| `bash scripts/demo_present.sh --use-vm …` | Mac Terminal, repo root | Demo script runs SELinux acts **inside** the VM via SSH |

```bash
bash scripts/fix_podman.sh
source ~/.local/share/selinux-demo/podman/env.sh
bash scripts/demo_present.sh --use-vm --demo-mode
```

Step-by-step tables: [SELINUX_TRAINING_LAB.md — Running on macOS](SELINUX_TRAINING_LAB.md#running-on-macos).

---

## 7. How to run the demo

| Platform | Where you type | Command pattern |
|----------|----------------|-----------------|
| **Native Linux** | SSH or console on SELinux host, **repo root** | `sudo bash scripts/demo_present.sh …` |
| **macOS** | Mac Terminal, **repo root** (after `source env.sh`) | `bash scripts/demo_present.sh --use-vm …` (no `sudo` on Mac) |

### First rehearsal (recommended)

```bash
# Talk track + pauses + offline fixtures — no flags (Mac: source env.sh first if needed)
bash scripts/run_demo_prep.sh
# Native Linux: sudo bash scripts/run_demo_prep.sh
```

Fast unattended dry run (low-level script with flags):

```bash
bash scripts/demo_present.sh --demo-mode --skip-ai --auto
# macOS add: --use-vm
```

With live OpenAI generation instead of fixtures:

```bash
export OPENAI_API_KEY="your-key"
sudo bash scripts/demo_present.sh --demo-mode --auto          # Linux
bash scripts/demo_present.sh --use-vm --demo-mode --auto      # macOS
```

**Expected start of output (run_demo_prep.sh):**

```text
SELinux workshop — demo prep / showcase
Talking points + typed show commands + full presenter demo (acts 1–10).
```

Typical duration: **15–25 minutes** with pauses; **8–12 minutes** with `--auto`.

### Live presentation

```bash
export OPENAI_API_KEY="your-key"
sudo bash scripts/demo_present.sh --demo-mode
```

Press **Enter** at each pause to explain the next act before commands run.

### Partial demo (time-limited)

```bash
# Developer + CI only (~8 min)
sudo bash scripts/demo_present.sh --demo-mode --auto --acts 1-5

# Admin + guardrails only (needs policy_out/ from acts 1–5 first)
sudo bash scripts/demo_present.sh --demo-mode --auto --acts 6-10
```

### No API key (offline rehearsal)

```bash
sudo bash scripts/demo_present.sh --skip-ai --demo-mode --auto
```

Requires no pre-existing `policy_out/` — `--skip-ai` stages fixtures at demo start.

---

## 8. Demo mode vs production

| Topic | Production | Workshop (`--demo-mode`) |
|-------|------------|---------------------------|
| Permissive soak | **7–14 real days** | Act 8 pre-seeds an 8-day-old marker |
| Enforce gate | `check_soak_ready.sh` must pass (soak + AVCs + deploy report) | Act 9 uses `force_enforce=true` (break-glass) |
| Everything else | Same commands | **Real** — not simulated |

**Say this to the audience before Act 8:**

> "In production we wait a full business cycle so weekly cron and logrotate fire. Demo mode only skips the calendar — CI, labeling checks, and canary deploy are all real."

Never use `force_enforce=true` in real production without documented approval. See [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md).

---

## 9. The 10 acts — timeline and walkthrough

```text
Act 1–2   App team    staging + export AVCs
Act 3–5   App team    AI generate + PR body + CI
Act 6–7   Admin       canary deploy + guardrails
Act 8–9   Admin       soak gate + enforce
Act 10    Admin       rollback (show commands only)
```

Each act prints a blue banner. Below: plain English, what runs, what you should see, and what to say.

---

### Act 1 — Staging (Application team)

**In plain English:** Install the app, turn on permissive mode for `myapp_t`, and run integration tests.

**What runs:** `setup_staging_env.sh` (if needed) + **all integration curls in one batch**, then preview of **`policy_out/avc.log`**.

**What you should see (excerpt):**

```bash
$ getenforce
Enforcing

$ sudo semanage permissive -l
myapp_t

=== GET /save-log ===
{"status":"ok",...}
=== GET /run-script ===
...
=== GET :8889/health ===
{"status":"ok",...}

$ wc -l policy_out/avc.log
42

$ head -1 policy_out/avc.log
type=AVC msg=audit(...): avc: denied { write } ...
```

**SELinux concept:** Per-domain permissive (two-layer model) — [SELINUX_BASICS.md §7](SELINUX_BASICS.md).

**Talking point:** *"SSH, systemd, and everything else stay enforcing — only our app domain is log-only so we can collect accurate AVC evidence without blocking the demo."*

---

### Act 2 — AVC export (Application team)

**In plain English:** Copy **myapp-related** denial lines from the audit log into a file for the AI. This is **staging discovery** — not the production soak yet.

**What runs:** Export to `policy_out/avc.log` via `export_app_avcs_to_file` in `lib/avc_query.sh` (same `--subject` / message types as soak gates). With `--skip-ai`, Act 2 uses the fixture log staged at startup.

**What you should see:**

```bash
$ wc -l policy_out/avc.log
# non-zero — often dozens on first run with stub/minimal policy

$ head -1 policy_out/avc.log
type=AVC msg=audit(...): avc: denied { write } for comm="python3"
  scontext=system_u:system_r:myapp_t:s0
  tcontext=system_u:object_r:myapp_var_lib_t:s0 tclass=file permissive=1
```

All exported lines should show `myapp_t` in `scontext` and `permissive=1` during staging.

**SELinux concept:** Reading AVC lines and export filter — [SELINUX_BASICS.md §8](SELINUX_BASICS.md).

**Talking point:** *"Every line here is myapp evidence from our tests — not SSH or cron denials from the rest of the server."*

**Show on screen:** `wc -l policy_out/avc.log` and one sample AVC line.

---

### Act 3 — Policy generation (Application team)

**In plain English:** The **deterministic** engine merges duplicate AVC lines, subtracts permissions already in `selinux/myapp.te`, and writes candidate `.te`/`.fc` to `policy_out/`. Optionally, **`cli/summarize_pr.py`** rewrites the admin narrative in `pr_summary.md` (classification table stays deterministic).

**What runs:** `cli/deterministic_gen.py` (+ `bash scripts/validate_forbidden_patterns.sh` / compile). With `--llm-summary` and `OPENAI_API_KEY`: `cli/summarize_pr.py`.

**What you should see:**

```text
Wrote policy_out/avc_summary.txt (raw=42 merged=6 net_new=2)
Wrote policy_out/myapp.{te,fc} (N net-new denial(s) classified)
Wrote policy_out/pr_summary.md
# optional:
Calling model 'gpt-4o-mini' for pr_summary narrative only...
```

**SELinux concept:** `.te` allow rules — [SELINUX_BASICS.md §5](SELINUX_BASICS.md).

**Talking point:** *"Policy is merged into the existing module — not replaced blindly. CI writes the rules; the model only helps admins read the PR summary if we enable it."*

**Show on screen:** `head -30 policy_out/pr_summary.md` (look for `### Network Bindings` headings).

---

### Act 4 — PR handoff (Application team → Admin)

**In plain English:** Build the GitHub PR body admins actually review.

**What runs:** `assemble_pr_body.sh` → `policy_out/pr_body.md` (template placeholders + merge-base **sesearch** access delta via `policy_module_diff.sh`; use `--skip-policy-diff` only for offline smoke).

**What you should see:**

```bash
$ grep -E 'Policy access delta|Rules ADDED|Network Bindings|forbidden-patterns' policy_out/pr_body.md | head -8
### 2.5 Policy access delta (merge-base)
### Network Bindings
| **No Over-Permissive Grants** | ⬜ Pass / ⬜ Reject | CI `forbidden-patterns`
```

**Talking point:** *"Developers don't paste free-form text — the pipeline assembles what admins need to sign off, including AVC excerpts and a rule-level diff against the merge base."*

**Show on screen:** Admin Pass/Reject table in `policy_out/pr_body.md`.

**Real GitHub PR (recommended for Act 4–5):** `main` already includes policy v1.1.2, so open a **review PR** against base branch `demo/policy-base-1.1.1` (v1.1.1 snapshot):

```bash
bash scripts/open_demo_policy_pr.sh --reuse-pr-body   # needs gh auth login
# offline PR body only: add --push-only and open PR in browser (base demo/policy-base-1.1.1, head policy/myapp-update)
```

Then share the PR URL — **Checks** tab runs [`.github/workflows/selinux-policy-ci.yml`](../.github/workflows/selinux-policy-ci.yml).

---

### Act 5 — CI gates (Automatic on PR)

**In plain English:** Run the same checks GitHub Actions runs before merge.

**What runs:** Same jobs as [`.github/workflows/selinux-policy-ci.yml`](../.github/workflows/selinux-policy-ci.yml) — e.g. `validate_forbidden_patterns.sh`, `validate_version_consistency.sh`, `compile_and_validate.sh`, `validate_policy_semantics.sh`, `run_blast_radius_fixtures.sh` (Podman), `ansible-lint`. PRs also get **`policy-diff-comment`** (merge-base access delta).

**What you should see:**

```text
[INFO] Forbidden-pattern checks passed for myapp
[INFO] Version consistency OK (policy_version.txt ↔ policy_module() ↔ spec)
[INFO] Compiling myapp in selinux
[INFO] policy_module() present
[INFO] Blast-radius fixtures: 4/4 passed
```

**Talking point:** *"Admins shouldn't review syntax errors — CI catches those before merge."*

---

### Act 6 — Canary deploy (Admin)

**In plain English:** Install the **full** policy module (not the staging stub) but keep `myapp_t` permissive for **canary soak**. This is a different permissive phase from Acts 1–2 (discovery).

**What runs:** `ansible/deploy_canary.yml` (or `apply_policy.sh --canary` fallback). On the Podman FCOS VM, Act 6 syncs the repo then builds **`selinux/myapp_canary.pp`** (permissive overlay for `myapp_t` when `semanage` is absent) before the playbook runs.

**What you should see:**

```bash
$ getenforce
Enforcing

$ sudo semanage permissive -l
myapp_t

$ sudo semodule -l | grep myapp
myapp

$ curl -sf http://127.0.0.1:8888/notify-socket
{"status":"ok","endpoint":"/notify-socket",...}
```

**Canary playbook checks:** after restart, Ansible waits for `:8888/`, `:8889/health`, and `GET /notify-socket`, then curls `/save-log`, `/run-script`, `/rotate-log`, `/probe-backend`, and `/notify-socket`.

**SELinux concept:** `semodule -i` + `restorecon` — [SELINUX_BASICS.md §5–6](SELINUX_BASICS.md). Two permissive phases — [SELINUX_BASICS.md §7](SELINUX_BASICS.md).

**Talking point:** *"We deploy the real module early, but we don't enforce until we've watched production-like workloads for a full business cycle."*

Soak marker written: `/var/lib/myapp/selinux_canary_deployed_at` (soak clock starts here). Canary also runs **`semodule -DB`** so dontaudit rules do not hide soak AVCs.

**FCOS note:** You will not see `semanage permissive -l`; permissive soak comes from the **`myapp_canary`** module (`semodule -l | grep myapp_canary`). Enforce (Act 9) removes that overlay with **`semodule -r myapp_canary`** when `semanage` is unavailable.

---

### Act 7 — Production guardrails (Admin)

**In plain English:** Verify file labels are correct and check for lingering denials before enforce.

**What runs:** `verify_file_contexts.sh` + `monitor_avc.sh`.

**What you should see:**

```text
[INFO] File context verification passed for myapp
[INFO] AVC report: domain=myapp_t since=... count=0
```

**SELinux concept:** `restorecon -n` dry-run — [SELINUX_BASICS.md §6](SELINUX_BASICS.md).

**Talking point:** *"The most common production surprise is wrong file labels on existing data — we verify before restart."*

---

### Act 8 — Soak period (Admin)

**In plain English:** In production, the admin waits **7–14 real days** after canary deploy while `myapp_t` stays permissive and daily monitoring confirms zero new AVCs. Demo mode pre-seeds an old marker to show the gate passing.

**Production soak checklist:**

| Step | What happens |
|------|----------------|
| Day 0 | Canary deploy writes `/var/lib/myapp/selinux_canary_deployed_at` |
| Days 1–14 | `myapp_t` still permissive; `getenforce` still Enforcing |
| Daily | `bash scripts/monitor_avc.sh --domain myapp_t --max-avc 0` |
| Before enforce | `check_soak_ready.sh` — marker age ≥ 7 days, zero new `myapp_t` AVCs, **and** passing deploy report at `/var/lib/myapp/selinux_deploy_report.json` |

**What runs:** `check_soak_ready.sh` (passes in `--demo-mode` after marker is pre-seeded).

**What you should see (demo mode):**

```text
[WARN] DEMO MODE: simulating completed soak (pre-seeding marker to 8 days ago)
[INFO] Soak gate passed — safe to enforce myapp_t
```

**Without demo mode** (expected failure right after canary):

```text
[ERROR] Soak period not met — wait 6 more day(s)
```

**SELinux concept:** Soak timeline — [SELINUX_BASICS.md §7.5](SELINUX_BASICS.md), [PRODUCTION_READINESS.md §3.5](PRODUCTION_READINESS.md).

**Talking point:** *"In production we wait a full business cycle so weekly cron and logrotate fire. Demo mode only skips the calendar — permissive semantics are real."*

---

### Act 9 — Enforce (Admin)

**In plain English:** Remove permissive mode — denials now block the app if policy is incomplete.

**What runs:** `ansible/enforce_production.yml` (with `force_enforce=true` in demo mode).

**What you should see:**

```bash
$ sudo semanage permissive -l
# (empty — myapp_t not listed)

# enforce_production.yml runs scripts/wait_for_endpoints.sh (checks systemd + all six endpoints):
$ bash scripts/wait_for_endpoints.sh --host 127.0.0.1 --retries 15 --delay 2
[INFO] All endpoints ready

# Equivalent manual curls (what the script checks):
$ curl -sf http://127.0.0.1:8888/
$ curl -sf http://127.0.0.1:8888/save-log
$ curl -sf http://127.0.0.1:8888/run-script
$ curl -sf http://127.0.0.1:8888/rotate-log
$ curl -sf http://127.0.0.1:8888/probe-backend
$ curl -sf http://127.0.0.1:8888/notify-socket
{"status":"ok",...}

$ cat /var/lib/myapp/selinux_deploy_report.json
{"status":"pass","phase":"enforce",...}
```

Playbook output should show `failed=0` on **Production smoke tests (unified endpoint wait)** and **Write enforce deploy report**. If enforce fails, Ansible **block/rescue** restores `myapp_t` to permissive and restarts services before failing.

**SELinux concept:** `semanage permissive -d` — [SELINUX_BASICS.md §7](SELINUX_BASICS.md).

**Talking point:** *"After enforce, any missing permission becomes a hard denial — that's why soak and monitoring matter."*

**Optional presenter beat (after Act 9):** Temporarily remove one allow from a test host, enforce, and show a blocked curl or an AVC with `permissive=0` — then rollback with `semanage permissive -a myapp_t`.

---

### Act 10 — Emergency rollback (Admin)

**In plain English:** Show the outage playbook — not executed in the workshop.

**What runs:** Prints commands only.

**Steps shown:**

1. `semanage permissive -a myapp_t` — instant relief, no reboot
2. `ausearch -m avc -ts recent > /tmp/prod_outage_denials.log`
3. `ansible-playbook ansible/emergency_rollback.yml`

**Talking point:** *"If enforce causes an outage, the first move is permissive domain — not disabling SELinux globally."*

Details: [PRODUCTION_READINESS.md §12](PRODUCTION_READINESS.md).

---

## 10. What success looks like after the full demo

| Check | Expected result |
|-------|-----------------|
| `policy_out/pr_body.md` | Exists with admin table + AVC excerpt |
| `policy_out/myapp.pp` | Compiled policy package |
| `sudo semanage permissive -l` | Empty (after Act 9) |
| All six HTTP endpoints | `curl` returns HTTP 200 with `"status":"ok"` (see section 3) |
| `getenforce` | `Enforcing` (OS was never set permissive) |
| `systemctl is-active myapp-backend` | `active` (Tier 6 backend required for `/probe-backend` and `/notify-socket`) |

---

## 11. Architecture diagram (for slides)

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

## 12. Key files to know

| Path | Purpose |
|------|---------|
| `app/app.py` | Demo application (six HTTP endpoints) |
| `app/backend_stub.py` | Tier 6 backend stub (`myapp_backend_t`, `:8889`, Unix socket) |
| `app/myapp-backend.service` | systemd unit for backend stub |
| `app/bin/backup.sh` | Script executed by `/run-script` (bash builtins only) |
| `selinux/myapp.te` | Type enforcement rules — Git source of truth |
| `selinux/myapp.fc` | File path → label mappings |
| `selinux/policy_version.txt` | SemVer SSOT — bump here and in `policy_module(myapp, …)` in `.te`; CI `version-consistency` |
| `policy_out/avc.log` | Raw exported denials (audit trail + PR excerpt) |
| `policy_out/avc_summary.txt` | Merged net-new access needs (LLM input) |
| `policy_out/pr_summary.md` | Plain-English summary for admins (live); sample: [`docs/examples/pr_summary.example.md`](../examples/pr_summary.example.md) |
| `policy_out/pr_body.md` | Assembled GitHub PR body (live); sample: [`docs/examples/pr_body.example.md`](../examples/pr_body.example.md) |
| `ansible/deploy_canary.yml` | Permissive canary deploy — see [ansible/README.md](../ansible/README.md) |
| `ansible/enforce_production.yml` | Remove permissive + enforce — see [ansible/README.md](../ansible/README.md) |
| `ansible/emergency_rollback.yml` | Outage response — see [ansible/README.md](../ansible/README.md) |
| `scripts/lib/integration_probes.sh` | Act 1 / Lab 7 / VM `trigger` — all HTTP probes in one pass |
| `scripts/wait_for_endpoints.sh` | Unified systemd + six HTTP endpoint readiness (canary/enforce gates) |
| `docs/TESTING.md` | Full test matrix (endpoints, smoke_test.py, CI, gates) |
| `scripts/post_deploy_report.sh` | JSON deploy feedback → `/var/lib/myapp/selinux_deploy_report.json` |
| `scripts/lib/vm_ready.sh` | Podman VM SSH readiness + recovery hints |
| `.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md` | Admin review template |

---

## 13. Troubleshooting

| Problem | What it looks like | Fix |
|---------|-------------------|-----|
| `OPENAI_API_KEY not set` | Script exits immediately | `export OPENAI_API_KEY=...` or `--skip-ai` |
| `Run as root` | Error before Act 1 | `sudo bash scripts/demo_present.sh ...` |
| `Podman VM unreachable` | Connection refused to VM API/SSH | `source ~/.local/share/selinux-demo/podman/env.sh`; `bash scripts/fix_podman.sh`; retry after `ensure_vm_ready` recovery card |
| Demo hangs on sync/setup | Long wait, no progress | `podman machine stop && podman machine start`; increase `VM_SSH_TIMEOUT_SEC` (default 90) |
| `connection refused` before compile | Podman machine stopped | `compile_and_validate.sh` now waits for VM — retry; run `bash scripts/fix_podman.sh` |
| No AVC lines exported | `wc -l` shows 0 | Re-run Act 1; check `systemctl status auditd` |
| AI generation fails | HTTP/timeout errors | Check `OPENAI_BASE_URL`; use `--skip-ai` |
| Compile fails on macOS | Podman overlay/readlink errors | `source …/podman/env.sh`; `bash scripts/repair_podman_machine.sh`; `bash scripts/lib/selinux_build_image.sh pull` — [`DOCKER_HUB_COMPILE_IMAGE.md`](DOCKER_HUB_COMPILE_IMAGE.md) |
| Enforce fails (no demo mode) | `Soak period not met` | Use `--demo-mode` for workshops |
| `/notify-socket` fails after enforce | Stale socket or backend not listening | Check `journalctl -u myapp-backend`; Ansible removes stale socket before restart |
| `/probe-backend` Permission denied | Missing TCP `getopt` or backend down | Confirm `:8889/health`; check AVC for `tcp_socket getopt` |
| `/run-script` Permission denied | Script calls `/usr/bin/*` (`bin_t`) | Keep `backup.sh` on bash builtins — CI forbids `bin_t:file execute` |
| Port 8888 in use | curl connection refused | Stop conflicting service |
| `ansible-playbook not found` | Warning + fallback | Install ansible, or demo uses `apply_policy.sh` |

---

## 14. Presenter checklist

**Before the session:**

- [ ] Read [SELINUX_BASICS.md](SELINUX_BASICS.md) sections 3–7 if new to SELinux
- [ ] Rehearse with `--demo-mode --auto` once on your platform
- [ ] Confirm `OPENAI_API_KEY` works (or prepare `--skip-ai`)
- [ ] Terminal font size readable for audience
- [ ] Know which acts to skip if short on time (`--acts 1-7` is a good default)

**During the session:**

- [ ] Introduce the two roles (app team vs admin)
- [ ] Call out **`--demo-mode`** honestly before Act 8
- [ ] Show `pr_summary.md` and PR template table at Act 4
- [ ] Emphasize port **8888** uses **`unreserved_port_t`** (not `http_port_t`)
- [ ] Optional: demonstrate enforce-mode denial (`permissive=0` AVC) after Act 9

**After the session:**

- [ ] Point admins to [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md)
- [ ] Point developers to `dev_generate_policy.sh` and [README.md](../README.md)

---

## 15. Quick command reference

```bash
# Full paced workshop
sudo bash scripts/demo_present.sh --demo-mode

# Rehearsal (no pauses)
sudo bash scripts/demo_present.sh --demo-mode --auto

# macOS
bash scripts/demo_present.sh --use-vm --demo-mode

# Fast unattended (no narration)
sudo bash scripts/run_demo.sh

# Help
bash scripts/demo_present.sh --help
```

---

## Document map

| Guide | Sections to read | Audience |
|-------|------------------|----------|
| [SELINUX_BASICS.md](SELINUX_BASICS.md) | §1–7 concepts; §9 worked example | New to SELinux |
| [SELINUX_BEST_PRACTICES.md](SELINUX_BEST_PRACTICES.md) | §1–4 policy + CI principles | Authors and reviewers |
| **This file** | §1–4 before demo; §9 during demo | Presenters and observers |
| [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) | §1–14 after demo | RHEL admins |
| [README.md](../README.md) | Self-service table | Day-to-day commands |
