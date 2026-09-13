# SELinux Policy-as-Code (PaC) Automation

Shift-left DevSecOps workflow: application teams version-control SELinux policy alongside code, generate updates from AVC audit logs with AI, and deploy safely via **per-domain permissive canary**, **enforce**, and **emergency rollback** Ansible playbooks.

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
├── app/                    Flask app + systemd unit + logrotate config
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

### Branch protection (recommended)

Require these status checks on PRs touching `selinux/**`:

- `smoke-tests`
- `forbidden-patterns`
- `compile-policy`

Require review from CODEOWNERS (`.github/CODEOWNERS`) for `selinux/` and `ansible/`.

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
bash scripts/compile_and_validate.sh selinux
bash scripts/compile_and_validate.sh policy_out   # after AI generation
```

---

## Admins — production deployment

### Deploy paths (RHEL admin model)

| When | Who | How |
|------|-----|-----|
| PR open | CI (automatic) | `smoke-tests`, `forbidden-patterns`, `compile-policy` |
| Merge to `main` | Pipeline (automatic) | [`.github/workflows/selinux-staging-canary.yml`](.github/workflows/selinux-staging-canary.yml) → staging canary |
| Production cutover | Admin (manual) | **SELinux Policy Deploy** → `enforce` + GitHub `production` Environment approval |

Production is **never** auto-enforced on merge.

Full admin runbook: [`docs/PRODUCTION_READINESS.md`](docs/PRODUCTION_READINESS.md) — soak, canary hosts, enforce gates, pass/fail examples, and admin sign-off checklist.

### GitHub Actions deploy (recommended)

Requires a **self-hosted runner** on a SELinux host:

| Runner label | Environment | Inventory file |
|--------------|-------------|----------------|
| `selinux-staging` | `staging` | `ansible/inventory.staging.yml` (copy from [`inventory.staging.example.yml`](ansible/inventory.staging.example.yml)) |
| `selinux-production` | `production` | `ansible/inventory.production.yml` (copy from [`inventory.production.example.yml`](ansible/inventory.production.example.yml)) |

1. GitHub → **Actions** → **SELinux Policy Deploy** → **Run workflow**
2. Choose `canary` on `staging`, monitor AVCs daily: `bash scripts/monitor_avc.sh --domain myapp_t --max-avc 0`
3. Deploy to **prod canary host**: `ansible-playbook ... deploy_canary.yml --limit canary`
4. After 7+ day soak (`check_soak_ready.sh` passes), choose `enforce` on `production` (configure Environment required reviewers)

Secrets (optional, for emergency rollback AI patch): `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_API_MODEL`

### Manual Ansible (AWX/Tower compatible)

### Canary (permissive domain + policy install)

```bash
bash scripts/compile_and_validate.sh selinux
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit canary \
  -e "policy_pp_path=$(pwd)/selinux/myapp.pp"
bash scripts/monitor_avc.sh --domain myapp_t --marker-file /var/myapp/selinux_canary_deployed_at
bash scripts/verify_file_contexts.sh --install-root /opt/myapp --var-dir /var/myapp
```

### Enforce production

```bash
bash scripts/check_soak_ready.sh --domain myapp_t --marker-file /var/myapp/selinux_canary_deployed_at
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

- Policy source of truth: **`selinux/`** — never commit `.pp` or API keys.
- Unlike blind `audit2allow`, this workflow uses **AI + forbidden-pattern CI + human review**.
- Always **`semodule -r myapp`** before upgrading module (handled in `apply_policy.sh` and Ansible).
- FCOS: run explicit **`chcon`** after `restorecon` on `/opt/myapp/venv` (automated in setup/Ansible).
- AI-generated `.te` files must use **`policy_module()`** syntax; the CLI includes compile-retry.

This is a **proof of concept**. All AI-generated policy requires human security review before production.

---

## Documentation

| Guide | For |
|-------|-----|
| [docs/SELINUX_BASICS.md](docs/SELINUX_BASICS.md) | **New to SELinux** — labels, `.te`/`.fc`/`.pp`, `restorecon`, `semanage` commands with example output |
| [docs/DEMO_GUIDE.md](docs/DEMO_GUIDE.md) | Workshop demo for newbies — 10 acts, example output, observer vs presenter paths |
| [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) | Post-demo admin runbook — soak, canary hosts, enforce gates, with pass/fail examples |
