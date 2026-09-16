# Offline demo fixtures (`--skip-ai`)

Used by `scripts/lib/stage_skip_ai_fixture.sh` when running `demo_present.sh --skip-ai` without `OPENAI_API_KEY`. For live generation without an API key, prefer the default **deterministic** engine ([`DETERMINISTIC_POLICY.md`](../../../developers/DETERMINISTIC_POLICY.md)) instead of `--skip-ai`.

| Path | Role |
|------|------|
| `baseline/` | Older module snapshot (**1.1.0**) — shown as “before” in Act 3 diff |
| `generated/` | Expected AI output — must match `selinux/myapp.{te,fc}` for deploy/enforce |
| `avc.log` | Recorded audit lines fed to Act 4 PR assembly |

Refresh `generated/` after bumping `selinux/`:

```bash
bash scripts/refresh_skip_ai_fixture.sh
```
