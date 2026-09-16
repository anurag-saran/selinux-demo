# Production Readiness Runbook (RHEL Admin)

Day-to-day runbook for **shipping SELinux policy** with application teams. Ansible Automation Platform (AAP) is the control plane. Developers PR policy from a **dev** host; you compile, package, canary, soak, and enforce on **prod**.

**How to read this guide:**

| You are… | Read first | Then |
|----------|------------|------|
| **New to SELinux** | [SELINUX_BASICS.md](../policy/SELINUX_BASICS.md) sections 1–7.5 | This guide sections 1–4 |
| **Running day-to-day deploys** | [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md) then [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md) | Phases 1–6 as your checklist |
| **Reviewing policy PRs** | [SELINUX_BEST_PRACTICES.md](../policy/SELINUX_BEST_PRACTICES.md) §8 | PR template + CI mapping §15 |
| **Optional training** | [DEMO_GUIDE.md](../training/DEMO_GUIDE.md) acts 6–10 | This guide from section 4 onward |

**Learning path:** [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md) → [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md) → [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md) → **this guide**. Concepts: [SELINUX_BASICS.md](../policy/SELINUX_BASICS.md). **Doc index:** [README.md](../README.md).

**Where this guide applies:** two RHEL boxes (dev + prod) from a controller — [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md). Commands like `semanage`, `semodule`, Ansible playbooks, and soak checks run on **those servers**.

---

## 1. Why production is different from the lab

High-blast-radius SELinux changes need **per-domain permissive soak**, **path labeling verification**, and **phased rollout** before you remove the permissive flag.

| Topic | Lab (`soak_min_days: 0` on **rhel-dev**) | Production |
|-------|------------------------------------------|------------|
| Soak wait | Skipped for the lab enforce on **dev** | **7–14 real calendar days** |
| Enforce | Lab inventory only — never copy onto prod | Enforce role **`collect_soak_facts.sh`** gate (or manual `check_soak_ready.sh` on host) |
| Goal | Teach the pipeline | **No surprise outages** |
| Rollback | Commands shown | Run `emergency_rollback.yml` if needed |

**Never** use `force_enforce=true` in production without documented break-glass approval and on-call awareness.

---

## 2. Plain-English glossary

| Term | Plain English |
|------|---------------|
| **Canary host** | One production node that gets new policy first — still permissive while you watch |
| **Soak** | Run permissive canary for 7–14 days so weekly cron, logrotate, and restarts surface missing rules |
| **Fleet** | All production hosts after canary proves stable |
| **Enforce gate** | Automated check (`collect_soak_facts.sh` in Ansible) — soak time elapsed + **net-new** access needs within limit (raw AVC fallback without `sesearch`) |
| **Break-glass** | `force_enforce=true` **and** a `change_ticket` — skip soak; use only in emergencies with approval |
| **Path labeling** | Files on disk must match `.fc` rules (`restorecon` + verify before restart) |
| **Per-domain permissive** | Only `myapp_t` is permissive; the OS stays **Enforcing** globally |
| **semanage** | Tool on the **server** that adds/removes domains from the permissive list (`-a` / `-d`) and manages ports/booleans in the live policy DB |

SELinux theory (labels, `.te`/`.fc`, `semanage` examples): [SELINUX_BASICS.md](../policy/SELINUX_BASICS.md).

---

## 3. The rollout journey

Production is **never** auto-enforced on merge. You move through staging → prod canary → fleet enforce deliberately.

```mermaid
flowchart LR
  PR[PR merged] --> StagingSoak[Staging canary + 7-14d soak]
  StagingSoak --> ProdCanary[Prod canary host]
  ProdCanary --> ProdSoak[Prod canary soak]
  ProdSoak --> Enforce[Fleet enforce]
  Enforce -->|outage| Rollback[AAP Rollback]
```

**Recommended sequence** ([RHEL_TWO_HOST.md](RHEL_TWO_HOST.md)):

```text
PR merge → compile / RPM (CLI: compile_and_validate.sh, build_rpms.sh)
         → AAP **Release canary** (`deploy_canary.yml --limit canary`)
         → scheduled **Soak monitor** (`soak_monitor.yml`, net-new vs installed policy)
         → AAP **Promote to enforce** (Soak status → approval → Enforce)
         → on denial: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md) (PR, not live patch)
```

---

## 3.5 Soak in plain English

**Soak** is not idle waiting — it is **active monitoring** while the app runs with **real policy** but **`myapp_t` still permissive**.

```text
Day 0     deploy_canary.yml
          → semodule -i myapp.pp + semanage permissive -a myapp_t
          → marker: /var/lib/myapp/selinux_canary_deployed_at

Week 1–2  Daily soak_monitor.yml (or monitor_avc.sh --max-net-new 0)
          → getenforce stays Enforcing; only app domain is log-only
          → net-new count vs installed policy (sesearch); raw AVC count is informational

Gate      collect_soak_facts.sh / enforce role passes ALL:
          → marker age ≥ 7 days
          → zero net-new access needs since marker (or raw AVC gate if sesearch unavailable)
          → deploy report at /var/lib/myapp/selinux_deploy_report.json with pass status + endpoint coverage

Enforce   semanage permissive -d myapp_t
          → denials now block the app if policy is incomplete
```

| Week | Admin action | Pass looks like |
|------|--------------|-----------------|
| **Week 0** | AAP **SELinux – Release canary** (or `deploy_canary.yml`) | App healthy; `myapp_t` in `semanage permissive -l`; marker file exists |
| **Week 1** | Daily AAP **SELinux – Soak monitor** | `net_new_count=0`, playbook `failed=0` |
| **Week 2** | AAP **SELinux – Promote to enforce** (Soak status → approval → Enforce) | `semanage permissive -l` empty; app still responds |
| **Enforce day** | Enforce node of **Promote to enforce** (`change_ticket` required) | Domain enforcing; HTTP probes from the manifest still succeed |

**Two-layer reminder:** `getenforce` = **Enforcing** throughout soak. Only **`myapp_t`** is on the permissive list until enforce.

**If policy changes during soak:** redeploy canary, extend `.te`, and **reset the soak clock** (new marker timestamp). See [§14 Troubleshooting](#14-troubleshooting).

Full timeline for beginners: [SELINUX_BASICS.md §7.5](../policy/SELINUX_BASICS.md).

---

## 4. Three deploy paths

**Ansible Automation Platform (AAP) is the production path.** Click-create objects from [`ansible/aap/`](../../ansible/aap/). Compile with CLI scripts (`compile_and_validate.sh`, `packaging/build_rpms.sh`). Optional GitHub Actions can call the same playbooks. See [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md).

| When | Who | How |
|------|-----|-----|
| **PR open** | CI (automatic) | `smoke-tests`, `forbidden-patterns`, `compile-policy` |
| **Merge / release** | Admin / optional CI | `compile_and_validate.sh` + `packaging/build_rpms.sh`; optional [`.github/workflows/selinux-staging-canary.yml`](../../.github/workflows/selinux-staging-canary.yml) |
| **Production cutover** | Admin (manual) | AAP workflow **SELinux – Promote to enforce** (`enforce_production.yml`, `change_ticket` required) |

Manual Ansible (`ansible-playbook` or AAP) uses the playbooks in [`ansible/`](../../ansible/) — see phases below.

**Merge pipeline (optional GHA):** after `staging-canary` installs policy on a self-hosted staging runner, **`staging-endpoint-smoke`** runs `wait_for_endpoints.sh` and verifies the deploy report. This catches regressions before an admin starts prod canary.

**Staging soak is scheduled Ansible, not a GitHub timer:** enable AAP job **SELinux – Soak monitor** daily. There is **no automatic enforce**. Wait 7–14 days, then run workflow **SELinux – Promote to enforce**. If soak fails: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md).

---

## 5. Pre-production testing matrix

See also: [`TESTING.md`](../developers/TESTING.md) (full endpoint → policy mapping and `smoke_test.py` cases), [`ansible/README.md`](../../ansible/README.md) (playbook task order).

| Phase | Goal | Command / playbook | **Pass looks like** |
| --- | --- | --- | --- |
| **Syntax and compilation** | `.te` / `.fc` compile without errors | `bash scripts/compile_and_validate.sh selinux` on a host with `selinux-policy-devel` | `myapp.pp` built, no errors |
| **Semantic assertions** | Required allows present in compiled module | `bash scripts/validate_policy_semantics.sh selinux` (CI `policy-semantics` job) | `sesearch` checks pass |
| **Forbidden patterns** | No wildcards or high-privilege allows | `bash scripts/validate_forbidden_patterns.sh selinux` | `Forbidden-pattern checks passed` |
| **Path labeling** | On-disk contexts match `.fc` before restart | `bash scripts/verify_file_contexts.sh --log-dir /var/log/myapp` | `File context verification passed` |
| **Staging canary** | Permissive domain + integration smoke | Merge to `main` or `ansible-playbook ansible/deploy_canary.yml -i ansible/inventory.dev.yml` | All **six** endpoints return HTTP 200; services run as `myapp_t` / `myapp_backend_t`; deploy report `"status": "pass"` with `domain_context_verified: true` |
| **Canary AVC gate** | Block canary if denials already present | `deploy_canary.yml` (default `canary_max_avc=0`) | Playbook fails if recent `myapp_t` AVC count exceeds threshold |
| **Post-merge staging smoke** | CI re-check after canary on runner | `staging-endpoint-smoke` job in `selinux-staging-canary.yml` | `wait_for_endpoints.sh` passes; deploy report present |
| **Permissive soak** | Capture weekly cron, logrotate, restarts (7–14 days) | `ansible/soak_monitor.yml` daily (net-new vs installed policy) | `net_new_count=0`; raw AVC count informational |
| **Production canary host** | Deploy to one node before fleet | `deploy_canary.yml --limit canary` | Marker file written, app + backend healthy |
| **Blast-radius tiering** | Soak minimum from policy delta (fail-closed) | `bash scripts/run_blast_radius_fixtures.sh` (CI **`blast-radius`** job) | All fixtures match `expected.json`; tier logic changes require fixture updates |
| **Enforce gate** | Automated soak + net-new + deploy report | `collect_soak_facts.sh` in `enforce_production.yml` (`soak_use_net_new: true`) | Role reports soak gate passed |
| **Production enforce** | Remove permissive domain | `ansible/enforce_production.yml` | `semanage permissive -l` empty; **six** production smoke tests pass under enforcing |
| **Outage response** | Instant relief + AVC capture | `ansible/emergency_rollback.yml` | Domain back in permissive list; endpoints pass; deploy report written; soak marker reset |

---

## 6. Phase 1 — Per-domain permissive soak (canary)

This phase is **canary soak after merge** — not the developer's **staging discovery** permissive (where the app team collects AVCs to write initial policy). Here the **full** `myapp.pp` is already installed; permissive mode lets you watch real workloads before enforce.

Enable permissive mode **only** for the application domain (OS stays enforcing):

```bash
sudo semanage permissive -a myapp_t
```

**Verify it is active:**

```bash
$ sudo semanage permissive -l
myapp_t
```

**Duration:** 7 to 14 days by default (`soak_min_days`). Optional **`check_soak_ready.sh --auto-tier`** adjusts the minimum using [`classify_policy_blast_radius.sh`](../../scripts/classify_policy_blast_radius.sh) (sesearch rule diff, not sediff). Tiering is **gated on** [`tests/fixtures/blast_radius/`](../../tests/fixtures/blast_radius/) — do not change tier logic without updating fixtures and passing the **`blast-radius`** CI job.

The canary playbook records a deploy timestamp at `/var/lib/myapp/selinux_canary_deployed_at` (epoch seconds), runs **`semodule -DB`** so dontaudit rules do not hide soak AVCs, and installs policy with **`semodule -i`** (in-place upgrade — no `semodule -r`). Production enforce refuses to run until soak requirements pass (unless `force_enforce=true` break-glass).

**Admin sign-off — host-level `semodule -DB`:** disabling dontaudit affects the **entire host**, not just `myapp_t`. If canary fails or rollback runs, playbooks call **`semodule -B`** to restore the baseline. If enforce never runs after a successful canary, `-DB` stays active until enforce — document this in the change ticket. Failed canary and rollback paths always restore `-B`.

**Admin sign-off — domain context verification:** deploy reports and soak gates require `wait_for_endpoints.sh` to confirm `myapp.service` runs as **`myapp_t`** and `myapp-backend.service` as **`myapp_backend_t`**. Without this check, a mislabeled entrypoint (`init_t`) can pass all HTTP gates with zero AVCs while the custom policy was never applied.

**Canary AVC gate:** `deploy_canary.yml` counts recent `myapp_t` AVC lines and **fails** if the count exceeds `canary_max_avc` (default **`0`**). Override only with explicit approval:

```bash
ansible-playbook ... ansible/deploy_canary.yml -e "canary_max_avc=2"
```

Do not raise the threshold to bypass missing policy — fix `.te`, redeploy, and re-soak instead.

**List vs add:** `semanage permissive -l` lists domains; `-a` adds, `-d` removes. See [SELINUX_BASICS.md §7](../policy/SELINUX_BASICS.md).

---

## 7. Phase 2 — Path labeling verification

After `semodule -i`, existing files may retain old contexts. Verify **before** restarting the service:

```bash
sudo bash scripts/verify_file_contexts.sh \
  --install-root /opt/myapp \
  --var-dir /var/lib/myapp \
  --log-dir /var/log/myapp \
  --app-name myapp
```

**Pass looks like:**

```text
[INFO] File context verification passed for myapp
```

**Fail looks like** (would relabel on restorecon):

```text
[ERROR] restorecon dry-run would change: /var/log/myapp/data.log
```

This runs `matchpathcon` on key paths and fails if `restorecon -Rv -n` would relabel anything under the data directory.

Always run verification immediately after policy install and before `systemctl restart`.

Full `restorecon` walkthrough: [SELINUX_BASICS.md §6](../policy/SELINUX_BASICS.md).

---

## 8. Phase 3 — Systemd and cron attestation

Staging tests must use **systemd**, not manual `python app.py`:

```bash
sudo systemctl restart myapp.service
sudo systemctl is-active myapp.service
curl -sf http://127.0.0.1:8888/rotate-log
```

**Cron (optional — does not run as `myapp_t`):**

The example below runs `backup.sh` as **root** in the **`cron_t`** domain — it does **not** exercise `myapp_t` during soak. Use it only to illustrate why real production soak must include schedulers that run **as the app domain** (systemd timers, app-owned cron, etc.).

```bash
# Illustration only — runs as cron_t/root, NOT myapp_t
echo '0 2 * * * root /opt/myapp/bin/backup.sh' | sudo tee /etc/cron.d/myapp-backup-smoke
```

For staging discovery on the **reference app**, `GET /rotate-log` (Flask in `myapp_t`) simulates log rotation.

That HTTP path does **not** replace real `logrotate` cron. Production soak must capture AVCs from `logrotate_t` (and any other scheduler domain) and extend policy before enforce.

**Monitoring agents (Datadog, Promtail, Prometheus):** org-specific domains — verify manually during soak if agents read `/var/lib/myapp`.

---

## 9. Phase 4 — Daily AVC monitoring

During soak, run **Ansible** — do not clone the git repo onto production hosts. Ops scripts live in the **`selinux-policy-ops`** RPM at `/usr/libexec/selinux-policy-ops`.

**AAP (recommended):** schedule job template **SELinux – Soak monitor** (`soak_monitor.yml`) daily on the canary group.

**Manual playbook:**

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary
```

**Ad-hoc on the host** (ops RPM installed):

```bash
/usr/libexec/selinux-policy-ops/monitor_avc.sh \
  --manifest /etc/myapp/selinux-manifest.yml \
  --marker-file /var/lib/myapp/selinux_canary_deployed_at \
  --max-net-new 0 \
  --format json
```

The JSON payload includes `count` (raw lines), `net_new_count` (unique access needs **not** already allowed by **installed** policy), `exceptions[]`, and `avc_fail_closed` (true if `sesearch` is missing).

**Pass looks like:** `net_new_count=0` (duplicate AVC lines from cron do **not** fail the gate).

**Fail looks like:** `net_new_count` > `soak_max_net_new` — investigate `exceptions[]`, extend `.te`, PR, redeploy canary, **reset the soak clock**.

Install **`setools-console`** on canary/prod (`selinux-policy-ops` Requires it). Playbooks **fail** if `sesearch` is missing.

**Optional webhook** (still via `monitor_avc.sh` flags if you wrap the script): `--notify-webhook URL` on failure.

---

## 10. Phase 5 — Production canary host groups

Copy [`ansible/inventory.production.example.yml`](../../ansible/inventory.production.example.yml) to `ansible/inventory.production.yml`.

**Inventory layout:**

```text
inventory.production.yml
├── canary group     → prod-canary-1 only (first)
└── production group → all prod hosts (canary + fleet)
```

The `canary` group is **one node** for the first production deploy. The `production` group includes canary plus the rest of the fleet for later rollout.

**Step-by-step:**

```bash
# 1. Canary node only (permissive + policy install)
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit canary

# 2. Daily monitoring on canary during soak (AAP schedule or ansible-playbook)
ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml \
  --limit canary

# 3. Optional: permissive rollout to full fleet before enforce
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit production

# 4. AAP Promote to enforce (Soak status → approval → Enforce; change_ticket required)
ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e change_ticket=CHG123

# Break-glass only:
ansible-playbook ... enforce_production.yml -e change_ticket=CHG123 -e "force_enforce=true"
```

Production inventory uses **RPMs** (`policy_pp_src: ""`). Lab inventories pass `policy_pp_src` and `selinux_ops_from_package: false` — see [ansible/README.md](../../ansible/README.md).

**`--limit canary`** targets only hosts in the `canary` group — not the full fleet. Use `--limit production` when rolling policy to all nodes while still permissive.

---

## 11. Phase 6 — Emergency rollback

If enforce causes an outage, run **`ansible-playbook ... ansible/emergency_rollback.yml`** (AAP **SELinux – Rollback**, or optional GitHub **SELinux Policy Deploy** → `rollback`). The playbook **sets the domain permissive first** (stock `semanage` / Ansible modules), then optional **`dnf downgrade myapp-selinux-<version>`** when `rollback_dnf_version` is set, then `semodule -B`, `restorecon`, and service restarts. It exports AVCs to **`/tmp/emergency_avc.log`**.

**Policy generation is controller-only:** run **`ansible/generate_emergency_patch.yml`** against a **git checkout on localhost**. It writes `policy_out/` for a PR. Do **not** run it on production hosts or `semodule -i` the output. Optional `OPENAI_API_KEY` polishes `pr_summary.md` only. See [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md).

**Interrupted canary** (host left on `semodule -DB`): run **`ansible/reset_host_state.yml`** to restore dontaudit and clear permissive without changing the installed module.

Optional ops scripts (`wait_for_endpoints`, deploy report) run only when **`selinux-policy-ops`** is installed on the host.

See [`ansible/emergency_rollback.yml`](../../ansible/emergency_rollback.yml), [`ansible/reset_host_state.yml`](../../ansible/reset_host_state.yml), and [`ansible/generate_emergency_patch.yml`](../../ansible/generate_emergency_patch.yml).

The two-host talk track shows these commands in [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md) and `scripts/demo_e2e_rhel_prod.sh`.

---

## 12. Enforce pre-checks (automated)

`enforce_production.yml` runs before removing permissive:

1. **`collect_soak_facts.sh`** (role) — minimum soak days + **net-new** access needs (or raw AVC if `avc_fail_closed`) + passing deploy report with verified domain context (same checks as manual **`check_soak_ready.sh`** / **`soak_status.yml`**; optional **`--auto-tier`** with base/candidate policy paths on the controller)
2. **`verify_file_contexts.sh`** — labeling dry-run (`restorecon` + `.fc` is source of truth; includes `/var/log/myapp`)
3. **Remove stale `/run/myapp/notify.sock`** — avoids false-positive socket checks after restarts
4. **`systemctl restart`** — `myapp-backend.service` then `myapp.service`
5. **Unified readiness** — `bash scripts/wait_for_endpoints.sh` (systemd + domain context + all six HTTP endpoints)
6. **Deploy report** — `bash scripts/post_deploy_report.sh` writes `/var/lib/myapp/selinux_deploy_report.json` including `domain_context`

Enforce runs inside an Ansible **block/rescue**: if smoke tests or the deploy report fail, the playbook restores **`myapp_t` to permissive**, restarts services, re-checks endpoints, then fails with guidance to inspect AVCs and the deploy report.

```bash
bash scripts/wait_for_endpoints.sh --host 127.0.0.1 --retries 15 --delay 2
bash scripts/post_deploy_report.sh --phase enforce --domain myapp_t --var-dir /var/lib/myapp \
  --marker-file /var/lib/myapp/selinux_canary_deployed_at --project-root /path/to/selinux-pac
```

`deploy_canary.yml` runs the same Tier 6 endpoints (minus `/`) during canary exercise, with the same backend and notify-socket waits.

### `check_soak_ready.sh` — pass vs fail examples

Prefer **`ansible-playbook … soak_status.yml`** on the controller. The host CLI below is the same gate (`collect_soak_facts.sh` JSON). With `setools-console`, enforce uses **net-new**; the text below still shows the raw-count messages from the script when fail-closed.

**FAIL — canary deployed today:**

```bash
$ bash scripts/check_soak_ready.sh \
    --domain myapp_t \
    --marker-file /var/lib/myapp/selinux_canary_deployed_at

[INFO] Soak: 1 day(s) elapsed (minimum 7)
[INFO] AVCs since canary deploy for myapp_t: 0 (maximum 0)
[ERROR] Soak period not met — wait 6 more day(s) or use force_enforce=true (break-glass only)
```

**FAIL — AVCs still appearing:**

```bash
[INFO] Soak: 10 day(s) elapsed (minimum 7)
[INFO] AVCs since canary deploy for myapp_t: 2 (maximum 0)
[ERROR] Too many AVC denials since canary deploy (2 > 0)
```

**PASS — after 8 days, zero AVCs:**

```bash
$ bash scripts/check_soak_ready.sh \
    --domain myapp_t \
    --marker-file /var/lib/myapp/selinux_canary_deployed_at

[INFO] Soak: 8 day(s) elapsed (minimum 7)
[INFO] AVCs since canary deploy for myapp_t: 0 (maximum 0)
[INFO] Soak gate passed — safe to enforce myapp_t
```

Manual pre-check before enforce:

```bash
bash scripts/check_soak_ready.sh \
  --domain myapp_t \
  --marker-file /var/lib/myapp/selinux_canary_deployed_at
```

Optional blast-radius minimum (controller; requires previous + candidate module sources):

```bash
bash scripts/check_soak_ready.sh \
  --auto-tier \
  --base-policy selinux/myapp.te \
  --candidate-policy policy_out/myapp.te \
  --marker-file /var/lib/myapp/selinux_canary_deployed_at \
  --min-days 7
```

Logs **`Blast-radius tier:`** and **`Classifier reason:`** on success; on classifier failure keeps **`soak_min_days`** (fail-closed).

---

## 12.5 App team incident card

When SELinux deploy or enforce affects the app, app teams need fast, non-ambiguous signals — not generic HTTP 500s that look like application regressions.

### What you will see

| Signal | Likely meaning |
|--------|----------------|
| `systemctl status myapp` / `myapp-backend` → `failed` | Service did not start after policy restart |
| `GET /` returns `"selinux": { "domain_permissive": false, "mode": "Enforcing" }` | Enforce is active — denials now block |
| Endpoint JSON includes `"selinux_context"` and `"Permission denied"` | SELinux denial (check AVCs, not app logic first) |
| `/var/lib/myapp/selinux_deploy_report.json` with `"status": "fail"` | Last canary/enforce/rollback deploy did not pass smoke |

### 60-second checklist (app team)

```bash
systemctl is-active myapp myapp-backend
curl -sf http://127.0.0.1:8888/ | python3 -m json.tool
bash scripts/wait_for_endpoints.sh --host 127.0.0.1 --retries 3 --delay 2
cat /var/lib/myapp/selinux_deploy_report.json
```

### Do / do not

| Do | Do not |
|----|--------|
| Page the SELinux/admin on-call with deploy phase + report JSON | Run `setenforce 0` globally |
| Capture `ausearch -m avc -ts recent` excerpt | Add broad `bin_t` execute rules locally |
| Retry after admin sets domain permissive or patches policy | Re-deploy app code alone without policy fix |

### Expected recovery loop

Follow [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md). Do not live-patch the host.

```text
Outage → AAP Rollback (domain permissive) → export AVCs → policy PR → AAP Release canary → soak → Promote to enforce
```

Deploy feedback artifact: **`/var/lib/myapp/selinux_deploy_report.json`** (written by canary, enforce, and rollback playbooks). Soak-fail artifact: **`/var/lib/myapp/selinux_soak_last_fail.json`**.

---

## 13. Admin sign-off checklist

Before you enforce on production, confirm:

- [ ] Staging soak **7+ days** complete
- [ ] `soak_monitor.yml` (or `monitor_avc.sh --max-net-new 0`) clean for a full business cycle (including weekends)
- [ ] Prod canary host deployed and soaked separately
- [ ] `verify_file_contexts.sh` passed after last canary deploy
- [ ] Backend unit active; health and notify probes succeed on canary host
- [ ] PR admin review table signed off ([PR template](../../.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md))
- [ ] Change ticket documents enforce window and rollback owner
- [ ] Rollback playbook tested on staging **or** on-call briefed on `emergency_rollback.yml`
- [ ] `semanage permissive -l` shows the app domain on target hosts (still permissive pre-enforce)
- [ ] `setools-console` installed on canary/prod (`sesearch` required; playbooks fail if missing)

---

## 14. Troubleshooting

| Problem | What it looks like | What to do |
|---------|-------------------|------------|
| **Enforce fails soak gate** | `Soak period not met` or `Too many AVC denials` | Wait remaining days; fix policy from AVCs; redeploy canary — do **not** use `force_enforce` without approval |
| **Mislabeled files after deploy** | `verify_file_contexts.sh` fails | Run `restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp`; re-verify; see [Basics §6](../policy/SELINUX_BASICS.md) |
| **AVCs spike during soak** | `soak_monitor.yml` fails (`net_new_count` > 0) | [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md) — copy `selinux_soak_last_fail.*`, PR, recanary; **reset soak clock**. Do **not** `semodule -i` on the host |
| **Ansible inventory missing** | `Could not match supplied host pattern` | Copy `inventory.production.example.yml` → `inventory.production.yml`; set real hostnames |
| **Canary marker missing** | `Canary marker not found` | Run `deploy_canary.yml` first — marker is written on canary deploy |
| **Audit tools unavailable** | `Could not determine AVC count` | Install `audit` package; ensure `auditd` is running |
| **App fails after enforce** | curl errors; AVCs in enforcing mode | `semanage permissive -a myapp_t` immediately; run emergency rollback playbook |
| **`/notify-socket` fails post-enforce** | HTTP 500; stale socket on disk | Remove `/run/myapp/notify.sock` and restart backend; playbooks do this automatically |
| **`/probe-backend` fails post-enforce** | `Permission denied` on TCP connect | Check backend on `:8889`; look for `tcp_socket getopt` or `cert_t` AVCs on `myapp_t` |
| **`/run-script` fails post-enforce** | `Permission denied` on `/usr/bin/*` | Do not add `bin_t:file execute` — fix `backup.sh` to use bash builtins |
| **Wrong cron path** | cron job fails silently | Use AAP **Soak monitor** or `/usr/libexec/selinux-policy-ops/monitor_avc.sh` — do **not** clone this repo onto prod |

---

## 15. CI mapping (developer PR)

| Admin PR table row | CI job |
| --- | --- |
| No over-permissive grants | `forbidden-patterns` |
| Compilation test | `compile-policy` |
| Semantic policy checks | `policy-semantics` (`sesearch` via `validate_policy_semantics.sh`) |
| Version SSOT | `version-consistency` |
| Policy access delta (review aid) | `policy-diff-comment` + `assemble_pr_body.sh` locally |
| Soak tier logic (do not change without fixtures) | `blast-radius` |
| Canary readiness | AAP **Release canary** / `deploy_canary.yml` (optional GHA `staging-canary` on merge) |
| Post-canary endpoint smoke | `wait_for_endpoints.sh` + deploy report (`staging-endpoint-smoke` if using GHA) |
| Canary AVC gate at deploy | `deploy_canary.yml` (`canary_max_avc`, default 0) |
| Soak net-new | `soak_monitor.yml` / `collect_soak_facts.sh` (`soak_max_net_new`) |

**GitHub Actions secrets (optional):**

| Secret | Used by | Purpose |
|--------|---------|---------|
| `OPENAI_API_KEY` | `emergency_rollback.yml`, deploy workflow | Emergency policy patch generation |
| `INCIDENT_WEBHOOK_URL` | [`.github/workflows/selinux-deploy.yml`](../../.github/workflows/selinux-deploy.yml) | POST pass/fail notification; Ansible logs uploaded as artifact on failure |

Packaged installs: [`packaging/myapp-selinux.spec`](../../packaging/myapp-selinux.spec) builds an RPM from `selinux/` for hosts that prefer package delivery over playbook copy.

Developer workflow and PR assembly: [README.md](../../README.md) and [DEMO_GUIDE.md acts 3–5](../training/DEMO_GUIDE.md).

---

## Document map

| Guide | Sections to read | Audience |
|-------|------------------|----------|
| [SELINUX_BASICS.md](../policy/SELINUX_BASICS.md) | §7 two-layer model; §7.5 soak timeline; §8 avc.log filter | New to SELinux |
| [SELINUX_BEST_PRACTICES.md](../policy/SELINUX_BEST_PRACTICES.md) | §1–6 principles; §8 review checklist | Policy authors and security reviewers |
| [DEMO_GUIDE.md](../training/DEMO_GUIDE.md) | Three-window typewriter demo (`demo_e2e_*.sh`) | Presenters |
| [DETERMINISTIC_POLICY.md](../developers/DETERMINISTIC_POLICY.md) | Default offline generator, sepolgen banners, fixtures | Policy authors without LLM |
| [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md) | AAP workflows in `ansible/aap/`, soak monitor, extra-vars | RHEL admins |
| [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md) | File/port AVC after ship → PR, not live patch | RHEL admins |
| [ADOPTION_CHECKLIST.md](ADOPTION_CHECKLIST.md) | CODEOWNERS, inventories, RPM repo | Platform team |
| **This file** | §3.5 soak; §5–14 phases and checklist | RHEL admins |
| [README.md](../../README.md) | Developer commands + admin pointer | Day-to-day |
