# 303 — Denial response

Host stays **Enforcing**. Only the app domain may be permissive (canary soak). Do not live-patch prod.

## Soak still running (domain permissive)

`soak_monitor.yml` fails on **net-new**. Do **not** run Enforce.

1. Copy `/var/lib/<app>/selinux_soak_last_fail.json` and `selinux_soak_last_fail.avc` off the host.
2. On **rhel-qa**: `bash scripts/dev_generate_policy.sh` (deterministic generator). It refuses to run if vendor/base policy already covers the app (JWS, EAP, httpd, …). If the situation is `loaded` or `base_policy`, re-run with `--tune-report` for host commands (`semanage fcontext`, `setsebool`, `semanage port`) — that does not write a module. `--force "reason"` only if the app genuinely differs (reason is recorded on the PR). Customer: generate in the **app** repo checkout on QA, then PR that repo.
3. PR → CI (`forbidden-patterns`, `version-consistency`) → CODEOWNERS → signed RPM.
4. AAP **SELinux – Release canary** (recanary). Soak clock resets.

## Already enforced (app is down)

AAP **SELinux – Rollback** (`emergency_rollback.yml`): domain back to permissive, optional RPM downgrade. Then the same PR path. Never `setenforce 0`. The two-host talk ([203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md)) shows this after a **clean** soak and talk-only enforce, then shopapi `/feature-spool` 500 on **:8091**.

## What to change in git

| Denial | Ship this | Not this |
|--------|-----------|----------|
| File / path | `.fc` + `restorecon` (`fc_fix` / `fc_drift`) | `semanage fcontext` on the box as the control plane |
| Port bind | `selinux_ports` in the manifest; canary `seport` | `semanage port -a` on the box as the control plane |
| Host boolean | admin `setsebool` (not in the RPM) | a raw `.te` allow that duplicates a boolean |
| New permission | `.te` allow; forbidden-patterns still apply | `audit2allow` \| `semodule -i` on prod |

## Do not

- `setenforce 0` (whole-OS Permissive)
- `audit2allow` or `semodule -i` on production
- `generate_emergency_patch.yml` against production hosts — controller + git checkout only; it writes `policy_out/` for a PR

AAP templates: [`ansible/aap/`](../../ansible/aap/).
