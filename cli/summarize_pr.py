#!/usr/bin/env python3
"""
summarize_pr.py — Optional LLM polish for policy_out/pr_summary.md (narrative only).

Policy (.te/.fc) is always produced by deterministic_gen.py. This tool rewrites the
four admin-facing sections; deterministic tail (host actions + classification table)
is appended verbatim from the template.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass

from pr_summary_common import (  # noqa: E402
    PR_SUMMARY_REQUIRED_HEADINGS,
    merge_pr_summary,
    split_pr_summary_sections,
    validate_narrative_section,
    validate_pr_summary,
)

DEFAULT_MODEL = "gpt-4o-mini"

SUMMARY_SYSTEM_PROMPT = """You are a security communications assistant for SELinux policy pull requests.

You write plain-English markdown for RHEL admins. You do NOT write SELinux policy.

OUTPUT: Return ONLY markdown (no JSON, no code fences) containing EXACTLY these four sections
in this order, each starting with the heading line shown:

### Network Bindings
### File System Access
### Process Execution
### Explicit Denials Maintained

RULES:
- Use bullet lists under each heading.
- Describe only facts present in the user-provided evidence (findings, stats, template).
- Do NOT invent ports, paths, allows, or rules not supported by the evidence.
- Do NOT include allow/type/policy_module lines or a classification table.
- Keep ### Explicit Denials Maintained focused on CI guardrails (no wildcards, forbidden types).
- Be concise (2–6 bullets per section where applicable).
"""


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def load_findings_summary(path: Path) -> str:
    if not path.is_file():
        return "(no findings.json)"
    data = json.loads(path.read_text(encoding="utf-8"))
    rows = data.get("findings") or []
    if not rows:
        return "No classified findings in findings.json."
    lines = ["Classification summary (from deterministic engine):"]
    for row in rows[:40]:
        need = row.get("need") or {}
        src = need.get("src_type", "?")
        tgt = need.get("tgt_type", "?")
        tclass = need.get("tclass", "?")
        verdict = row.get("verdict", "?")
        note = (row.get("note") or "")[:160]
        lines.append(f"- [{verdict}] {src} → {tgt}:{tclass} — {note}")
    if len(rows) > 40:
        lines.append(f"- … and {len(rows) - 40} more")
    return "\n".join(lines)


def call_llm_narrative(user_prompt: str, model: str) -> str:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        eprint("Error: OPENAI_API_KEY not set.")
        sys.exit(1)

    try:
        from openai import OpenAI
    except ImportError as exc:
        eprint("Install dependencies: pip3 install -r cli/requirements.txt")
        raise SystemExit(1) from exc

    base_url = os.environ.get("OPENAI_BASE_URL") or os.environ.get("OPENAI_API_BASE")
    timeout = float(os.environ.get("OPENAI_TIMEOUT", "120"))
    client_kwargs: dict = {"api_key": api_key, "timeout": timeout}
    if base_url:
        client_kwargs["base_url"] = base_url.rstrip("/")

    client = OpenAI(**client_kwargs)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SUMMARY_SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0.2,
        max_tokens=2048,
    )
    content = (response.choices[0].message.content or "").strip()
    if content.startswith("```"):
        content = re.sub(r"^```(?:markdown)?\s*", "", content)
        content = re.sub(r"\s*```$", "", content)
    return content.strip()


def build_user_prompt(
    *,
    app_name: str,
    template: str,
    findings_text: str,
    avc_summary: str,
) -> str:
    narrative, _tail = split_pr_summary_sections(template)
    headings = "\n".join(PR_SUMMARY_REQUIRED_HEADINGS)
    return f"""App module: {app_name}

Rewrite the admin narrative for a pull request using the evidence below.
Use exactly these headings (markdown):
{headings}

Current deterministic narrative (for facts — improve clarity, do not drop important items):
---
{narrative or '(empty)'}
---

{findings_text}

AVC preprocess summary:
---
{avc_summary.strip() or '(no avc_summary.txt)'}
---
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Optional LLM polish for pr_summary.md (narrative sections only)."
    )
    parser.add_argument(
        "--template",
        type=Path,
        default=Path("policy_out/pr_summary.md"),
        help="Deterministic pr_summary.md (tail sections preserved)",
    )
    parser.add_argument("--findings", type=Path, default=Path("policy_out/findings.json"))
    parser.add_argument("--avc-summary", type=Path, default=Path("policy_out/avc_summary.txt"))
    parser.add_argument("--out", type=Path, default=Path("policy_out/pr_summary.md"))
    parser.add_argument("--app-name", default=os.environ.get("POLICY_APP", "myapp"))
    parser.add_argument(
        "--model",
        default=os.environ.get("OPENAI_API_MODEL", DEFAULT_MODEL),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print merged summary to stdout; do not write --out",
    )
    args = parser.parse_args()

    if not args.template.is_file():
        eprint(f"Missing template: {args.template} (run deterministic_gen first)")
        return 1

    template = args.template.read_text(encoding="utf-8")
    _narrative, tail = split_pr_summary_sections(template)
    if not tail:
        eprint(
            "Warning: template has no deterministic tail marker; "
            "classification table may be omitted after LLM polish."
        )

    avc_summary = ""
    if args.avc_summary.is_file():
        avc_summary = args.avc_summary.read_text(encoding="utf-8", errors="replace")

    user_prompt = build_user_prompt(
        app_name=args.app_name,
        template=template,
        findings_text=load_findings_summary(args.findings),
        avc_summary=avc_summary,
    )

    print(f"Calling model '{args.model}' for pr_summary narrative only...")
    narrative = call_llm_narrative(user_prompt, args.model)
    validate_narrative_section(narrative)
    merged = merge_pr_summary(narrative, tail)
    validate_pr_summary(merged)

    if args.dry_run:
        print(merged)
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(merged, encoding="utf-8")
    print(f"Wrote {args.out} (LLM narrative + deterministic tail)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
