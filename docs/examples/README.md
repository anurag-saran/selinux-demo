# Demo examples (curated samples)

Static copies of CLI output for **workshop presentations** when you cannot run staging or `assemble_pr_body.sh` live.

| File | Live equivalent | Use in demo |
|------|-----------------|-------------|
| [`pr_summary.example.md`](pr_summary.example.md) | `policy_out/pr_summary.md` | Act 4 — plain-English admin summary |
| [`pr_body.example.md`](pr_body.example.md) | `policy_out/pr_body.md` | Act 4 — full GitHub PR body + checklist |

These reflect **policy v1.1.1** (FHS paths, dedicated port types, domain-context gates). Regenerate fresh output on a SELinux host with:

```bash
bash scripts/dev_generate_policy.sh --use-vm --apply
bash scripts/assemble_pr_body.sh
# → policy_out/pr_summary.md and policy_out/pr_body.md
```

Do not edit `policy_out/` in Git — it is for local/generated artifacts. Update these examples when the PR template or policy baseline changes materially.
