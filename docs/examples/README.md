# Demo examples (curated samples)

Static copies of CLI output for **workshop presentations** when you cannot run staging or `assemble_pr_body.sh` live.

| File | Live equivalent | Use in demo |
|------|-----------------|-------------|
| [`pr_summary.example.md`](pr_summary.example.md) | `policy_out/pr_summary.md` | Act 4 — plain-English admin summary |
| [`pr_body.example.md`](pr_body.example.md) | `policy_out/pr_body.md` | Act 4 — full GitHub PR body + checklist |

These reflect **policy v1.1.2** (FHS paths, dedicated port types, domain-context gates, merge-base access delta in PR body). Regenerate fresh output on a SELinux host with:

```bash
# Default engine is deterministic (no OPENAI_API_KEY required for generation)
bash scripts/dev_generate_policy.sh --use-vm --apply
bash scripts/assemble_pr_body.sh
# → policy_out/pr_summary.md and policy_out/pr_body.md
```

Deterministic verdict fixtures: [`fixtures/deterministic/`](fixtures/deterministic/). Compile image (CentOS Stream 9): [`../DOCKER_HUB_COMPILE_IMAGE.md`](../DOCKER_HUB_COMPILE_IMAGE.md).

Do not edit `policy_out/` in Git — `.te`, `.fc`, and `policy_version.txt` there are local build output (gitignored). Offline demos use [`fixtures/skip_ai/`](fixtures/skip_ai/) via `--skip-ai`; refresh with `bash scripts/refresh_skip_ai_fixture.sh` when `selinux/` bumps.
