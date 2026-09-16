#!/usr/bin/env python3
"""Local smoke tests (no SELinux/Podman required for most)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "cli"))

from avc_preprocess import (  # noqa: E402
    AccessNeed,
    build_llm_avc_summary,
    extract_type,
    merge_avc_entries,
    normalize_perms,
    parse_existing_allows,
    preprocess_avc_entries,
    subtract_covered,
)
from prompt_templates import SYSTEM_PROMPT, build_user_prompt  # noqa: E402
from selinux_gen import (  # noqa: E402
    bump_policy_version,
    deduplicate_avc_entries,
    filter_avc_entries,
    parse_avc_line,
    parse_policy_json,
    read_policy_version,
    validate_policy_content,
    validate_pr_summary,
)


def test_prompts() -> None:
    avc = (
        'type=AVC msg=audit(123): avc: denied { write } for pid=1 comm="python3" '
        "scontext=system_u:system_r:myapp_t:s0 "
        "tcontext=system_u:object_r:myapp_var_lib_t:s0 tclass=file permissive=1"
    )
    te = (PROJECT_ROOT / "selinux" / "myapp.te").read_text(encoding="utf-8")
    fc = (PROJECT_ROOT / "selinux" / "myapp.fc").read_text(encoding="utf-8")
    prompt = build_user_prompt(
        "myapp_t", avc, app_name="myapp", version="1.0.0", existing_te=te, existing_fc=fc
    )
    assert "myapp_t" in prompt
    assert "Existing Type Enforcement" in prompt
    assert len(SYSTEM_PROMPT) > 100


def test_avc_parsing() -> None:
    line = (
        'type=AVC msg=audit(1): avc: denied { write append open } for pid=99 '
        'scontext=system_u:system_r:myapp_t:s0 '
        "tcontext=system_u:object_r:myapp_var_lib_t:s0 tclass=file permissive=1"
    )
    entry = parse_avc_line(line)
    assert entry.perm == "write append open"
    deduped = deduplicate_avc_entries([entry, parse_avc_line(line)])
    assert len(deduped) == 1
    assert len(filter_avc_entries(deduped, "myapp_t")) == 1


def _sample_avc_line(perm: str, scontext: str, tcontext: str, tclass: str = "file") -> str:
    return (
        f'type=AVC msg=audit(1): avc: denied {{ {perm} }} for pid=1 comm="python3" '
        f"scontext={scontext} tcontext={tcontext} tclass={tclass} permissive=1"
    )


def test_perm_merge() -> None:
    line_a = _sample_avc_line(
        "write",
        "system_u:system_r:myapp_t:s0",
        "system_u:object_r:myapp_var_lib_t:s0",
    )
    line_b = _sample_avc_line(
        "append open",
        "system_u:system_r:myapp_t:s0",
        "system_u:object_r:myapp_var_lib_t:s0",
    )
    merged = merge_avc_entries([parse_avc_line(line_a), parse_avc_line(line_b)])
    assert len(merged) == 1
    assert merged[0].perms == frozenset({"write", "append", "open"})


def test_type_extraction_dedup() -> None:
    line_a = _sample_avc_line(
        "write",
        "system_u:system_r:myapp_t:s0",
        "system_u:object_r:myapp_var_lib_t:s0",
    )
    line_b = _sample_avc_line(
        "write",
        "system_u:object_r:myapp_t:s0",
        "system_u:object_r:myapp_var_lib_t:s0",
    )
    merged = merge_avc_entries([parse_avc_line(line_a), parse_avc_line(line_b)])
    assert len(merged) == 1
    assert extract_type("system_u:system_r:myapp_t:s0") == "myapp_t"


def test_subtract_existing() -> None:
    te = (PROJECT_ROOT / "selinux" / "myapp.te").read_text(encoding="utf-8")
    existing = parse_existing_allows(te)
    merged = [
        AccessNeed("myapp_t", "myapp_lib_t", "file", frozenset({"read"})),
    ]
    net_new, covered = subtract_covered(merged, existing)
    assert len(net_new) == 0, f"unexpected net_new: {net_new}"
    assert len(covered) == 1
    assert "read" in covered[0].perms


def test_net_new_detection() -> None:
    te = (PROJECT_ROOT / "selinux" / "myapp.te").read_text(encoding="utf-8")
    existing = parse_existing_allows(te)
    merged = [
        AccessNeed("myapp_t", "myapp_lib_t", "file", frozenset({"read", "write"})),
    ]
    net_new, covered = subtract_covered(merged, existing)
    assert any("write" in need.perms for need in net_new)
    assert any("read" in need.perms for need in covered)


def test_preprocess_stats() -> None:
    lines = [
        _sample_avc_line("write", "system_u:system_r:myapp_t:s0", "system_u:object_r:myapp_var_lib_t:s0"),
        _sample_avc_line("append", "system_u:system_r:myapp_t:s0", "system_u:object_r:myapp_var_lib_t:s0"),
        _sample_avc_line(
            "name_bind",
            "system_u:system_r:myapp_t:s0",
            "system_u:object_r:unreserved_port_t:s0",
            tclass="tcp_socket",
        ),
    ]
    entries = [parse_avc_line(line) for line in lines]
    entries = filter_avc_entries(entries, "myapp_t")
    _, stats = preprocess_avc_entries(entries, existing_te="")
    assert stats["raw"] == 3
    assert stats["merged"] == 2
    assert stats["merged"] < stats["raw"]


def test_prompt_uses_summary() -> None:
    te = (PROJECT_ROOT / "selinux" / "myapp.te").read_text(encoding="utf-8")
    fc = (PROJECT_ROOT / "selinux" / "myapp.fc").read_text(encoding="utf-8")
    entries = [
        parse_avc_line(
            _sample_avc_line("link", "system_u:system_r:myapp_t:s0", "system_u:object_r:myapp_var_lib_t:s0")
        )
    ]
    summary, _ = build_llm_avc_summary(entries, existing_te=te)
    prompt = build_user_prompt(
        "myapp_t", summary, app_name="myapp", version="1.0.0", existing_te=te, existing_fc=fc
    )
    assert "Net-new access needs" in prompt
    assert "Access needs derived from AVCs" in prompt
    assert "Already covered by existing policy" in prompt


def test_no_changes_needed_summary() -> None:
    te = (PROJECT_ROOT / "selinux" / "myapp.te").read_text(encoding="utf-8")
    entries = [
        parse_avc_line(
            _sample_avc_line("read", "system_u:system_r:myapp_t:s0", "system_u:object_r:myapp_lib_t:s0")
        )
    ]
    summary, stats = build_llm_avc_summary(entries, existing_te=te)
    assert stats.get("no_changes_needed") == 1
    assert "no te_content changes required" in summary.lower() or "No te_content changes" in summary


def test_pr_summary_split_and_validate() -> None:
    from pr_summary_common import (
        merge_pr_summary,
        split_pr_summary_sections,
        validate_narrative_section,
        validate_pr_summary,
    )

    narrative = "\n".join(
        [
            "### Network Bindings",
            "- port 8888",
            "",
            "### File System Access",
            "- /var/lib/myapp",
            "",
            "### Process Execution",
            "- myapp_exec_t",
            "",
            "### Explicit Denials Maintained",
            "- no wildcards",
        ]
    )
    tail = "\n".join(
        [
            "### Host administrative actions (not shipped in RPM)",
            "- None",
            "",
            "### Classification audit (engine)",
            "| Verdict | Target | Engine | Note |",
            "| --- | --- | --- | --- |",
            "| direct | myapp_log_t | rules | ok |",
        ]
    )
    template = narrative + "\n\n" + tail
    got_narr, got_tail = split_pr_summary_sections(template)
    assert "### Host administrative" in got_tail
    assert "Classification audit" in got_tail
    merged = merge_pr_summary(got_narr, got_tail)
    validate_pr_summary(merged)
    validate_narrative_section(got_narr)
    try:
        validate_narrative_section("allow myapp_t shadow_t:file read;")
        raise AssertionError("expected validate_narrative_section to fail")
    except RuntimeError:
        pass


def test_policy_json_validation() -> None:
    payload = {
        "module_name": "myapp",
        "te_content": "policy_module(myapp, 1.0.0)\ntype myapp_t;\n",
        "fc_content": (
            "/opt/myapp/app\\.py -- gen_context(system_u:object_r:myapp_exec_t,s0)\n"
            "/var/lib/myapp(/.*)? gen_context(system_u:object_r:myapp_var_lib_t,s0)\n"
            "/run/myapp(/.*)? gen_context(system_u:object_r:myapp_var_run_t,s0)\n"
        ),
        "rationale": "test",
        "pr_summary": (
            "### Network Bindings\n- Binds unreserved_port_t:8888\n\n"
            "### File System Access\n- myapp_var_lib_t read/write\n\n"
            "### Process Execution\n- myapp_exec_t transitions\n\n"
            "### Explicit Denials Maintained\n- No shadow_t access\n"
        ),
    }
    data = parse_policy_json(json.dumps(payload))
    validate_policy_content(data["te_content"], data["fc_content"], "myapp_t", "myapp")
    validate_pr_summary(data["pr_summary"])


def test_version_bump() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        vf = Path(tmp) / "policy_version.txt"
        vf.write_text("1.0.0\n", encoding="utf-8")
        assert read_policy_version(vf) == "1.0.0"
        assert bump_policy_version(vf) == "1.0.1"
        assert read_policy_version(vf) == "1.0.1"


def test_flask_endpoints(require_backend: bool = True) -> None:
    tmp = Path(tempfile.mkdtemp(prefix="myapp-smoke-"))
    bin_dir = tmp / "bin"
    var_dir = tmp / "var" / "lib" / "myapp"
    run_dir = tmp / "run" / "myapp"
    bin_dir.mkdir()
    var_dir.mkdir(parents=True)
    run_dir.mkdir(parents=True)
    notify_sock = run_dir / "notify.sock"
    backend_port = 18889

    backend_src = (PROJECT_ROOT / "app" / "backend_stub.py").read_text(encoding="utf-8")
    backend_path = tmp / "backend_stub.py"
    backend_path.write_text(backend_src, encoding="utf-8")

    app_src = (PROJECT_ROOT / "app" / "app.py").read_text(encoding="utf-8")
    app_src = app_src.replace("/var/lib/myapp", str(var_dir))
    app_src = app_src.replace("/run/myapp", str(run_dir))
    app_src = app_src.replace("/opt/myapp/bin/backup.sh", str(bin_dir / "backup.sh"))
    app_path = tmp / "app.py"
    app_path.write_text(app_src, encoding="utf-8")

    backup_src = (PROJECT_ROOT / "app" / "backup.sh").read_text(encoding="utf-8")
    backup_src = backup_src.replace("/var/lib/myapp", str(var_dir))
    backup_path = bin_dir / "backup.sh"
    backup_path.write_text(backup_src, encoding="utf-8")
    backup_path.chmod(0o755)

    backend_env = {
        **os.environ,
        "MYAPP_NOTIFY_SOCK": str(notify_sock),
        "MYAPP_BACKEND_PORT": str(backend_port),
    }
    app_env = {
        **os.environ,
        "MYAPP_BACKEND_URL": f"http://127.0.0.1:{backend_port}/health",
        "MYAPP_NOTIFY_SOCK": str(notify_sock),
    }

    backend_proc = subprocess.Popen(
        [sys.executable, str(backend_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=backend_env,
    )
    proc = subprocess.Popen(
        [sys.executable, str(app_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=app_env,
    )
    try:
        for _ in range(30):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{backend_port}/health", timeout=1):
                    pass
                with urllib.request.urlopen("http://127.0.0.1:8888/", timeout=1) as resp:
                    assert resp.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.2)
        else:
            raise AssertionError("Flask app or backend stub did not become healthy")

        if require_backend:
            with urllib.request.urlopen(f"http://127.0.0.1:{backend_port}/health", timeout=3) as resp:
                assert resp.status == 200

        for path in ("/", "/save-log", "/run-script", "/rotate-log", "/probe-backend", "/notify-socket"):
            with urllib.request.urlopen(f"http://127.0.0.1:8888{path}", timeout=3) as resp:
                body = resp.read().decode("utf-8")
                assert resp.status == 200
                assert "ok" in body
    finally:
        proc.terminate()
        backend_proc.terminate()
        for child in (proc, backend_proc):
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()


def test_assemble_pr_body_policy_diff_section() -> None:
    """assemble_pr_body embeds precomputed sesearch delta (full diff needs Podman + git merge-base)."""
    fixture = PROJECT_ROOT / "docs" / "examples" / "fixtures" / "policy_diff" / "sample_delta.md"
    assert fixture.is_file(), f"missing {fixture}"
    with tempfile.TemporaryDirectory() as tmp:
        pr_summary = Path(tmp) / "pr_summary.md"
        pr_summary.write_text("### Network Bindings\n- test\n", encoding="utf-8")
        avc_log = Path(tmp) / "avc.log"
        avc_log.write_text("type=AVC msg=audit(1): avc: denied { read } for pid=1\n", encoding="utf-8")
        output = Path(tmp) / "pr_body.md"
        script = PROJECT_ROOT / "scripts" / "assemble_pr_body.sh"
        subprocess.run(
            [
                "bash",
                str(script),
                "--template",
                str(PROJECT_ROOT / ".github" / "PULL_REQUEST_TEMPLATE" / "selinux_policy_review.md"),
                "--pr-summary",
                str(pr_summary),
                "--avc-log",
                str(avc_log),
                "--output",
                str(output),
                "--app-name",
                "myapp",
                "--policy-diff-file",
                str(fixture),
            ],
            check=True,
            cwd=PROJECT_ROOT,
        )
        body = output.read_text(encoding="utf-8")
        assert "Rules ADDED" in body
        assert "name_bind" in body
        assert "sediff unavailable" not in body.lower()


def test_assemble_pr_body() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        pr_summary = Path(tmp) / "pr_summary.md"
        pr_summary.write_text(
            "### Network Bindings\n- Port 8888 via unreserved_port_t\n\n"
            "### File System Access\n- /var/lib/myapp data dir\n\n"
            "### Process Execution\n- backup.sh via myapp_exec_t\n\n"
            "### Explicit Denials Maintained\n- No wildcard allows\n",
            encoding="utf-8",
        )
        avc_log = Path(tmp) / "avc.log"
        avc_log.write_text(
            'type=AVC msg=audit(1): avc: denied { write } for pid=1 comm="python3" '
            "scontext=system_u:system_r:myapp_t:s0 "
            "tcontext=system_u:object_r:myapp_var_lib_t:s0 tclass=file permissive=1\n",
            encoding="utf-8",
        )
        output = Path(tmp) / "pr_body.md"
        template = PROJECT_ROOT / ".github" / "PULL_REQUEST_TEMPLATE" / "selinux_policy_review.md"
        script = PROJECT_ROOT / "scripts" / "assemble_pr_body.sh"
        subprocess.run(
            [
                "bash",
                str(script),
                "--template",
                str(template),
                "--pr-summary",
                str(pr_summary),
                "--avc-log",
                str(avc_log),
                "--output",
                str(output),
                "--app-name",
                "myapp",
                "--staging-host",
                "staging.example.com",
                "--skip-policy-diff",
            ],
            check=True,
            cwd=PROJECT_ROOT,
        )
        body = output.read_text(encoding="utf-8")
        assert "### Network Bindings" in body
        assert "Security and Sysadmin Checklist" in body
        assert "staging.example.com" in body
        assert "type=AVC" in body
        assert "<!-- AUTO:PR_SUMMARY -->" not in body
        assert "<!-- AUTO:AVC_EXCERPT -->" not in body


def test_verify_file_contexts_skip() -> None:
    script = PROJECT_ROOT / "scripts" / "verify_file_contexts.sh"
    result = subprocess.run(
        ["bash", str(script), "--skip-if-unavailable"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_check_soak_ready_gate() -> None:
    script = PROJECT_ROOT / "scripts" / "check_soak_ready.sh"
    with tempfile.TemporaryDirectory() as tmp:
        marker = Path(tmp) / "marker"
        report = Path(tmp) / "selinux_deploy_report.json"
        report.write_text(
            json.dumps(
                {
                    "status": "pass",
                    "endpoints_exercised": True,
                    "domain_context_verified": True,
                }
            ),
            encoding="utf-8",
        )
        missing = subprocess.run(
            ["bash", str(script), "--marker-file", str(marker), "--min-days", "7"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert missing.returncode != 0

        marker.write_text(str(int(time.time())), encoding="utf-8")
        recent = subprocess.run(
            ["bash", str(script), "--marker-file", str(marker), "--min-days", "7", "--max-avc", "0"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert recent.returncode != 0

        old_epoch = int(time.time()) - (8 * 86400)
        marker.write_text(str(old_epoch), encoding="utf-8")
        old = subprocess.run(
            [
                "bash",
                str(script),
                "--marker-file",
                str(marker),
                "--min-days",
                "7",
                "--max-avc",
                "0",
                "--skip-if-unavailable",
                "--report-file",
                str(report),
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert old.returncode == 0, old.stderr


def test_monitor_avc_skip() -> None:
    script = PROJECT_ROOT / "scripts" / "monitor_avc.sh"
    manifest = PROJECT_ROOT / "config" / "myapp.manifest.yml"
    result = subprocess.run(
        [
            "bash",
            str(script),
            "--skip-if-unavailable",
            "--max-avc",
            "-1",
            "--manifest",
            str(manifest),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_soak_net_new_empty_manifest() -> None:
    manifest = PROJECT_ROOT / "config" / "myapp.manifest.yml"
    proc = subprocess.run(
        [
            sys.executable,
            str(PROJECT_ROOT / "cli" / "soak_net_new.py"),
            "--manifest",
            str(manifest),
        ],
        input="",
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["raw_count"] == 0
    assert data["net_new_count"] == 0


def test_demo_present_help() -> None:
    script = PROJECT_ROOT / "scripts" / "demo_present.sh"
    result = subprocess.run(
        ["bash", str(script), "--help"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert "ACT 1" in result.stdout or "Acts:" in result.stdout


def test_app_manifest() -> None:
    loader = PROJECT_ROOT / "scripts" / "lib" / "app_manifest.py"
    demo_manifest = PROJECT_ROOT / "config" / "myapp.manifest.yml"
    example_manifest = PROJECT_ROOT / "config" / "payments.manifest.example.yml"

    for path in (demo_manifest, example_manifest):
        result = subprocess.run(
            ["python3", str(loader), "validate", str(path)],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr or result.stdout

    wrapper = PROJECT_ROOT / "scripts" / "validate_app_manifest.sh"
    result = subprocess.run(
        ["bash", str(wrapper), str(demo_manifest)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    assert "OK" in result.stdout

    export = subprocess.run(
        ["python3", str(loader), "shell-export", str(demo_manifest)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert export.returncode == 0, export.stderr
    assert "HTTP_PORT=8888" in export.stdout
    assert "PRIMARY_SERVICE=\"myapp.service\"" in export.stdout
    assert "PATHS_CSV=" in export.stdout
    assert "/var/opt/myapp" in export.stdout

    paths_csv = subprocess.run(
        ["python3", str(loader), "paths-csv", str(demo_manifest)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert paths_csv.returncode == 0, paths_csv.stderr
    assert "/opt/myapp" in paths_csv.stdout
    assert "myapp" in paths_csv.stdout
    assert "/opt/payments" not in paths_csv.stdout


def test_rpm_ops_parity() -> None:
    script = PROJECT_ROOT / "scripts" / "validate_rpm_ops_parity.sh"
    result = subprocess.run(
        ["bash", str(script)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_version_consistency() -> None:
    script = PROJECT_ROOT / "scripts" / "validate_version_consistency.sh"
    result = subprocess.run(
        ["bash", str(script)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_version_consistency_fails_on_payments_drift() -> None:
    script = PROJECT_ROOT / "scripts" / "validate_version_consistency.sh"
    vf = PROJECT_ROOT / "selinux" / "payments" / "policy_version.txt"
    original = vf.read_text(encoding="utf-8")
    try:
        vf.write_text("9.9.9\n", encoding="utf-8")
        result = subprocess.run(
            ["bash", str(script)],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0, "expected failure when payments policy_version.txt drifts from .te"
    finally:
        vf.write_text(original, encoding="utf-8")


def test_scaffold_billing_no_myapp_leak() -> None:
    script = PROJECT_ROOT / "scripts" / "scaffold_sepolicy_module.sh"
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "selinux").mkdir()
        fake_bin = root / "bin"
        fake_bin.mkdir()
        fake_sep = fake_bin / "sepolicy-generate"
        fake_sep.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "cat > \"${PWD}/billing.te\" <<'EOF'\n"
            "policy_module(billing, 1.0.0)\n"
            "type billing_t;\n"
            "EOF\n"
            "touch \"${PWD}/billing.fc\" \"${PWD}/billing.if\"\n",
            encoding="utf-8",
        )
        fake_sep.chmod(0o755)
        env = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
            "SCAFFOLD_PROJECT_ROOT": str(root),
        }
        result = subprocess.run(
            ["bash", str(script), "billing", "billing_t"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            env=env,
        )
        assert result.returncode == 0, result.stderr + result.stdout
        te = root / "selinux" / "billing" / "billing.te"
        assert te.is_file(), te
        text = te.read_text(encoding="utf-8")
        forbidden = ("myapp_t", "/opt/myapp", "Order Processor", "myapp_port_t")
        for needle in forbidden:
            assert needle not in text, f"scaffold leaked {needle!r} in {text}"


def test_deterministic_payments_manifest_check() -> None:
    script = PROJECT_ROOT / "scripts" / "run_deterministic_payments_check.sh"
    result = subprocess.run(
        ["bash", str(script)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr + result.stdout


def test_version_consistency_fails_on_drift() -> None:
    script = PROJECT_ROOT / "scripts" / "validate_version_consistency.sh"
    spec = PROJECT_ROOT / "packaging" / "myapp-selinux.spec"
    original = spec.read_text(encoding="utf-8")
    try:
        spec.write_text(original.replace("Version:        %{modver}", "Version:        9.9.9"), encoding="utf-8")
        result = subprocess.run(
            ["bash", str(script)],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0, "expected failure when spec Version is hardcoded"
    finally:
        spec.write_text(original, encoding="utf-8")


def test_promote_policy_version_from_te() -> None:
    """promote_to_selinux must rewrite selinux/policy_version.txt from policy_module() when missing in policy_out."""
    import tempfile

    version_sh = PROJECT_ROOT / "scripts" / "lib" / "version.sh"
    te_src = PROJECT_ROOT / "docs" / "examples" / "fixtures" / "skip_ai" / "generated" / "myapp.te"
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        policy_out = root / "policy_out"
        selinux = root / "selinux"
        policy_out.mkdir()
        selinux.mkdir()
        (policy_out / "myapp.te").write_text(te_src.read_text(encoding="utf-8"), encoding="utf-8")
        (policy_out / "myapp.fc").write_text("# fixture\n", encoding="utf-8")
        (selinux / "policy_version.txt").write_text("1.0.0\n", encoding="utf-8")
        script = f"""
set -euo pipefail
PROJECT_ROOT="{root}"
APP_NAME=myapp
POLICY_OUT="${{PROJECT_ROOT}}/policy_out"
SELINUX_DIR="${{PROJECT_ROOT}}/selinux"
source "{version_sh}"
match="$(policy_module_version_from_te "${{POLICY_OUT}}/myapp.te" "${{APP_NAME}}")"
echo "${{match}}" > "${{SELINUX_DIR}}/policy_version.txt"
"""
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        got = (selinux / "policy_version.txt").read_text(encoding="utf-8").strip()
        assert got == "1.1.2", f"expected 1.1.2 from fixture te, got {got!r}"


def test_classify_fail_closed_json() -> None:
    script = PROJECT_ROOT / "scripts" / "classify_policy_blast_radius.sh"
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / "base.pp"
        cand = Path(tmp) / "cand.pp"
        base.write_bytes(b"FAKE")
        cand.write_bytes(b"FAKE")
        result = subprocess.run(
            ["bash", str(script), str(base), str(cand)],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            env={**os.environ, "CLASSIFY_SKIP_PODMAN": "1"},
        )
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["min_days"] == 7
    assert payload.get("fail_closed") is True
    assert "tier" in payload


def test_check_soak_auto_tier_fail_closed() -> None:
    """--auto-tier must not shorten soak when classifier returns fail_closed."""
    script = PROJECT_ROOT / "scripts" / "check_soak_ready.sh"
    base = PROJECT_ROOT / "tests/fixtures/blast_radius/_common/base.te"
    cand = PROJECT_ROOT / "tests/fixtures/blast_radius/low_private_type/cand.te"
    with tempfile.TemporaryDirectory() as tmp:
        marker = Path(tmp) / "marker"
        report = Path(tmp) / "selinux_deploy_report.json"
        report.write_text(
            json.dumps(
                {
                    "status": "pass",
                    "endpoints_exercised": True,
                    "domain_context_verified": True,
                }
            ),
            encoding="utf-8",
        )
        old_epoch = int(time.time()) - (8 * 86400)
        marker.write_text(str(old_epoch), encoding="utf-8")
        result = subprocess.run(
            [
                "bash",
                str(script),
                "--marker-file",
                str(marker),
                "--report-file",
                str(report),
                "--min-days",
                "7",
                "--max-avc",
                "9999",
                "--skip-if-unavailable",
                "--auto-tier",
                "--base-policy",
                str(base),
                "--candidate-policy",
                str(cand),
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            env={**os.environ, "CLASSIFY_SKIP_PODMAN": "1"},
        )
    combined = result.stdout + result.stderr
    assert "Blast-radius classifier fail-closed" in combined, combined
    assert "soak minimum 7 day" in combined, combined


def test_skip_ai_fixture_sync() -> None:
    """Offline demo generated/ must match selinux/ (refresh_skip_ai_fixture.sh)."""
    fix = PROJECT_ROOT / "docs" / "examples" / "fixtures" / "skip_ai" / "generated"
    for name in ("myapp.te", "myapp.fc"):
        assert (fix / name).read_text(encoding="utf-8") == (
            PROJECT_ROOT / "selinux" / name
        ).read_text(encoding="utf-8"), f"Drift in skip_ai/generated/{name} — run refresh_skip_ai_fixture.sh"


DETERMINISTIC_CLASSIFICATION_VERDICTS = frozenset(
    {
        "fc_fix",
        "fc_drift",
        "private_port",
        "forbidden",
        "baseline",
        "interface",
        "direct",
        "toolchain_required",
        "boolean",
    }
)


def _deterministic_fixture_dirs(root: Path) -> list[Path]:
    return sorted(
        p
        for p in root.iterdir()
        if p.is_dir() and (p / "avc.log").is_file() and (p / "expected.json").is_file()
    )


def _deterministic_case_meta(case_dir: Path) -> dict:
    meta_path = case_dir / "case.meta.json"
    if meta_path.is_file():
        return json.loads(meta_path.read_text(encoding="utf-8"))
    return {"exit_code": 0}


def _deterministic_boolean_mock(case_dir: Path) -> dict | None:
    mock_path = case_dir / "boolean_mock.json"
    if not mock_path.is_file():
        return None
    return json.loads(mock_path.read_text(encoding="utf-8"))


def _deterministic_sepolgen_mock(case_dir: Path) -> dict | None:
    mock_path = case_dir / "sepolgen_mock.json"
    if not mock_path.is_file():
        return None
    return json.loads(mock_path.read_text(encoding="utf-8"))


def _deterministic_run_args(
    case_dir: Path,
    manifest: Path,
    te: Path,
    fc: Path,
    *,
    explain: bool,
    out_dir: Path,
) -> argparse.Namespace:
    meta = _deterministic_case_meta(case_dir)
    hints_path = PROJECT_ROOT / "config" / "boolean_hints.yml"
    rel = meta.get("boolean_hints")
    if rel:
        hints_path = case_dir / str(rel)
    return argparse.Namespace(
        avc_log=case_dir / "avc.log",
        manifest=manifest,
        existing_te=te,
        existing_fc=fc,
        out_dir=out_dir,
        app_name=None,
        bump_version=False,
        version_file=PROJECT_ROOT / "selinux" / "policy_version.txt",
        explain=explain,
        allow_degraded=False,
        policy_kern=None,
        boolean_hints=hints_path,
    )


def _boolean_lookup_from_mock(mock: dict):
    from boolean_hints import BooleanLookupResult, BooleanMatch

    behavior = mock.get("behavior")
    if behavior == "match":
        matches = tuple(
            BooleanMatch(str(m["name"]), str(m.get("description") or ""))
            for m in mock.get("matches") or []
        )
        return BooleanLookupResult(status="matched", matches=matches)
    if behavior == "none":
        return BooleanLookupResult(status="none")
    if behavior == "unavailable":
        return BooleanLookupResult(
            status="unavailable",
            detail=str(mock.get("detail") or "boolean lookup unavailable"),
        )
    raise ValueError(f"unknown boolean_mock behavior {behavior!r}")


def _run_deterministic_gen(
    case_dir: Path,
    manifest: Path,
    te: Path,
    fc: Path,
    *,
    explain: bool,
    out_dir: Path,
    mock: dict | None,
    boolean_mock: dict | None,
) -> tuple[int, str, str]:
    """Run deterministic_gen; in-process when fixture mocks are present."""
    import io
    from contextlib import ExitStack, redirect_stderr, redirect_stdout
    from unittest.mock import patch

    import deterministic_gen as dg

    args = _deterministic_run_args(
        case_dir, manifest, te, fc, explain=explain, out_dir=out_dir
    )
    stdout = io.StringIO()
    stderr = io.StringIO()

    def _invoke() -> int:
        with redirect_stdout(stdout), redirect_stderr(stderr):
            return dg.run(args)

    if not mock and not boolean_mock:
        gen = PROJECT_ROOT / "cli" / "deterministic_gen.py"
        result = subprocess.run(
            [
                sys.executable,
                str(gen),
                *(["--explain"] if explain else []),
                "--avc-log",
                str(args.avc_log),
                "--manifest",
                str(manifest),
                "--existing-te",
                str(te),
                "--existing-fc",
                str(fc),
                "--out-dir",
                str(out_dir),
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        return result.returncode, result.stdout, result.stderr

    with ExitStack() as stack:
        if mock:
            behavior = mock.get("behavior")
            if behavior == "match":
                rendered = mock["rendered"]
                note = mock.get("note", "mock interface")

                def _fake_match(*_a, **_k):
                    return (rendered, note)

                stack.enter_context(patch.object(dg, "try_sepolgen_interface", _fake_match))
            elif behavior == "no_match":
                stack.enter_context(patch.object(dg, "try_sepolgen_interface", return_value=None))
            elif behavior == "unavailable":
                stack.enter_context(
                    patch.object(
                        dg, "try_sepolgen_interface", return_value=dg.SEPOLGEN_UNAVAILABLE
                    )
                )
            else:
                raise ValueError(f"{case_dir.name}: unknown sepolgen_mock behavior {behavior!r}")
        if boolean_mock:

            def _fake_bool(*_a, **_k):
                return _boolean_lookup_from_mock(boolean_mock)

            import boolean_hints as bh

            stack.enter_context(patch.object(bh, "lookup_booleans_for_need", _fake_bool))
        code = _invoke()

    return code, stdout.getvalue(), stderr.getvalue()


def test_deterministic_verdict_fixture_coverage() -> None:
    """Every classification verdict has at least one golden fixture row."""
    root = PROJECT_ROOT / "docs" / "examples" / "fixtures" / "deterministic"
    seen: set[str] = set()
    for case_dir in _deterministic_fixture_dirs(root):
        for row in json.loads((case_dir / "expected.json").read_text(encoding="utf-8")):
            seen.add(row["verdict"])
    missing = DETERMINISTIC_CLASSIFICATION_VERDICTS - seen
    assert not missing, f"Add fixtures for verdict(s): {sorted(missing)}"


def test_deterministic_fixture_classify() -> None:
    """Golden verdict checks for deterministic_gen --explain and full generation."""
    root = PROJECT_ROOT / "docs" / "examples" / "fixtures" / "deterministic"
    manifest = PROJECT_ROOT / "config" / "myapp.manifest.yml"
    te = PROJECT_ROOT / "selinux" / "myapp.te"
    fc = PROJECT_ROOT / "selinux" / "myapp.fc"

    for case_dir in _deterministic_fixture_dirs(root):
        case = case_dir.name
        meta = _deterministic_case_meta(case_dir)
        mock = _deterministic_sepolgen_mock(case_dir)
        boolean_mock = _deterministic_boolean_mock(case_dir)
        expected = json.loads((case_dir / "expected.json").read_text(encoding="utf-8"))
        want_exit = int(meta.get("exit_code", 0))

        code, out, err = _run_deterministic_gen(
            case_dir,
            manifest,
            te,
            fc,
            explain=True,
            out_dir=case_dir / "_out",
            mock=mock,
            boolean_mock=boolean_mock,
        )
        combined = out + err
        assert code == want_exit, f"{case}: explain exit {code}, want {want_exit}\n{combined}"
        for needle in meta.get("stderr_substrings", []):
            assert needle in combined, f"{case}: stderr missing {needle!r}\n{combined}"

        gen_code, gen_out, gen_err = _run_deterministic_gen(
            case_dir,
            manifest,
            te,
            fc,
            explain=False,
            out_dir=case_dir / "_out",
            mock=mock,
            boolean_mock=boolean_mock,
        )
        assert gen_code == want_exit, (
            f"{case}: generation exit {gen_code}, want {want_exit}\n{gen_err}{gen_out}"
        )
        findings_path = case_dir / "_out" / "findings.json"
        assert findings_path.is_file(), f"{case}: missing findings.json"
        payload = json.loads(findings_path.read_text(encoding="utf-8"))
        rows = payload["findings"] if isinstance(payload, dict) else payload
        for want in expected:
            matched = [
                row
                for row in rows
                if row.get("verdict") == want["verdict"] and row.get("tgt") == want["tgt"]
            ]
            assert matched, f"{case}: missing {want} in {rows}"
            if want.get("boolean"):
                assert any(row.get("boolean") == want["boolean"] for row in matched), (
                    f"{case}: boolean name mismatch for {want}"
                )
            if want.get("next_action"):
                assert any(row.get("next_action") == want["next_action"] for row in matched), (
                    f"{case}: next_action mismatch for {want} in {matched}"
                )
            if "port" in want:
                assert any(row.get("port") == want["port"] for row in matched), (
                    f"{case}: port mismatch for {want} in {matched}"
                )
        if want_exit != 0:
            assert payload.get("generation_blocked") is True, f"{case}: expected generation_blocked"
            continue

        if case == "02-port-bind":
            summary = (case_dir / "_out" / "pr_summary.md").read_text(encoding="utf-8")
            assert "add_manifest_port" in summary, f"{case}: pr_summary missing next_action"
            assert "port: 8888" in summary, f"{case}: pr_summary missing selinux_ports snippet"
        if case == "01-mislabeled-var-lib":
            out_fc = (case_dir / "_out" / "myapp.fc").read_text(encoding="utf-8")
            assert out_fc == fc.read_text(encoding="utf-8"), (
                f"{case}: .fc must not grow per-file lines when directory regex already covers path"
            )
        if case == "06-fc-missing-line":
            out_fc = (case_dir / "_out" / "myapp.fc").read_text(encoding="utf-8")
            assert "/opt/myapp/cache/data" in out_fc, f"{case}: expected new .fc line for cache path"
        if case == "04-boolean-network-connect":
            digest_a = hashlib.sha256(
                (case_dir / "_out" / "myapp.te").read_bytes()
                + (case_dir / "_out" / "findings.json").read_bytes()
            ).hexdigest()
            code2, _, _ = _run_deterministic_gen(
                case_dir,
                manifest,
                te,
                fc,
                explain=False,
                out_dir=case_dir / "_out2",
                mock=mock,
                boolean_mock=boolean_mock,
            )
            assert code2 == 0
            digest_b = hashlib.sha256(
                (case_dir / "_out2" / "myapp.te").read_bytes()
                + (case_dir / "_out2" / "findings.json").read_bytes()
            ).hexdigest()
            assert digest_a == digest_b, f"{case}: non-deterministic output between runs"
        if case in ("04-boolean-network-connect", "10-boolean-hint"):
            out_te = (case_dir / "_out" / "myapp.te").read_text(encoding="utf-8")
            assert "http_port_t" not in out_te, f"{case}: must not add permanent allow on http_port_t"
            row = next(r for r in rows if r.get("verdict") == "boolean")
            assert row.get("boolean") == "httpd_can_network_connect"
            assert "setsebool -P" in (row.get("rendered") or "")
            assert payload.get("host_admin_actions"), f"{case}: expected host_admin_actions in findings"
        if case == "10-boolean-hint":
            row10 = next(r for r in rows if r.get("verdict") == "boolean")
            assert row10.get("engine") == "curated_override", row10


def test_payments_onboarding_module() -> None:
    """Second app: manifest example + selinux/payments with shipped .if."""
    mod = PROJECT_ROOT / "selinux" / "payments"
    for name in ("payments.te", "payments.fc", "payments.if"):
        assert (mod / name).is_file(), f"missing {mod / name}"
    if_text = (mod / "payments.if").read_text(encoding="utf-8")
    assert "interface(`payments_read_public_state'" in if_text
    loader = PROJECT_ROOT / "scripts" / "lib" / "app_manifest.py"
    result = subprocess.run(
        ["python3", str(loader), "json", str(PROJECT_ROOT / "config" / "payments.manifest.example.yml")],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    norm = json.loads(result.stdout)
    assert norm["policy"]["module_dir"] == "selinux/payments"


def test_selinux_build_image_internal_registry() -> None:
    """Compile image URL is fully overridable (not hard-coded at runtime)."""
    lib = PROJECT_ROOT / "scripts" / "lib" / "build_image.sh"
    internal = "registry.example.com/security/selinux-demo-selinux-build:stream9"
    result = subprocess.run(
        [
            "bash",
            "-c",
            f"source '{lib}' && printf '%s' \"$SELINUX_BUILD_IMAGE\"",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        env={**os.environ, "SELINUX_BUILD_IMAGE": internal},
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == internal


def test_single_ensure_selinux_build_image_definition() -> None:
    """ensure_selinux_build_image() must exist in exactly one library (no silent override)."""
    lib_dir = PROJECT_ROOT / "scripts" / "lib"
    count = 0
    owner = ""
    for path in sorted(lib_dir.glob("*.sh")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("ensure_selinux_build_image()"):
                count += 1
                owner = str(path.relative_to(PROJECT_ROOT))
    assert count == 1, f"expected one ensure_selinux_build_image(), found {count} in {owner or '?'}"


def test_export_app_avcs_requires_paths() -> None:
    avc_lib = PROJECT_ROOT / "scripts" / "lib" / "avc_query.sh"
    result = subprocess.run(
        [
            "bash",
            "-c",
            f"source '{avc_lib}' && export_app_avcs_to_file /tmp/x.log boot payments_t '' ''",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "paths_csv required" in result.stderr


def test_boolean_policy_render() -> None:
    from boolean_hints import BooleanMatch, render_boolean_finding, resolve_booleans_for_need

    rendered, note, names = render_boolean_finding(
        (BooleanMatch("httpd_can_network_connect", "Allow httpd to connect to http ports"),)
    )
    assert rendered == "setsebool -P httpd_can_network_connect on"
    assert "-P" in rendered
    assert names == "httpd_can_network_connect"
    assert "Host-wide" in note

    multi = (
        BooleanMatch("aaa_first", "desc a"),
        BooleanMatch("bbb_second", "desc b"),
    )
    rendered_m, note_m, names_m = render_boolean_finding(multi)
    assert "setsebool -P aaa_first on" in rendered_m
    assert "setsebool -P bbb_second on" in rendered_m
    assert "aaa_first" in names_m and "bbb_second" in names_m
    assert "choose deliberately" in note_m


def test_boolean_triage_two_matches() -> None:
    from boolean_hints import BooleanLookupResult, BooleanMatch, resolve_booleans_for_need

    need = AccessNeed(
        "myapp_t",
        "http_port_t",
        "tcp_socket",
        frozenset({"name_connect"}),
    )

    def _fake(_need, *, policy_kern=None):
        return BooleanLookupResult(
            status="matched",
            matches=(
                BooleanMatch("aaa_first", "desc a"),
                BooleanMatch("bbb_second", "desc b"),
            ),
        )

    out = resolve_booleans_for_need(need, [], {}, policy_lookup=_fake)
    assert out.status == "matched"
    assert [m.name for m in out.matches] == ["aaa_first", "bbb_second"]
    from boolean_hints import render_boolean_finding

    rendered, note, names = render_boolean_finding(out.matches)
    assert "setsebool -P aaa_first on" in rendered
    assert "setsebool -P bbb_second on" in rendered
    assert "choose deliberately" in note
    assert "aaa_first" in names and "bbb_second" in names


def test_boolean_curated_when_policy_unavailable() -> None:
    from boolean_hints import BooleanLookupResult, resolve_booleans_for_need

    need = AccessNeed("payments_t", "http_port_t", "tcp_socket", frozenset({"name_connect"}))
    hints = [
        {
            "boolean": "httpd_can_network_connect",
            "note": "site",
            "match": {"tgt_type": "http_port_t", "tclass": "tcp_socket", "perms": ["name_connect"]},
        }
    ]

    def _unavail(_need, *, policy_kern=None):
        return BooleanLookupResult(status="unavailable", detail="offline")

    out = resolve_booleans_for_need(need, hints, {"app_name": "payments", "domain": "payments_t"}, policy_lookup=_unavail)
    assert out.status == "matched"
    assert out.matches[0].name == "httpd_can_network_connect"


def test_boolean_hint_yaml_still_documents_patterns() -> None:
    from boolean_hints import load_boolean_hints

    hints = load_boolean_hints(PROJECT_ROOT / "config" / "boolean_hints.yml")
    assert hints and hints[0].get("boolean") == "httpd_can_network_connect"
    assert "src_type" not in (hints[0].get("match") or {})


def test_fc_labeling_drift_detection() -> None:
    from fc_labeling import existing_fc_covers, filter_fc_fix_lines, strip_redundant_fc_lines

    baseline = (PROJECT_ROOT / "selinux" / "myapp.fc").read_text(encoding="utf-8")
    path = "/var/lib/myapp/data.log"
    assert existing_fc_covers(path, "myapp_var_lib_t", baseline)

    redundant_line = (
        r"/var/lib/myapp/data\.log    gen_context(system_u:object_r:myapp_var_lib_t,s0)"
    )
    kept, dropped = filter_fc_fix_lines(baseline, [redundant_line], {redundant_line: path})
    assert not kept
    assert dropped == [redundant_line]

    bloated = baseline.rstrip() + "\n" + redundant_line + "\n"
    trimmed = strip_redundant_fc_lines(baseline, bloated)
    assert redundant_line not in trimmed
    assert "/var/lib/myapp(/.*)?" in trimmed


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="SELinux demo smoke tests")
    parser.add_argument(
        "--require-backend",
        action="store_true",
        default=os.environ.get("SMOKE_REQUIRE_BACKEND", "1") != "0",
        help="Fail if Tier 6 backend stub is not healthy (default: true)",
    )
    parser.add_argument(
        "--no-require-backend",
        action="store_true",
        help="Skip backend health requirement in flask_endpoints test",
    )
    args = parser.parse_args()
    require_backend = args.require_backend and not args.no_require_backend

    tests = [
        ("prompts", test_prompts),
        ("avc_parsing", test_avc_parsing),
        ("perm_merge", test_perm_merge),
        ("type_extraction_dedup", test_type_extraction_dedup),
        ("subtract_existing", test_subtract_existing),
        ("net_new_detection", test_net_new_detection),
        ("preprocess_stats", test_preprocess_stats),
        ("prompt_uses_summary", test_prompt_uses_summary),
        ("no_changes_needed_summary", test_no_changes_needed_summary),
        ("pr_summary_split_and_validate", test_pr_summary_split_and_validate),
        ("policy_json_validation", test_policy_json_validation),
        ("version_bump", test_version_bump),
        ("flask_endpoints", lambda: test_flask_endpoints(require_backend=require_backend)),
        ("assemble_pr_body_policy_diff_section", test_assemble_pr_body_policy_diff_section),
        ("assemble_pr_body", test_assemble_pr_body),
        ("verify_file_contexts_skip", test_verify_file_contexts_skip),
        ("check_soak_ready_gate", test_check_soak_ready_gate),
        ("monitor_avc_skip", test_monitor_avc_skip),
        ("soak_net_new_empty_manifest", test_soak_net_new_empty_manifest),
        ("demo_present_help", test_demo_present_help),
        ("app_manifest", test_app_manifest),
        ("rpm_ops_parity", test_rpm_ops_parity),
        ("version_consistency", test_version_consistency),
        ("version_consistency_fails_on_drift", test_version_consistency_fails_on_drift),
        ("version_consistency_fails_on_payments_drift", test_version_consistency_fails_on_payments_drift),
        ("scaffold_billing_no_myapp_leak", test_scaffold_billing_no_myapp_leak),
        ("deterministic_payments_manifest_check", test_deterministic_payments_manifest_check),
        ("promote_policy_version_from_te", test_promote_policy_version_from_te),
        ("classify_fail_closed_json", test_classify_fail_closed_json),
        ("check_soak_auto_tier_fail_closed", test_check_soak_auto_tier_fail_closed),
        ("skip_ai_fixture_sync", test_skip_ai_fixture_sync),
        ("deterministic_verdict_fixture_coverage", test_deterministic_verdict_fixture_coverage),
        ("deterministic_fixture_classify", test_deterministic_fixture_classify),
        ("payments_onboarding_module", test_payments_onboarding_module),
        ("selinux_build_image_internal_registry", test_selinux_build_image_internal_registry),
        ("single_ensure_selinux_build_image", test_single_ensure_selinux_build_image_definition),
        ("export_app_avcs_requires_paths", test_export_app_avcs_requires_paths),
        ("boolean_policy_render", test_boolean_policy_render),
        ("boolean_triage_two_matches", test_boolean_triage_two_matches),
        ("boolean_curated_when_policy_unavailable", test_boolean_curated_when_policy_unavailable),
        ("boolean_hint_yaml_still_documents_patterns", test_boolean_hint_yaml_still_documents_patterns),
        ("fc_labeling_drift_detection", test_fc_labeling_drift_detection),
    ]
    if os.environ.get("SMOKE_SKIP_FLASK") == "1":
        tests = [t for t in tests if t[0] != "flask_endpoints"]
    for name, fn in tests:
        fn()
        print(f"PASS {name}")
    print(f"\n{len(tests)}/{len(tests)} smoke tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
