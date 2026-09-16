# Sample outputs

Static copies of CLI output for reviews when you cannot run staging or `assemble_pr_body.sh` live.

**Where to regenerate live output:** SELinux **Linux host** or Mac with **`dev_generate_policy.sh --use-vm`** at **repo root**. Offline-only: use [`fixtures/skip_ai/`](fixtures/skip_ai/) — no VM required.

| File | Live equivalent | Use in demo |
|------|-----------------|-------------|
| [`pr_summary.example.md`](pr_summary.example.md) | `policy_out/pr_summary.md` | Act 4 — plain-English admin summary |
| [`pr_body.example.md`](pr_body.example.md) | `policy_out/pr_body.md` | Act 4 — full GitHub PR body + checklist |

Live policy in `selinux/` is **v1.1.3**. [`pr_body.example.md`](pr_body.example.md) / [`pr_summary.example.md`](pr_summary.example.md) are **frozen samples** (v1.1.2). `fixtures/skip_ai/generated/` is kept in sync with `selinux/` via `refresh_skip_ai_fixture.sh`. Regenerate live `policy_out/` on a SELinux host with:

| | |
|--|--|
| **Where** | **Repo root** on native Linux (`sudo` staging) or Mac with `--use-vm` |
| **Why** | Refreshes `policy_out/pr_summary.md` and `pr_body.md` to match current `selinux/` |

```bash
# Default engine is deterministic (no OPENAI_API_KEY required for generation)
bash scripts/dev_generate_policy.sh --use-vm --apply
bash scripts/assemble_pr_body.sh
# → policy_out/pr_summary.md and policy_out/pr_body.md
```

Deterministic verdict fixtures: [`fixtures/deterministic/`](fixtures/deterministic/). Compile image: [`COMPILE_IMAGE.md`](../admin/COMPILE_IMAGE.md).

Do not edit `policy_out/` in Git — `.te`, `.fc`, and `policy_version.txt` there are local build output (gitignored). Offline demos use [`fixtures/skip_ai/`](fixtures/skip_ai/) via `--skip-ai`; refresh with `bash scripts/refresh_skip_ai_fixture.sh` when `selinux/` bumps.
