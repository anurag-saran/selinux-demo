"""
Boolean triage: curated YAML overrides first, then sesearch on loaded policy.

Offline fixtures may supply only overrides; policy query requires setools + policy.kern.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import yaml

from avc_preprocess import AccessNeed

DEFAULT_HINTS_PATH = Path(__file__).resolve().parent.parent / "config" / "boolean_hints.yml"

DEFAULT_POLICY_KERN = Path("/var/lib/selinux/targeted/active/policy.kern")
SYSFS_POLICY = Path("/sys/fs/selinux/policy")

SEMANAGE_BOOL_RE = re.compile(r"^(\S+)\s+\([^)]+\)\s+(.*)$")


@dataclass(frozen=True)
class BooleanMatch:
    name: str
    description: str
    site_note: str = ""


@dataclass(frozen=True)
class BooleanLookupResult:
    """Policy query only: matched | none | unavailable."""

    status: str
    matches: tuple[BooleanMatch, ...] = ()
    detail: str = ""


@dataclass(frozen=True)
class BooleanTriageResult:
    """Combined curated + policy query."""

    status: str
    matches: tuple[BooleanMatch, ...] = ()
    detail: str = ""
    policy_query_status: str = ""


def load_boolean_hints(path: Path | None = None) -> list[dict]:
    hint_path = path or DEFAULT_HINTS_PATH
    if not hint_path.is_file():
        return []
    data = yaml.safe_load(hint_path.read_text(encoding="utf-8")) or {}
    hints = data.get("hints")
    return hints if isinstance(hints, list) else []


def expand_match_token(value: str, manifest: dict, need: AccessNeed) -> str:
    app = str(manifest.get("app_name") or "myapp")
    domain = str(manifest.get("domain") or f"{app}_t")
    out = value.replace("{app_name}", app)
    out = out.replace("{domain}", domain)
    out = out.replace("{app_domain}", domain)
    out = out.replace("{src_type}", need.src_type)
    return out


def match_curated_hints(
    need: AccessNeed,
    hints: list[dict],
    manifest: dict,
) -> list[tuple[str, str]]:
    """Return sorted (boolean_name, site_note) from YAML overrides."""
    hits: list[tuple[str, str]] = []
    for row in hints:
        if not isinstance(row, dict):
            continue
        match = row.get("match")
        if not isinstance(match, dict):
            continue
        src_pattern = match.get("src_type")
        if src_pattern is not None and str(src_pattern).strip():
            resolved = expand_match_token(str(src_pattern).strip(), manifest, need)
            if resolved != need.src_type:
                continue
        tgt_type = match.get("tgt_type")
        if tgt_type and tgt_type != need.tgt_type:
            continue
        tclass = match.get("tclass")
        if tclass and tclass != need.tclass:
            continue
        required = match.get("perms") or []
        if required:
            required_set = frozenset(str(p) for p in required)
            if not required_set <= need.perms:
                continue
        boolean = str(row.get("boolean") or "").strip()
        if not boolean:
            continue
        site_note = str(row.get("note") or "").strip()
        hits.append((boolean, site_note))
    hits.sort(key=lambda x: x[0])
    return hits


def resolve_policy_kern(explicit: Path | None = None) -> Path | None:
    if explicit and explicit.is_file():
        return explicit
    env = os.environ.get("POLICY_KERN", "").strip()
    if env:
        p = Path(env)
        if p.is_file():
            return p
    for candidate in (DEFAULT_POLICY_KERN, SYSFS_POLICY):
        if candidate.is_file():
            return candidate
    return None


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def _rpm_query(pkg: str) -> str:
    try:
        proc = _run(["rpm", "-q", pkg])
        if proc.returncode == 0:
            return proc.stdout.strip()
    except OSError:
        pass
    return "unknown"


def query_policy_identity(policy_kern: Path | None = None) -> dict[str, str]:
    """Record installed policy identity for reproducible boolean triage."""
    kern = resolve_policy_kern(policy_kern)
    nvr = _rpm_query("selinux-policy-targeted")
    if nvr == "unknown":
        nvr = _rpm_query("selinux-policy")
    version = "unknown"
    if kern and shutil.which("seinfo"):
        proc = _run(["seinfo", "--policy", str(kern)])
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                if "Policy version" in line or "policy version" in line.lower():
                    version = line.split(":", 1)[-1].strip() or version
                    break
    if version == "unknown" and shutil.which("sestatus"):
        proc = _run(["sestatus"])
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                if "policy version" in line.lower():
                    version = line.split(":", 1)[-1].strip() or version
                    break
    return {
        "selinux_policy_rpm": nvr,
        "policy_version": version,
        "policy_kern": str(kern) if kern else "",
    }


def list_booleans_with_descriptions() -> tuple[list[BooleanMatch], str]:
    proc = _run(["semanage", "boolean", "-l"])
    if proc.returncode == 0 and proc.stdout.strip():
        out: list[BooleanMatch] = []
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line or line.startswith("SELinux"):
                continue
            m = SEMANAGE_BOOL_RE.match(line)
            if m:
                out.append(BooleanMatch(m.group(1), m.group(2).strip()))
            else:
                name = line.split()[0]
                if name:
                    out.append(BooleanMatch(name, ""))
        if out:
            return sorted(out, key=lambda b: b.name), ""
    detail = (proc.stderr or proc.stdout or "semanage boolean -l failed").strip()
    proc2 = _run(["seinfo", "-b"])
    if proc2.returncode == 0 and proc2.stdout.strip():
        names = sorted({ln.strip() for ln in proc2.stdout.splitlines() if ln.strip()})
        return [BooleanMatch(n, "") for n in names], ""
    if detail:
        return [], detail
    return [], (proc2.stderr or "seinfo -b failed").strip()


def sesearch_bool_permits(
    policy_kern: Path,
    boolean_name: str,
    src: str,
    tgt: str,
    tclass: str,
    perm: str,
) -> bool:
    cmd = [
        "sesearch",
        "--allow",
        "--bool",
        boolean_name,
        "-s",
        src,
        "-t",
        tgt,
        "-c",
        tclass,
        "-p",
        perm,
        str(policy_kern),
    ]
    proc = _run(cmd)
    if proc.returncode not in (0, 1):
        raise OSError((proc.stderr or proc.stdout or f"sesearch failed: {cmd}").strip())
    if proc.stderr.strip():
        raise OSError(proc.stderr.strip())
    return bool(proc.stdout.strip())


def boolean_permits_need(
    policy_kern: Path,
    boolean_name: str,
    need: AccessNeed,
) -> bool:
    for perm in sorted(need.perms):
        if not sesearch_bool_permits(
            policy_kern,
            boolean_name,
            need.src_type,
            need.tgt_type,
            need.tclass,
            perm,
        ):
            return False
    return True


def lookup_booleans_for_need(
    need: AccessNeed,
    *,
    policy_kern: Path | None = None,
) -> BooleanLookupResult:
    kern = resolve_policy_kern(policy_kern)
    if kern is None:
        return BooleanLookupResult(
            status="unavailable",
            detail="No readable SELinux policy (set POLICY_KERN or install targeted policy).",
        )
    if not shutil.which("sesearch"):
        return BooleanLookupResult(
            status="unavailable",
            detail="sesearch not installed (setools-console).",
        )
    booleans, list_err = list_booleans_with_descriptions()
    if not booleans:
        return BooleanLookupResult(
            status="unavailable",
            detail=list_err or "Could not enumerate policy booleans.",
        )
    matched: list[BooleanMatch] = []
    try:
        for row in booleans:
            if boolean_permits_need(kern, row.name, need):
                matched.append(row)
    except OSError as exc:
        return BooleanLookupResult(status="unavailable", detail=str(exc))
    if not matched:
        return BooleanLookupResult(status="none")
    return BooleanLookupResult(status="matched", matches=tuple(matched))


def resolve_booleans_for_need(
    need: AccessNeed,
    hints: list[dict],
    manifest: dict,
    *,
    policy_kern: Path | None = None,
    policy_lookup: Callable[..., BooleanLookupResult] | None = None,
) -> BooleanTriageResult:
    """
    Curated YAML first, then policy sesearch. Union of matches, sorted by name.
    Unavailable policy query with no curated match → status unavailable.
    """
    lookup_fn = policy_lookup or lookup_booleans_for_need
    curated = match_curated_hints(need, hints, manifest)
    merged: dict[str, BooleanMatch] = {}
    for name, site_note in curated:
        merged[name] = BooleanMatch(name, "", site_note=site_note)

    policy_result = lookup_fn(need, policy_kern=policy_kern)

    if policy_result.status == "matched":
        for m in policy_result.matches:
            if m.name in merged:
                desc = m.description or merged[m.name].description
                merged[m.name] = BooleanMatch(
                    m.name,
                    desc,
                    site_note=merged[m.name].site_note,
                )
            else:
                merged[m.name] = BooleanMatch(m.name, m.description)

    if merged:
        ordered = tuple(sorted(merged.values(), key=lambda b: b.name))
        return BooleanTriageResult(
            status="matched",
            matches=ordered,
            policy_query_status=policy_result.status,
            detail=policy_result.detail if policy_result.status == "unavailable" else "",
        )

    if policy_result.status == "unavailable":
        return BooleanTriageResult(
            status="unavailable",
            detail=policy_result.detail,
            policy_query_status="unavailable",
        )
    return BooleanTriageResult(status="none", policy_query_status=policy_result.status)


def render_boolean_finding(
    matches: tuple[BooleanMatch, ...],
) -> tuple[str, str, str]:
    names = [m.name for m in matches]
    commands = [f"setsebool -P {n} on" for n in names]
    rendered = commands[0] if len(commands) == 1 else "\n".join(commands)
    desc_lines = []
    for m in matches:
        parts = []
        if m.description:
            parts.append(m.description)
        if m.site_note:
            parts.append(f"Site note: {m.site_note}")
        line = f"- {m.name}"
        if parts:
            line += ": " + " ".join(parts)
        desc_lines.append(line)
    if len(matches) == 1:
        m = matches[0]
        body = m.description or "Review semanage boolean -l before enabling."
        if m.site_note:
            body = f"{body} Site note: {m.site_note}"
        note = (
            "Host-wide boolean decision (not applied by the policy RPM). "
            f"{body}"
        )
    else:
        note = (
            "Multiple booleans would permit this access; choose deliberately "
            "(host-wide, not in module RPM):\n" + "\n".join(desc_lines)
        )
    return rendered, note, ",".join(names)


# Backward-compatible alias for older imports
BOOLEAN_UNAVAILABLE = object()
