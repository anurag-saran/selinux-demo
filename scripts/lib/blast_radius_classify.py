#!/usr/bin/env python3
"""
Classify added SELinux rules (sesearch line format) into soak tiers.

Parses one rule per line from comm-diff output — not sediff prose.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from typing import Iterable

BASE_TARGET_TYPES = frozenset(
    {
        "var_t",
        "etc_t",
        "usr_t",
        "bin_t",
        "shadow_t",
        "unlabeled_t",
        "tmp_t",
        "proc_t",
        "sysfs_t",
    }
)

TIER_RANK = {"low": 0, "medium": 1, "high": 2}
TIER_DAYS = {"low": 1, "medium": 3, "high": 7}

ALLOW_RE = re.compile(
    r"^allow\s+(\S+)\s+(\S+):(\S+)\s+(\{[^}]+\}|\S+)\s*;",
    re.IGNORECASE,
)

TYPE_RULE_PREFIXES = (
    "type_transition",
    "type_change",
    "type_member",
    "role_transition",
    "range_transition",
)


@dataclass
class RuleVerdict:
    tier: str
    reason: str
    line: str


def tier_for_type_rule(line: str) -> RuleVerdict:
    return RuleVerdict(
        tier="high",
        reason="Entrypoint or domain transition change detected",
        line=line,
    )


def tier_for_allow(source: str, target: str, tclass: str, perms: str, line: str) -> RuleVerdict:
    perms_l = perms.lower()
    if "entrypoint" in perms_l:
        return RuleVerdict(
            tier="high",
            reason="Entrypoint permission added",
            line=line,
        )
    if target in BASE_TARGET_TYPES:
        return RuleVerdict(
            tier="high",
            reason="Direct allow on base policy type detected",
            line=line,
        )
    if target.startswith("myapp_"):
        return RuleVerdict(
            tier="low",
            reason="Only module-private types changed",
            line=line,
        )
    return RuleVerdict(
        tier="medium",
        reason="Refpolicy interface or non-module type expansion detected",
        line=line,
    )


def classify_line(line: str) -> RuleVerdict | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    lower = stripped.lower()
    for prefix in TYPE_RULE_PREFIXES:
        if lower.startswith(prefix):
            return tier_for_type_rule(stripped)
    m = ALLOW_RE.match(stripped)
    if not m:
        return RuleVerdict(
            tier="high",
            reason=f"Unparseable added rule (conservative soak): {stripped[:120]}",
            line=stripped,
        )
    source, target, tclass, perms = m.groups()
    return tier_for_allow(source, target, tclass, perms, stripped)


def classify_added_rules(lines: Iterable[str]) -> dict:
    verdicts: list[RuleVerdict] = []
    for line in lines:
        v = classify_line(line)
        if v is not None:
            verdicts.append(v)

    if not verdicts:
        return {
            "tier": "high",
            "min_days": 7,
            "reason": "No added rules parsed — conservative soak",
            "matched_rules": [],
            "fail_closed": True,
        }

    best = max(verdicts, key=lambda v: TIER_RANK[v.tier])
    fail_closed = any(v.reason.startswith("Unparseable added rule") for v in verdicts)
    return {
        "tier": best.tier,
        "min_days": TIER_DAYS[best.tier],
        "reason": best.reason,
        "matched_rules": [v.line for v in verdicts if v.tier == best.tier][:20],
        "fail_closed": fail_closed,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: blast_radius_classify.py ADDED_RULES.txt", file=sys.stderr)
        return 2
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    lines = text.splitlines()
    result = classify_added_rules(lines)
    excerpt = text[:2000]
    print(
        json.dumps(
            {
                "tier": result["tier"],
                "min_days": result["min_days"],
                "reason": result["reason"],
                "sediff_excerpt": excerpt,
                "fail_closed": result.get("fail_closed", False),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
