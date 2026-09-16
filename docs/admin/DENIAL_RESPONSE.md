# When a file or port is denied after ship

Host stays **Enforcing**. Only the app domain may be permissive (canary soak). Do not live-patch prod.

## Soak still running (domain permissive)

`soak_monitor.yml` fails on **net-new**. Do **not** run Enforce.

1. Copy `/var/lib/<app>/selinux_soak_last_fail.json` and `selinux_soak_last_fail.avc` off the host.
2. On **rhel-dev**: `bash scripts/dev_generate_policy.sh` (deterministic generator).
3. PR → CI → CODEOWNERS → signed RPM.
4. AAP **SELinux – Release canary** (recanary). Soak clock resets.

## Already enforced (app is down)

AAP **SELinux – Rollback** (`emergency_rollback.yml`): domain back to permissive, optional RPM downgrade. Then the same PR path. Never `setenforce 0`.

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
