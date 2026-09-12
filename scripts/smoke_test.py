#!/usr/bin/env python3
"""Local smoke tests (no SELinux/Podman required for most)."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "cli"))

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


def test_policy_json_validation() -> None:
    payload = {
        "module_name": "myapp",
        "te_content": "policy_module(myapp, 1.0.0)\ntype myapp_t;\n",
        "fc_content": (
            "/opt/myapp/app\\.py -- gen_context(system_u:object_r:myapp_exec_t,s0)\n"
            "/var/myapp(/.*)? -- gen_context(system_u:object_r:myapp_var_lib_t,s0)\n"
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


def test_flask_endpoints() -> None:
    tmp = Path(tempfile.mkdtemp(prefix="myapp-smoke-"))
    bin_dir = tmp / "bin"
    var_dir = tmp / "var"
    bin_dir.mkdir()
    var_dir.mkdir()

    app_src = (PROJECT_ROOT / "app" / "app.py").read_text(encoding="utf-8")
    app_src = app_src.replace("/var/myapp", str(var_dir))
    app_src = app_src.replace("/opt/myapp/bin/backup.sh", str(bin_dir / "backup.sh"))
    app_path = tmp / "app.py"
    app_path.write_text(app_src, encoding="utf-8")

    backup_src = (PROJECT_ROOT / "app" / "backup.sh").read_text(encoding="utf-8")
    backup_src = backup_src.replace("/var/myapp", str(var_dir))
    backup_path = bin_dir / "backup.sh"
    backup_path.write_text(backup_src, encoding="utf-8")
    backup_path.chmod(0o755)

    proc = subprocess.Popen([sys.executable, str(app_path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(30):
            try:
                with urllib.request.urlopen("http://127.0.0.1:8888/", timeout=1) as resp:
                    assert resp.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.2)
        else:
            raise AssertionError("Flask app did not become healthy")

        for path in ("/", "/save-log", "/run-script", "/rotate-log"):
            with urllib.request.urlopen(f"http://127.0.0.1:8888{path}", timeout=3) as resp:
                body = resp.read().decode("utf-8")
                assert resp.status == 200
                assert "ok" in body
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_assemble_pr_body() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        pr_summary = Path(tmp) / "pr_summary.md"
        pr_summary.write_text(
            "### Network Bindings\n- Port 8888 via unreserved_port_t\n\n"
            "### File System Access\n- /var/myapp data dir\n\n"
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
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert old.returncode == 0, old.stderr


def test_monitor_avc_skip() -> None:
    script = PROJECT_ROOT / "scripts" / "monitor_avc.sh"
    result = subprocess.run(
        ["bash", str(script), "--skip-if-unavailable", "--max-avc", "-1"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


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


def main() -> int:
    tests = [
        ("prompts", test_prompts),
        ("avc_parsing", test_avc_parsing),
        ("policy_json_validation", test_policy_json_validation),
        ("version_bump", test_version_bump),
        ("flask_endpoints", test_flask_endpoints),
        ("assemble_pr_body", test_assemble_pr_body),
        ("verify_file_contexts_skip", test_verify_file_contexts_skip),
        ("check_soak_ready_gate", test_check_soak_ready_gate),
        ("monitor_avc_skip", test_monitor_avc_skip),
        ("demo_present_help", test_demo_present_help),
    ]
    for name, fn in tests:
        fn()
        print(f"PASS {name}")
    print(f"\n{len(tests)}/{len(tests)} smoke tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
