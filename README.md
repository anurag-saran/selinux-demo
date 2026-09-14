# SELinux Policy-as-Code (PaC) Automation

Shift-left DevSecOps workflow: application teams version-control SELinux policy alongside code, generate updates from AVC audit logs with AI, and deploy safely via **per-domain permissive canary**, **enforce**, and **emergency rollback** Ansible playbooks.

**Security model:** The host stays **`getenforce` = Enforcing** throughout staging and soak. Only the app domain (`myapp_t`) is set permissive via `semanage permissive -a myapp_t` so AVCs are logged without blocking the app. Export filters `policy_out/avc.log` to app-related denials; enforce removes permissive after soak gates pass.

## Architecture

```text
App change → staging (permissive myapp_t) → AVC logs
    → cli/deterministic_gen.py (default) or selinux_gen.py (LLM)
    → merge + version bump + pr_summary.md + findings.json
    → PR review → compile_and_validate.sh (UBI 9 compile image, pull-first)
    → ansible/deploy_canary.yml → ansible/enforce_production.yml
```

## Project layout

```text
selinux-demo/
├── app/                    Flask app, backend stub, systemd units, logrotate config
│   ├── app.py              Six demo HTTP endpoints (incl. Tier 6 network probes)
│   ├── backend_stub.py     Backend on :8889 + /run/myapp/notify.sock (myapp_backend_t)
│   └── bin/backup.sh       Executed by /run-script (bash builtins only)
├── cli/                    deterministic_gen.py (default), selinux_gen.py (LLM), verify_avc_coverage.py
├── config/                 App manifests (paths, probes, deploy artifacts)
│   ├── myapp.manifest.yml  Demo app manifest (drives readiness scripts)
│   └── README.md           Schema + onboarding for new apps
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
| **Developer (offline / no API)** | `bash scripts/dev_generate_policy.sh --skip-export` — deterministic engine is default; see [docs/DETERMINISTIC_POLICY.md](docs/DETERMINISTIC_POLICY.md) |
| **Developer (LLM path)** | `bash scripts/dev_generate_policy.sh --engine llm --use-vm --apply` |
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
- `app-manifest`
- `forbidden-patterns`
- `compile-policy`

Require review from CODEOWNERS (`.github/CODEOWNERS`) for `selinux/` and `ansible/`. Replace the placeholder `@your-org/security-team` in `.github/CODEOWNERS` before using branch protection in your org.

---

## Developers

### Quick start (self-service)

```bash
pip3 install -r cli/requirements.txt
export OPENAI_API_KEY="your-key"   # only for --engine llm

# macOS / laptop without native selinux-policy-devel: pull prebuilt **UBI 9** image (Red Hat demo), or build once
export SELINUX_BUILD_IMAGE="${SELINUX_BUILD_IMAGE:-docker.io/asaran/selinux-demo-selinux-build:ubi9}"
# Pull-first on first compile (SELINUX_BUILD_IMAGE_PULL=1, default). See [docs/DOCKER_HUB_COMPILE_IMAGE.md](docs/DOCKER_HUB_COMPILE_IMAGE.md).

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

# Optional: enforce-check before PR (compile + domain context + endpoints)
bash scripts/dev_generate_policy.sh --use-vm --apply --enforce-check

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

Outputs: `policy_out/myapp.te`, `myapp.fc`, `pr_summary.md`, `pr_body.md`, and updated `selinux/policy_version.txt` when promoted with `--apply`. PR access delta is filled by [`assemble_pr_body.sh`](scripts/assemble_pr_body.sh) (merge-base **sesearch** diff via [`policy_module_diff.sh`](scripts/lib/policy_module_diff.sh)).

### 4. Open a PR

```bash
bash scripts/assemble_pr_body.sh   # needs git merge-base + Podman for full §2.5 delta; --skip-policy-diff for offline smoke only
gh pr create \
  --title "security(selinux): Update policy module for myapp" \
  --body-file policy_out/pr_body.md \
  --label security --label selinux --label pending-admin-review
```

Template: [`.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md`](.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md) (admin Pass/Reject table + CI check mapping).

---

## CI / validation

Runs automatically on PRs via [`.github/workflows/selinux-policy-ci.yml`](.github/workflows/selinux-policy-ci.yml).

| Job | Purpose |
|-----|---------|
| `smoke-tests` | Python unit/smoke tests (deterministic **8-verdict** fixtures, version consistency, blast-radius fail-closed) |
| `forbidden-patterns` | Wildcards and high-privilege denies in `.te` |
| `version-consistency` | `policy_version.txt`, `policy_module()` in `.te`, and RPM spec wiring agree |
| `compile-policy` / `policy-semantics` | Refpolicy build + container `sesearch` assertions |
| `blast-radius` | [`tests/fixtures/blast_radius/`](tests/fixtures/blast_radius/) vs [`classify_policy_blast_radius.sh`](scripts/classify_policy_blast_radius.sh) |
| `policy-diff-comment` | PR comment with merge-base **sesearch** access delta (not `sediff` on `.pp`) |
| `ansible-lint`, `yamllint`, `shellcheck`, `app-manifest`, `rpm-ops-parity` | Supporting gates |

Local equivalents:

```bash
python3 scripts/smoke_test.py
bash scripts/validate_forbidden_patterns.sh selinux
bash scripts/lib/selinux_build_image.sh pull    # or ensure (pull → local UBI9 build)
bash scripts/compile_and_validate.sh selinux      # refpolicy Makefile in compile image
bash scripts/validate_policy_semantics.sh selinux   # sesearch assertions (CI: policy-semantics job)
bash scripts/validate_version_consistency.sh      # version SSOT (CI: version-consistency)
bash scripts/run_blast_radius_fixtures.sh       # soak tier fixtures (CI: blast-radius; needs Podman)
bash scripts/assemble_pr_body.sh                # PR body + merge-base policy access delta
bash scripts/compile_and_validate.sh policy_out   # after generation
```

PR CI also runs **`policy-semantics`** (`sesearch` via `validate_policy_semantics.sh`). Packaged installs: [`packaging/myapp-selinux.spec`](packaging/myapp-selinux.spec) builds an RPM from `selinux/`.

Full test matrix: [`docs/TESTING.md`](docs/TESTING.md). Ansible playbook reference: [`ansible/README.md`](ansible/README.md).

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
5. After soak (default **7** days; optional **`check_soak_ready.sh --auto-tier`** with `--base-policy` / `--candidate-policy` for blast-radius tiering — fail-closed on classifier errors), run **SELinux Policy Deploy** → `enforce` on `production`. Ansible enforce uses **`collect_soak_facts.sh`** with fixed `soak_min_days` unless you wire tiering on the controller separately ([`classify_policy_blast_radius.sh`](scripts/classify_policy_blast_radius.sh), gated by [`tests/fixtures/blast_radius/`](tests/fixtures/blast_radius/)).

Canary runs **`semodule -DB`** during soak so dontaudit rules do not hide AVCs. Canary, enforce, and rollback playbooks all run **`wait_for_endpoints.sh`** (six HTTP endpoints + backend + **SELinux domain verification**) and write **`/var/lib/myapp/selinux_deploy_report.json`** via **`post_deploy_report.sh`**. Failed canary and rollback restore **`semodule -B`**. Enforce uses an Ansible **block/rescue** — on failure, `myapp_t` is restored to permissive and services are restarted before the playbook fails.

Secrets (optional):

| Secret | Purpose |
|--------|---------|
| `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_API_MODEL` | Emergency rollback AI patch generation |
| `INCIDENT_WEBHOOK_URL` | Pass/fail notification from **SELinux Policy Deploy** workflow |

### Reliability scripts (canary / enforce / rollback)

| Script | Purpose |
|--------|---------|
| [`scripts/wait_for_endpoints.sh`](scripts/wait_for_endpoints.sh) | Unified systemd + six HTTP endpoint readiness + domain-context check |
| [`scripts/post_deploy_report.sh`](scripts/post_deploy_report.sh) | Writes `/var/lib/myapp/selinux_deploy_report.json` deploy feedback |
| [`scripts/lib/vm_ready.sh`](scripts/lib/vm_ready.sh) | Podman VM SSH readiness and recovery hints (macOS demo path) |

### Manual Ansible (AWX/Tower compatible)

#### Canary (permissive domain + policy install)

```bash
bash scripts/compile_and_validate.sh selinux
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml \
  --limit canary \
  -e "policy_pp_src=$(pwd)/selinux/myapp.pp" \
  -e "policy_artifact_dir=$(pwd)"
bash scripts/monitor_avc.sh --domain myapp_t --marker-file /var/lib/myapp/selinux_canary_deployed_at
bash scripts/verify_file_contexts.sh --install-root /opt/myapp --var-dir /var/lib/myapp --log-dir /var/log/myapp
```

### Enforce production

```bash
bash scripts/check_soak_ready.sh --domain myapp_t --marker-file /var/lib/myapp/selinux_canary_deployed_at
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e "policy_pp_src=$(pwd)/selinux/myapp.pp" \
  -e "policy_artifact_dir=$(pwd)"
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

**New to the demo?** Follow the learning path: [`docs/SELINUX_BASICS.md`](docs/SELINUX_BASICS.md) → [`docs/DEMO_GUIDE.md`](docs/DEMO_GUIDE.md) (10 acts). **New to the codebase?** See [`docs/CODE_WALKTHROUGH.md`](docs/CODE_WALKTHROUGH.md).

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

- Policy source of truth: **`selinux/`** — never commit API keys. Compiled **`selinux/myapp.pp`** is a CI artifact (build with `compile_and_validate.sh` before deploy); `policy_out/*.pp` is generation output.
- **SemVer:** single source of truth is **`selinux/policy_version.txt`** — keep `policy_module(myapp, …)` in `.te` in sync (CI **`version-consistency`**). RPM **`Version:`** comes from that file via [`packaging/build_rpms.sh`](packaging/build_rpms.sh). Ansible reads the same file at runtime (no hardcoded version in inventory).
- Unlike blind `audit2allow`, this workflow uses **AI + forbidden-pattern CI + semantic `sesearch` checks + human review** — see [docs/SELINUX_BEST_PRACTICES.md](docs/SELINUX_BEST_PRACTICES.md).
- **`semodule -i`** upgrades the module in place — no `semodule -r` step before install (handled in `apply_policy.sh` and Ansible).
- Path labels come from **`myapp.fc`** — run **`restorecon`** after install; `.fc` is the source of truth (no manual `chcon`).
- AI-generated `.te` files must use **`policy_module()`** syntax; the CLI includes compile-retry.

This is a **proof of concept**. All AI-generated policy requires human security review before production.

---

## Documentation

| Guide | For |
|-------|-----|
| [docs/DETERMINISTIC_POLICY.md](docs/DETERMINISTIC_POLICY.md) | **Default generator** — house rules, sepolgen banners, `findings.json`, fixture catalog |
| [docs/DOCKER_HUB_COMPILE_IMAGE.md](docs/DOCKER_HUB_COMPILE_IMAGE.md) | **Red Hat demo compiles** — UBI 9 image on Docker Hub, pull-first env vars, publish script |
| [docs/CODE_WALKTHROUGH.md](docs/CODE_WALKTHROUGH.md) | **Code tour** — every major directory/file, algorithms (AVC merge, policy diff, blast radius, soak gates) |
| [docs/SELINUX_BASICS.md](docs/SELINUX_BASICS.md) | **New to SELinux** — labels, `.te`/`.fc`/`.pp`, `restorecon`, `semanage` commands with example output |
| [docs/TESTING.md](docs/TESTING.md) | **All test cases** — six HTTP endpoints, `smoke_test.py`, CI jobs, soak/enforce gates |
| [ansible/README.md](ansible/README.md) | **Ansible playbooks** — canary, enforce, rollback task order and variables |
| [docs/DEMO_GUIDE.md](docs/DEMO_GUIDE.md) | Workshop demo for newbies — 10 acts, example output, observer vs presenter paths |
| [docs/examples/](docs/examples/) | **Curated PR samples** — `pr_summary.example.md` and `pr_body.example.md` for Act 4 when staging is unavailable |
| [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) | Post-demo admin runbook — soak, canary hosts, enforce gates, deploy report JSON, incident card §12.5, pass/fail examples |
| [docs/SELINUX_BEST_PRACTICES.md](docs/SELINUX_BEST_PRACTICES.md) | **Policy-as-Code principles** — refpolicy interfaces, labeling, CI gates, soak/enforce anti-patterns (admin + reviewer checklist) |
