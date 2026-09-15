#!/usr/bin/env python3
"""
deterministic_gen.py — Offline, reproducible AVC → policy updates (house rules + optional sepolgen).

Requires PyYAML. Optional RHEL sepolgen: policycoreutils-devel + sepolgen-ifgen.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import yaml  # noqa: E402
from avc_preprocess import AccessNeed, merge_avc_entries, parse_existing_allows, subtract_covered  # noqa: E402
from boolean_hints import load_boolean_hints, match_boolean_hint  # noqa: E402
from policy_rules import (  # noqa: E402
    FORBIDDEN_TARGET_TYPES,
    GENERIC_FILE_TYPES,
    GENERIC_PORT_TYPES,
    PATTERN_MACROS,
    VERDICT_BASELINE,
    VERDICT_DIRECT,
    VERDICT_FC,
    VERDICT_FC_DRIFT,
    VERDICT_FORBIDDEN,
    VERDICT_INTERFACE,
    VERDICT_PORT,
    VERDICT_BOOLEAN,
    VERDICT_TOOLCHAIN,
)
from selinux_gen import (  # noqa: E402
    domain_for_app,
    format_version,
    parse_avc_line,
    parse_version,
    read_policy_version,
    SELINUX_DIR,
)

from fc_labeling import (  # noqa: E402
    existing_fc_covers,
    filter_fc_fix_lines,
)

PATH_FIELD_RE = re.compile(r'path="([^"]+)"')
POLICY_MODULE_RE = re.compile(r"policy_module\(\s*(\w+)\s*,\s*([\d.]+)\s*\)")

SEPOLGEN_UNAVAILABLE = object()

SEPOLGEN_WARN_BANNER = """\
================================================================================
WARNING: SEPOLGEN INTERFACE MATCHING IS NOT AVAILABLE
================================================================================
{detail}

Impact:
  - Base-type AVCs (e.g. var_log_t, port types) will NOT map to refpolicy macros.
  - This generator REFUSES raw allows on base types (exit 1) unless you pass
    --allow-degraded (audit2allow-grade output; not recommended).

Fix on RHEL / CentOS Stream (with SELinux):
  sudo dnf install -y policycoreutils-devel setools-console
  sudo sepolgen-ifgen

Do not confuse with "no interface matched" — that message only appears when
sepolgen-ifgen data is present but your specific denial has no macro.
================================================================================
"""


def sepolgen_diagnose() -> dict[str, str]:
    """Return status: available | missing_python_modules | missing_ifgen | unreadable_ifgen."""
    try:
        import sepolgen.defaults as defaults
    except ImportError:
        return {
            "status": "missing_python_modules",
            "detail": (
                "Python sepolgen is not installed. "
                "Install policycoreutils-devel (provides sepolgen modules)."
            ),
            "if_path": "",
        }

    try:
        if_path = defaults.interface_info()
    except (OSError, AttributeError) as exc:
        return {
            "status": "missing_ifgen",
            "detail": f"Cannot resolve sepolgen interface_info path: {exc}. Run: sudo sepolgen-ifgen",
            "if_path": "",
        }

    try:
        with open(if_path, encoding="utf-8") as fd:
            if not fd.read(1):
                return {
                    "status": "unreadable_ifgen",
                    "detail": f"interface_info at {if_path} is empty. Re-run: sudo sepolgen-ifgen",
                    "if_path": str(if_path),
                }
    except OSError as exc:
        return {
            "status": "missing_ifgen",
            "detail": (
                f"interface_info missing at {if_path}: {exc}. "
                "Run: sudo sepolgen-ifgen (after policycoreutils-devel is installed)."
            ),
            "if_path": str(if_path),
        }

    return {
        "status": "available",
        "detail": "",
        "if_path": str(if_path),
    }


def sepolgen_toolchain_available() -> bool:
    return sepolgen_diagnose()["status"] == "available"


def emit_sepolgen_warning(diagnose: dict[str, str] | None = None) -> None:
    diagnose = diagnose or sepolgen_diagnose()
    if diagnose["status"] == "available":
        return
    print(SEPOLGEN_WARN_BANNER.format(detail=diagnose["detail"]), file=sys.stderr)


def emit_degraded_warning(findings: list[Finding]) -> None:
    degraded = [f for f in findings if f.engine == "degraded"]
    if not degraded:
        return
    print(
        "\n"
        "================================================================================\n"
        "WARNING: --allow-degraded IS ON — EMITTING RAW ALLOWS WITHOUT SEPOLGEN\n"
        "================================================================================\n"
        f"{len(degraded)} rule(s) use engine=degraded in findings.json. "
        "Admin review must treat these as audit2allow output, not interface-backed policy.\n"
        "Install sepolgen-ifgen and regenerate without --allow-degraded when possible.\n"
        "================================================================================\n",
        file=sys.stderr,
    )


@dataclass(frozen=True)
class Finding:
    need: AccessNeed
    verdict: str
    rendered: str
    note: str
    paths: tuple[str, ...] = ()
    engine: str = "house_rules"
    boolean: str = ""


def boolean_finding(
    need: AccessNeed,
    paths: tuple[str, ...],
    boolean_name: str,
    rendered: str,
    note: str,
) -> Finding:
    return Finding(
        need,
        VERDICT_BOOLEAN,
        rendered,
        note,
        paths,
        engine="house_rules",
        boolean=boolean_name,
    )


def load_manifest(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def domains_from_manifest(manifest: dict) -> set[str]:
    out = {manifest["domain"]}
    for svc in manifest.get("services", {}).values():
        if isinstance(svc, dict) and svc.get("domain"):
            out.add(str(svc["domain"]))
    return out


def private_types(manifest: dict) -> set[str]:
    app = manifest["app_name"]
    return {
        f"{app}_t",
        f"{app}_backend_t",
        f"{app}_exec_t",
        f"{app}_lib_t",
        f"{app}_var_lib_t",
        f"{app}_var_run_t",
        f"{app}_log_t",
        f"{app}_script_exec_t",
        f"{app}_backend_exec_t",
        f"{app}_port_t",
        f"{app}_backend_port_t",
    }


def suggest_fc_type(path: str, manifest: dict) -> str | None:
    app = manifest["app_name"]
    paths = manifest.get("paths", {})
    rules = (
        ("log_dir", "log_t"),
        ("var_dir", "var_lib_t"),
        ("runtime_dir", "var_run_t"),
        ("install_root", "exec_t"),
    )
    for key, suffix in rules:
        root = paths.get(key)
        if not root:
            continue
        base = root.rstrip("/")
        if path == base or path.startswith(base + "/"):
            return f"{app}_{suffix}"
    return None


def collapse_to_pattern(perms: frozenset[str]) -> str | None:
    perm_set = set(perms)
    for required, macro in PATTERN_MACROS:
        if required <= perm_set:
            return macro
    return None


def parse_avc_file(avc_path: Path, domains: set[str]) -> tuple[list, dict[tuple[str, str, str], set[str]]]:
    from selinux_gen import AvcEntry

    entries: list[AvcEntry] = []
    paths: dict[tuple[str, str, str], set[str]] = {}
    for line in avc_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "type=AVC" not in line:
            continue
        entry = parse_avc_line(line)
        src = entry.scontext.split(":")[2] if entry.scontext.count(":") >= 2 else ""
        tgt = entry.tcontext.split(":")[2] if entry.tcontext.count(":") >= 2 else ""
        if src not in domains:
            continue
        entries.append(entry)
        pm = PATH_FIELD_RE.search(line)
        if pm and tgt and entry.tclass:
            key = (src, tgt, entry.tclass)
            paths.setdefault(key, set()).add(pm.group(1))
    return entries, paths


def try_sepolgen_interface(
    src: str, tgt: str, tclass: str, perms: frozenset[str]
) -> tuple[str, str] | None | object:
    try:
        import sepolgen.access as access_mod
        import sepolgen.defaults as defaults
        import sepolgen.interfaces as interfaces
        import sepolgen.matching as matching
    except ImportError:
        return SEPOLGEN_UNAVAILABLE

    if_path = defaults.interface_info()
    try:
        with open(if_path, encoding="utf-8") as fd:
            ifset = interfaces.InterfaceSet()
            ifset.from_file(fd)
    except OSError:
        return SEPOLGEN_UNAVAILABLE

    try:
        av = access_mod.AccessVector([src, tgt, tclass, *sorted(perms)])
        matcher = matching.Match()
        candidates = matcher.search(ifset, av)
    except (AttributeError, TypeError, ValueError):
        return None
    if not candidates:
        return None
    best = sorted(candidates, key=lambda m: (-getattr(m, "dist", 0), m.interface.name))[0]
    return f"{best.interface.name}({src})", f"Matched refpolicy interface (distance {getattr(best, 'dist', '?')})."


def baseline_macro_covers(need: AccessNeed, te_text: str) -> bool:
    if need.tgt_type == "random_device_t" and need.perms <= frozenset({"read", "open", "getattr"}):
        if f"dev_read_urand({need.src_type})" in te_text:
            return True
    return False


def classify(
    need: AccessNeed,
    manifest: dict,
    paths: tuple[str, ...],
    existing_te: str,
    existing_fc: str,
    allow_degraded: bool,
    boolean_hints: list[dict],
) -> Finding:
    src, tgt, tclass = need.src_type, need.tgt_type, need.tclass
    perms = need.perms

    if baseline_macro_covers(need, existing_te):
        return Finding(
            need,
            VERDICT_BASELINE,
            "",
            "Covered by dev_read_urand in reviewed baseline block.",
            paths,
        )

    if tgt in FORBIDDEN_TARGET_TYPES:
        return Finding(
            need,
            VERDICT_FORBIDDEN,
            "",
            f"Refusing to grant {src} access to {tgt}. Denied paths: {', '.join(paths) or 'n/a'}",
            paths,
        )

    if tgt in GENERIC_FILE_TYPES:
        for path in paths:
            want = suggest_fc_type(path, manifest)
            if want:
                if existing_fc_covers(path, want, existing_fc):
                    return Finding(
                        need,
                        VERDICT_FC_DRIFT,
                        "",
                        f"{path} should already be {want} per the .fc, but is labeled "
                        f"{tgt} on disk. No policy change needed — run: "
                        f"restorecon -Rv {path}",
                        paths,
                        engine="house_rules",
                    )
                fc = f"{re.escape(path)}    gen_context(system_u:object_r:{want},s0)"
                return Finding(
                    need,
                    VERDICT_FC,
                    fc,
                    f"{path} is under an app-owned directory but labeled {tgt}. "
                    f"Fix labeling (.fc + restorecon), do not allow {tgt}.",
                    paths,
                )

    if tgt in GENERIC_PORT_TYPES and "name_bind" in perms:
        app = manifest["app_name"]
        ptype = f"{app}_port_t"
        return Finding(
            need,
            VERDICT_PORT,
            f"allow {src} {ptype}:{tclass} name_bind;",
            f"Use private port type {ptype} and semanage port — not {tgt}.",
            paths,
        )

    existing = parse_existing_allows(existing_te)
    uncovered = need.perms - existing.get(need.key, frozenset())
    if not uncovered:
        return Finding(
            need,
            VERDICT_BASELINE,
            "",
            "Already allowed in existing .te",
            paths,
        )

    if tgt in private_types(manifest):
        macro = collapse_to_pattern(need.perms)
        if macro and tclass in ("file", "dir"):
            rendered = f"{macro}({src}, {tgt}, {tgt})"
        else:
            perm_list = " ".join(sorted(need.perms))
            rendered = (
                f"allow {src} {tgt}:{tclass} {{ {perm_list} }};"
                if len(need.perms) > 1
                else f"allow {src} {tgt}:{tclass} {perm_list};"
            )
        return Finding(need, VERDICT_DIRECT, rendered, "Module-private type.", paths)

    def _boolean_or_none() -> Finding | None:
        hit = match_boolean_hint(need, boolean_hints)
        if not hit:
            return None
        name, rendered, note = hit
        return boolean_finding(need, paths, name, rendered, note)

    iface = try_sepolgen_interface(src, tgt, tclass, need.perms)
    if iface is SEPOLGEN_UNAVAILABLE:
        bool_f = _boolean_or_none()
        if bool_f:
            return bool_f
        if allow_degraded:
            perm_list = " ".join(sorted(need.perms))
            rendered = f"allow {src} {tgt}:{tclass} {{ {perm_list} }};"
            return Finding(
                need,
                VERDICT_DIRECT,
                rendered,
                "sepolgen unavailable — degraded raw allow on base type (--allow-degraded). "
                "Install policycoreutils-devel and run sepolgen-ifgen for interface matching.",
                paths,
                engine="degraded",
            )
        return Finding(
            need,
            VERDICT_TOOLCHAIN,
            "",
            "Refusing raw allow on base type without sepolgen. Install policycoreutils-devel, "
            "run sepolgen-ifgen, or pass --allow-degraded (records degraded rules in findings.json).",
            paths,
            engine="none",
        )
    if iface:
        rendered, note = iface
        return Finding(need, VERDICT_INTERFACE, rendered, note, paths, engine="sepolgen")

    bool_f = _boolean_or_none()
    if bool_f:
        return bool_f

    perm_list = " ".join(sorted(need.perms))
    rendered = f"allow {src} {tgt}:{tclass} {{ {perm_list} }};"
    return Finding(
        need,
        VERDICT_DIRECT,
        rendered,
        "sepolgen ran but no refpolicy interface matched this denial — manual review required "
        "(not the same as sepolgen missing).",
        paths,
        engine="house_rules",
    )


def render_fragment(findings: list[Finding], meta: dict) -> str:
    lines = [
        "########################################",
        "# Generated by deterministic_gen.py (reproducible for identical inputs).",
        f"# avc-sha256-prefix: {meta.get('avc_sha', 'unknown')}",
        f"# refpolicy-devel:     {meta.get('refpolicy', 'unknown')}",
        "########################################",
        "",
    ]
    for verdict, heading in (
        (VERDICT_INTERFACE, "# Refpolicy interfaces"),
        (VERDICT_DIRECT, "# Module-private / direct access"),
        (VERDICT_PORT, "# Private port binding"),
    ):
        rows = sorted({f.rendered for f in findings if f.verdict == verdict and f.rendered})
        if rows:
            lines.append(heading)
            lines.extend(rows)
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def merge_te(existing_te: str, app_name: str, new_version: str, fragment: str) -> str:
    te = existing_te
    if POLICY_MODULE_RE.search(te):
        te = POLICY_MODULE_RE.sub(f"policy_module({app_name}, {new_version})", te, count=1)
    if fragment.strip():
        te = te.rstrip() + "\n\n" + fragment
    return te if te.endswith("\n") else te + "\n"


def merge_fc(existing_fc: str, fc_lines: list[str], path_hints: dict[str, str] | None = None) -> str:
    kept, redundant = filter_fc_fix_lines(existing_fc, fc_lines, path_hints)
    if redundant and not kept:
        return existing_fc if existing_fc.endswith("\n") else existing_fc + "\n"
    if not kept:
        return existing_fc if existing_fc.endswith("\n") else existing_fc + "\n"
    block = "\n".join(sorted(set(kept))) + "\n"
    return existing_fc.rstrip() + "\n\n# deterministic_gen labeling fixes\n" + block


def write_pr_summary(findings: list[Finding], app_name: str) -> str:
    lines = [
        "### Network Bindings",
        "- See generated port / interface rules below",
        "",
        "### File System Access",
    ]
    for f in findings:
        if f.verdict in (VERDICT_DIRECT, VERDICT_FC, VERDICT_FC_DRIFT, VERDICT_INTERFACE, VERDICT_BOOLEAN):
            if f.verdict == VERDICT_BOOLEAN:
                lines.append(f"- Boolean `{f.boolean}`: `{f.rendered}` ({f.note[:100]})")
            else:
                lines.append(f"- {f.need.src_type} → {f.need.tgt_type}:{f.need.tclass} ({f.verdict})")
    lines.extend(
        [
            "",
            "### Process Execution",
            f"- {app_name}_exec_t entrypoints unchanged unless .fc fixes applied",
            "",
            "### Explicit Denials Maintained",
            "- No wildcard allows; forbidden targets refused at generation time",
            "",
            "### Classification audit (engine)",
            "| Verdict | Target | Engine | Note |",
            "| --- | --- | --- | --- |",
        ]
    )
    for f in findings:
        note = f.note.replace("|", "\\|")[:120]
        lines.append(
            f"| {f.verdict} | {f.need.tgt_type} | {f.engine} | {note} |"
        )
    lines.append("")
    return "\n".join(lines)


def write_findings_artifact(
    out_dir: Path,
    findings: list[Finding],
    sepolgen_info: dict[str, str],
    *,
    generation_blocked: bool,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    out_dir.joinpath("findings.json").write_text(
        json.dumps(
            {
                "sepolgen_status": sepolgen_info["status"],
                "sepolgen_detail": sepolgen_info.get("detail", ""),
                "generation_blocked": generation_blocked,
                "findings": [
                    {
                        "src": f.need.src_type,
                        "tgt": f.need.tgt_type,
                        "class": f.need.tclass,
                        "perms": sorted(f.need.perms),
                        "verdict": f.verdict,
                        "rendered": f.rendered,
                        "note": f.note,
                        "engine": f.engine,
                        **({"boolean": f.boolean} if f.boolean else {}),
                    }
                    for f in findings
                ],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def tool_versions() -> dict[str, str]:
    def rpm_q(pkg: str) -> str:
        try:
            return subprocess.run(
                ["rpm", "-q", pkg],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        except (FileNotFoundError, subprocess.CalledProcessError):
            return "unknown"

    return {"refpolicy": rpm_q("selinux-policy-devel")}


def run(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    app_name = manifest.get("app_name", args.app_name)
    domains = domains_from_manifest(manifest)
    existing_te = args.existing_te.read_text(encoding="utf-8")
    existing_fc = args.existing_fc.read_text(encoding="utf-8")

    sepolgen_info = sepolgen_diagnose()
    emit_sepolgen_warning(sepolgen_info)
    if args.allow_degraded and sepolgen_info["status"] != "available":
        print(
            "[WARN] --allow-degraded: base-type denials may become raw allows in output.\n",
            file=sys.stderr,
        )

    boolean_hints = load_boolean_hints(args.boolean_hints)

    entries, path_map = parse_avc_file(args.avc_log, domains)
    merged = merge_avc_entries(entries)
    net_new, _covered = subtract_covered(merged, parse_existing_allows(existing_te))

    findings: list[Finding] = []
    for need in net_new:
        paths = tuple(sorted(path_map.get(need.key, set())))
        findings.append(
            classify(
                need,
                manifest,
                paths,
                existing_te,
                existing_fc,
                args.allow_degraded,
                boolean_hints,
            )
        )

    meta = tool_versions()
    meta["avc_sha"] = hashlib.sha256(args.avc_log.read_bytes()).hexdigest()[:16]
    meta["sepolgen"] = sepolgen_info["status"]
    if sepolgen_info.get("if_path"):
        meta["sepolgen_if_path"] = sepolgen_info["if_path"]

    blockers = [
        f
        for f in findings
        if f.verdict in (VERDICT_FORBIDDEN, VERDICT_TOOLCHAIN)
    ]

    if args.explain:
        for f in findings:
            perms = " ".join(sorted(f.need.perms))
            print(
                f"[{f.verdict:>12}] {f.need.src_type} → {f.need.tgt_type}:"
                f"{f.need.tclass} {{{perms}}}"
            )
            print(f"               {f.note}")
            if f.rendered:
                print(f"               → {f.rendered}")
        emit_degraded_warning(findings)
        if blockers:
            args.out_dir.mkdir(parents=True, exist_ok=True)
            write_findings_artifact(
                args.out_dir, findings, sepolgen_info, generation_blocked=True
            )
        return 1 if blockers else 0

    if blockers:
        print("\n*** GENERATION BLOCKED — fix sepolgen or remove base-type denials from AVC log ***\n", file=sys.stderr)
        for f in blockers:
            print(f"REFUSED: {f.note}", file=sys.stderr)
        write_findings_artifact(
            args.out_dir, findings, sepolgen_info, generation_blocked=True
        )
        (args.out_dir / "pr_summary.md").write_text(
            write_pr_summary(findings, app_name),
            encoding="utf-8",
        )
        print(f"\nWrote {args.out_dir}/findings.json (generation_blocked=true)\n", file=sys.stderr)
        return 1

    emit_degraded_warning(findings)

    drift_notes = [f for f in findings if f.verdict == VERDICT_FC_DRIFT]
    if drift_notes:
        print("\nLABELING DRIFT (restorecon — no .fc / .te change):", file=sys.stderr)
        for f in drift_notes:
            print(f"  {f.note}", file=sys.stderr)

    boolean_notes = [f for f in findings if f.verdict == VERDICT_BOOLEAN]
    if boolean_notes:
        print("\nBOOLEAN TRIAGE (setsebool — no permanent .te allow):", file=sys.stderr)
        for f in boolean_notes:
            print(f"  {f.rendered}  # {f.note}", file=sys.stderr)

    version_file = args.version_file
    if args.bump_version:
        major, minor, patch = parse_version(read_policy_version(version_file))
        new_version = format_version(major, minor, patch + 1)
    else:
        new_version = read_policy_version(version_file)
        m = POLICY_MODULE_RE.search(existing_te)
        if m:
            new_version = m.group(2)

    fragment = render_fragment(findings, meta)
    fc_candidates = sorted({f.rendered for f in findings if f.verdict == VERDICT_FC and f.rendered})
    path_hints: dict[str, str] = {}
    for f in findings:
        if f.verdict == VERDICT_FC and f.rendered and f.paths:
            path_hints[f.rendered] = f.paths[0]

    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_te = merge_te(existing_te, app_name, new_version, fragment)
    out_fc = merge_fc(existing_fc, list(fc_candidates), path_hints)
    fc_fixes, _fc_dropped = filter_fc_fix_lines(existing_fc, list(fc_candidates), path_hints)

    (args.out_dir / f"{app_name}.te").write_text(out_te, encoding="utf-8")
    (args.out_dir / f"{app_name}.fc").write_text(out_fc, encoding="utf-8")
    write_findings_artifact(args.out_dir, findings, sepolgen_info, generation_blocked=False)
    (args.out_dir / "pr_summary.md").write_text(
        write_pr_summary(findings, app_name),
        encoding="utf-8",
    )
    if args.bump_version:
        (args.out_dir / "policy_version.txt").write_text(new_version + "\n", encoding="utf-8")

    if fc_fixes:
        print("\nLABELING FIXES (.fc — restorecon, do not grant generic types):")
        for line in fc_fixes:
            print(f"  {line}")

    print(f"\nWrote {args.out_dir}/{app_name}.{{te,fc}} ({len(findings)} net-new denial(s) classified)")
    return 0


def main() -> int:
    project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Deterministic AVC → policy generator")
    parser.add_argument("--avc-log", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--existing-te", type=Path, required=True)
    parser.add_argument("--existing-fc", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, default=Path("policy_out"))
    parser.add_argument("--app-name", default="myapp")
    parser.add_argument("--bump-version", action="store_true")
    parser.add_argument(
        "--version-file",
        type=Path,
        default=SELINUX_DIR / "policy_version.txt",
    )
    parser.add_argument("--explain", action="store_true")
    parser.add_argument(
        "--allow-degraded",
        action="store_true",
        help="When sepolgen is missing, emit raw allows on base types (engine=degraded in findings)",
    )
    parser.add_argument(
        "--boolean-hints",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "config" / "boolean_hints.yml",
        help="YAML table of AVC patterns → setsebool suggestions (default: config/boolean_hints.yml)",
    )
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
