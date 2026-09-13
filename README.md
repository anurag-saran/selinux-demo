# SELinux Policy-as-Code (PaC) Automation

Shift-left DevSecOps workflow: application teams version-control SELinux policy alongside code, generate updates from AVC audit logs with AI, and deploy safely via **per-domain permissive canary**, **enforce**, and **emergency rollback** Ansible playbooks.

**Security model:** The host stays **`getenforce` = Enforcing** throughout staging and soak. Only the app domain (`myapp_t`) is set permissive via `semanage permissive -a myapp_t` so AVCs are logged without blocking the app. Export filters `policy_out/avc.log` to app-related denials; enforce removes permissive after soak gates pass.

## Architecture

```text
App change → staging (permissive myapp_t) → AVC logs
    → cli/selinux_gen.py (merge + version bump + pr_summary.md)
    → PR review → compile_and_validate.sh
    → ansible/deploy_canary.yml → ansible/enforce_production.yml
```

## Project layout

```text
selinux-demo/
├── app/                    Flask app, backend stub, systemd units, logrotate config
│   ├── app.py              Six demo HTTP endpoints (incl. Tier 6 network probes)
│   ├── backend_stub.py     Backend on :8889 + /run/myapp/notify.sock (myapp_backend_t)
│   └── bin/backup.sh       Executed by /run-script (bash builtins only)
├── cli/                    selinux_gen.py — AI policy CLI
├── selinux/                Version-controlled policy (source of truth)
│   ├── myapp.te / myapp.fc
│   ├── policy_version.txt
│   └── stub/               Permissive staging module
├── ansible/                Canary, enforce, emergency rollback
├── scripts/                Setup, compile, demo, Podman VM helpers
├── policy_out/             Build artifacts (gitignored .pp, avc exports)
└── .github/                PR template for security review
```

---

## Self-Service Workflow (App Team → Admin Team)

```text
┌─────────────────────────────────────────────────────────┐
│ APPLICATION TEAM                                        │
│  1. setup_staging_env.sh (permissive) + integration tests│
│  2. dev_generate_policy.sh → selinux/ + pr_summary.md   │
│  3. Open PR (CI validates compile + forbidden patterns) │
└───────────────────────────┬─────────────────────────────┘
                            │ Git Pull Request
                            ▼
┌─────────────────────────────────────────────────────────┐
│ ADMIN / SECURITY TEAM                                   │
│  1. Review plain-English pr_summary.md + CODEOWNERS     │
│  2. Approve & merge                                     │
│  3. Deploy workflow: canary → monitor → enforce         │
└─────────────────────────────────────────────────────────┘
```

| Role | Command |
|------|---------|
| **Developer (one command)** | `bash scripts/dev_generate_policy.sh --use-vm --apply` |
| **Developer (open PR)** | `bash scripts/dev_generate_policy.sh --use-vm --apply --open-pr` |
| **Developer (CLI alias)** | `bash scripts/selinux-gen --help` |
| **PR body assembly** | `bash scripts/assemble_pr_body.sh` → `policy_out/pr_body.md` |
| **CI (automatic on PR)** | `.github/workflows/selinux-policy-ci.yml` |
| **Admin canary** | GitHub Actions → **SELinux Policy Deploy** → `canary` / `staging` |
| **Admin enforce** | Same workflow → `enforce` / `production` (Environment approval) |
| **Admin rollback** | Same workflow → `rollback` |
| **App team incident card** | [`docs/PRODUCTION_READINESS.md`](docs/PRODUCTION_READINESS.md) §12.5 — checks when SELinux deploy breaks startup |

### Branch protection (recommended)

Require these status checks on PRs touching `selinux/**`:

- `smoke-tests`
- `forbidden-patterns`
- `compile-policy`

Require review from CODEOWNERS (`.github/CODEOWNERS`) for `selinux/` and `ansible/`. Replace the placeholder `@your-org/security-team` in `.github/CODEOWNERS` before using branch protection in your org.

---

## Developers

### Quick start (self-service)

```bash
pip3 install -r cli/requirements.txt
export OPENAI_API_KEY="your-key"

# Staging + tests (native Linux)
sudo bash scripts/setup_staging_env.sh
curl http://127.0.0.1:8888/save-log
curl http://127.0.0.1:8888/run-script
curl http://127.0.0.1:8888/rotate-log
curl http://127.0.0.1:8888/probe-backend
curl http://127.0.0.1:8888/notify-socket

# Tier 6 endpoints require myapp-backend.service (installed by setup_staging_env.sh):
#   /probe-backend  → TCP client to 127.0.0.1:8889 (myapp_backend_t)
#   /notify-socket  → Unix client to /run/myapp/notify.sock

# macOS: use --use-vm to export AVCs from Podman VM
bash scripts/dev_generate_policy.sh --use-vm --apply

# Optional: open PR with assembled body + labels
bash scripts/dev_generate_policy.sh --use-vm --apply --open-pr
```

This exports AVCs, runs AI generation, copies results into `selinux/`, assembles `policy_out/pr_body.md`, and prints PR steps.

### 1. Staging environment (permissive)

```bash
sudo bash scripts/setup_staging_env.sh
curl http://127.0.0.1:8888/save-log
curl http://127.0.0.1:8888/run-script
curl http://127.0.0.1:8888/rotate-log
curl http://127.0.0.1:8888/probe-backend
curl http://127.0.0.1:8888/notify-socket

# Tier 6 endpoints require myapp-backend.service (installed by setup_staging_env.sh):
#   /probe-backend  → TCP client to 127.0.0.1:8889 (myapp_backend_t)
#   /notify-socket  → Unix client to /run/myapp/notify.sock
```

### 2. Export AVC logs

```bash
# Native Linux
sudo ausearch -m avc -ts boot --raw | grep myapp > policy_out/avc.log

# macOS + Podman VM
bash scripts/run_on_podman_vm.sh export-avcs
```

### 3. Generate policy update

```bash
pip3 install -r cli/requirements.txt
export OPENAI_API_KEY="your-key"
# Optional LiteLLM / workshop endpoint:
export OPENAI_BASE_URL="https://your-litellm-host/v1"
export OPENAI_API_MODEL="qwen3-14b"

python3 cli/selinux_gen.py \
  --app-name myapp \
  --audit-log policy_out/avc.log \
  --existing-te selinux/myapp.te \
  --existing-fc selinux/myapp.fc \
  --bump-version \
  --validate-compile \
  --generate-only \
  --output-dir policy_out
```

Outputs: `policy_out/myapp.te`, `myapp.fc`, `pr_summary.md`, `pr_body.md`, updated `selinux/policy_version.txt`.

### 4. Open a PR

```bash
bash scripts/assemble_pr_body.sh
gh pr create \
  --title "security(selinux): Update policy module for myapp" \
  --body-file policy_out/pr_body.md \
  --label security --label selinux --label pending-admin-review
```

Template: [`.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md`](.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md) (admin Pass/Reject table + CI check mapping).

---

## CI / validation

Runs automatically on PRs via [`.github/workflows/selinux-policy-ci.yml`](.github/workflows/selinux-policy-ci.yml).

Local equivalents:

```bash
python3 scripts/smoke_test.py
bash scripts/validate_forbidden_patterns.sh selinux
bash scripts/compile_and_validate.sh selinux      # refpolicy Makefile (checkmodule fallback)
bash scripts/validate_policy_semantics.sh selinux   # sesearch assertions (CI: policy-semantics job)
bash scripts/compile_and_validate.sh policy_out   # after AI generation
```

PR CI also runs **`policy-semantics`** (`sesearch` via `validate_policy_semantics.sh`). Packaged installs: [`packaging/myapp-selinux.spec`](packaging/myapp-selinux.spec) builds an RPM from `selinux/`.

---

## Admins — production deployment

### Deploy paths (RHEL admin model)

| When | Who | How |
|------|-----|-----|
| PR open | CI (automatic) | `smoke-tests`, `forbidden-patterns`, `compile-policy` |
| Merge to `main` | Pipeline (automatic) | [`.github/workflows/selinux-staging-canary.yml`](.github/workflows/selinux-staging-canary.yml) → `staging-canary` + `staging-endpoint-smoke` |
| Production cutover | Admin (manual) | **SELinux Policy Deploy** → `enforce` + GitHub `production` Environment approval |

Production is **never** auto-enforced on merge.

Full admin runbook: [`docs/PRODUCTION_READINESS.md`](docs/PRODUCTION_READINESS.md) — soak, canary hosts, enforce gates, deploy report JSON, app team incident card (§12.5), pass/fail examples, and admin sign-off checklist.

### GitHub Actions deploy (recommended)

Requires a **self-hosted runner** on a SELinux host:

| Runner label | Environment | Inventory file |
|--------------|-------------|----------------|
| `selinux-staging` | `staging` | `ansible/inventory.staging.yml` (copy from [`inventory.staging.example.yml`](ansible/inventory.staging.example.yml)) |
| `selinux-production` | `production` | `ansible/inventory.production.yml` (copy from [`inventory.production.example.yml`](ansible/inventory.production.example.yml)) |

1. GitHub → **Actions** → **SELinux Policy Deploy** → **Run workflow**
2. Choose `canary` on `staging`, monitor AVCs daily: `bash scripts/monitor_avc.sh --domain myapp_t --max-avc 0`
3. After merge to `main`, CI runs **`staging-endpoint-smoke`** (`wait_for_endpoints.sh` + deploy report check on the staging runner)
4. Deploy to **prod canary host**: `ansible-playbook ... deploy_canary.yml --limit canary` (fails if `canary_max_avc` exceeded, default 0)
5. After 7+ day soak (`check_soak_ready.sh` passes — requires a passing deploy report at `/var/lib/myapp/selinux_deploy_report.json`), choose `enforce` on `production` (configure Environment required reviewers)

Canary runs **`semodule -DB`** during soak so dontaudit rules do not hide AVCs. Canary, enforce, and rollback playbooks all run **`wait_for_endpoints.sh`** (six HTTP endpoints + backend) and write **`/var/lib/myapp/selinux_deploy_report.json`** via **`post_deploy_report.sh`**. Enforce uses an Ansible **block/rescue** — on failure, `myapp_t` is restored to permissive and services are restarted before the playbook fails.

Secrets (optional):

| Secret | Purpose |
|--------|---------|
| `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_API_MODEL` | Emergency rollback AI patch generation |
| `INCIDENT_WEBHOOK_URL` | Pass/fail notification from **SELinux Policy Deploy** workflow |

### Reliability scripts (canary / enforce / rollback)

| Script | Purpose |
|--------|---------|
| [`scripts/wait_for_endpoints.sh`](scripts/wait_for_endpoints.sh) | Unified systemd + six HTTP endpoint readiness check |
| [`scripts/post_deploy_report.sh`](scripts/post_deploy_report.sh) | Writes `/var/lib/myapp/selinux_deploy_report.json` deploy feedback |
| [`scripts/lib/vm_ready.sh`](scripts/lib/vm_ready.sh) | Podman VM SSH readiness and recovery hints (macOS demo path) |

### Manual Ansible (AWX/Tower compatible)

#### Canary (permissive domain + policy install)

```bash
bash scripts/compile_and_validate.sh selinux
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit canary \
  -e "policy_pp_path=$(pwd)/selinux/myapp.pp"
bash scripts/monitor_avc.sh --domain myapp_t --marker-file /var/lib/myapp/selinux_canary_deployed_at
bash scripts/verify_file_contexts.sh --install-root /opt/myapp --var-dir /var/lib/myapp
```

### Enforce production

```bash
bash scripts/check_soak_ready.sh --domain myapp_t --marker-file /var/lib/myapp/selinux_canary_deployed_at
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e "policy_pp_path=$(pwd)/selinux/myapp.pp"
# Break-glass only: add -e "force_enforce=true"
```

### Emergency rollback

```bash
export OPENAI_API_KEY="your-key"
ansible-playbook -i ansible/inventory.example.yml ansible/emergency_rollback.yml
```

Direct apply (without Ansible):

```bash
# Production canary (keeps myapp_t permissive + soak marker):
sudo bash scripts/apply_policy.sh --canary policy_out

# Dev/FCOS only — enforces immediately (skips soak gate):
sudo bash scripts/apply_policy.sh policy_out
```

---

## macOS developers (Podman VM)

```bash
source ~/.local/share/selinux-demo/podman/env.sh
bash scripts/demo_present.sh --use-vm --demo-mode
bash scripts/run_on_podman_vm.sh export-avcs
export OPENAI_API_KEY="your-key"
bash scripts/run_on_podman_vm.sh generate-policy
bash scripts/run_on_podman_vm.sh apply-policy
```

---

## Workshop demo (presenter)

**New to the demo?** Follow the learning path: [`docs/SELINUX_BASICS.md`](docs/SELINUX_BASICS.md) → [`docs/DEMO_GUIDE.md`](docs/DEMO_GUIDE.md) (10 acts, example output, presenter vs observer paths).

Paced narration with pauses between acts (dev → PR → canary → guardrails → enforce):

```bash
export OPENAI_API_KEY="your-key"
sudo bash scripts/demo_present.sh --demo-mode

# Rehearsal (no pauses):
sudo bash scripts/demo_present.sh --demo-mode --auto

# macOS (Podman VM for SELinux acts):
bash scripts/demo_present.sh --use-vm --demo-mode

# No API key (existing policy_out/ artifacts):
sudo bash scripts/demo_present.sh --skip-ai --demo-mode --acts 1-7
```

`--demo-mode` bypasses the **7-day soak gate only** for workshop time limits. Production requires full soak per [`docs/PRODUCTION_READINESS.md`](docs/PRODUCTION_READINESS.md).

---

## End-to-end demo (native Linux)

```bash
export OPENAI_API_KEY="your-key"
sudo bash scripts/run_demo.sh
```

Fast unattended path (no narration). Uses `force_enforce=true` on the enforce step for demo compatibility.

---

## CLI reference

**Wrapper:** `bash scripts/selinux-gen` (alias for `cli/selinux_gen.py`)

| Flag | Description |
|------|-------------|
| `--app-name` | Module name (default: `myapp`) |
| `--audit-log` / `--avc-file` | AVC input file |
| `--existing-te` / `--existing-fc` | Policy to extend |
| `--bump-version` | Increment `selinux/policy_version.txt` |
| `--generate-only` | Write artifacts only (no install) |
| `--validate-compile` | Compile-check via checkmodule or podman |
| `--apply` | Compile + `semodule -i` (root) |

Environment: `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_API_MODEL`, `OPENAI_TIMEOUT`.

---

## Safety notes

- Policy source of truth: **`selinux/`** — never commit API keys. Compiled `.pp` for `selinux/` is tracked; `policy_out/*.pp` is build output.
- Current module version: **`selinux/policy_version.txt`** (1.1.0 — FHS paths, Tier 6 enforcing smoke tests for all six endpoints).
- Unlike blind `audit2allow`, this workflow uses **AI + forbidden-pattern CI + semantic `sesearch` checks + human review** — see [docs/SELINUX_BEST_PRACTICES.md](docs/SELINUX_BEST_PRACTICES.md).
- **`semodule -i`** upgrades the module in place — no `semodule -r` step before install (handled in `apply_policy.sh` and Ansible).
- Path labels come from **`myapp.fc`** — run **`restorecon`** after install; `.fc` is the source of truth (no manual `chcon`).
- AI-generated `.te` files must use **`policy_module()`** syntax; the CLI includes compile-retry.

This is a **proof of concept**. All AI-generated policy requires human security review before production.

---

## Documentation

| Guide | For |
|-------|-----|
| [docs/SELINUX_BASICS.md](docs/SELINUX_BASICS.md) | **New to SELinux** — labels, `.te`/`.fc`/`.pp`, `restorecon`, `semanage` commands with example output |
| [docs/DEMO_GUIDE.md](docs/DEMO_GUIDE.md) | Workshop demo for newbies — 10 acts, example output, observer vs presenter paths |
| [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) | Post-demo admin runbook — soak, canary hosts, enforce gates, deploy report JSON, incident card §12.5, pass/fail examples |
| [docs/SELINUX_BEST_PRACTICES.md](docs/SELINUX_BEST_PRACTICES.md) | **Policy-as-Code principles** — refpolicy interfaces, labeling, CI gates, soak/enforce anti-patterns (admin + reviewer checklist) |
