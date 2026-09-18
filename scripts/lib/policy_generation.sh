#!/usr/bin/env bash
# policy_generation.sh — Shared deterministic policy + optional LLM pr_summary (source only)
set -euo pipefail

run_write_avc_summary() {
    local avc_log="$1"
    local existing_te="$2"
    local out="${3:-${PROJECT_ROOT}/policy_out/avc_summary.txt}"
    local domain="${4:-${SELINUX_DOMAIN:-myapp_t}}"
    python3 - "${PROJECT_ROOT}" "${avc_log}" "${existing_te}" "${out}" "${domain}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "cli"))
from avc_preprocess import preprocess_avc_file

avc = Path(sys.argv[2])
te = Path(sys.argv[3]).read_text(encoding="utf-8")
out = Path(sys.argv[4])
domain = sys.argv[5]
summary, stats = preprocess_avc_file(avc, domain, existing_te=te)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(summary + "\n", encoding="utf-8")
print(f"Wrote {out} (raw={stats['raw']} merged={stats['merged']} net_new={stats['net_new']})")
PY
}

run_deterministic_policy_gen() {
    local avc_log="$1"
    local manifest="$2"
    local policy_te="$3"
    local policy_fc="$4"
    local policy_version_file="$5"
    local policy_out="$6"
    local app_name="$7"

    mkdir -p "${policy_out}"
    cp "${policy_version_file}" "${policy_out}/policy_version.txt"
    python3 "${PROJECT_ROOT}/cli/deterministic_gen.py" \
        --avc-log "${avc_log}" \
        --manifest "${manifest}" \
        --existing-te "${policy_te}" \
        --existing-fc "${policy_fc}" \
        --out-dir "${policy_out}" \
        --version-file "${policy_out}/policy_version.txt" \
        --bump-version \
        $( [[ "${POLICY_ALLOW_DEGRADED:-0}" == "1" ]] && echo --allow-degraded ) \
        $( [[ "${POLICY_ALLOW_NEEDS_REVIEW:-0}" == "1" ]] && echo --allow-needs-review )
    POLICY_MODULE="${app_name}" SELINUX_DOMAIN="${app_name}_t" \
        bash "${SCRIPT_DIR}/validate_forbidden_patterns.sh" "${policy_out}"
    POLICY_MODULE="${app_name}" SELINUX_DOMAIN="${app_name}_t" \
        bash "${SCRIPT_DIR}/compile_and_validate.sh" "${policy_out}"
    run_write_avc_summary "${avc_log}" "${policy_te}" "${policy_out}/avc_summary.txt"
}

run_llm_pr_summary_if_requested() {
    local policy_out="$1"
    local app_name="$2"
    if [[ "${LLM_SUMMARY:-0}" -ne 1 ]]; then
        return 0
    fi
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        echo "[WARN] LLM_SUMMARY requested but OPENAI_API_KEY unset — keeping template pr_summary.md" >&2
        return 0
    fi
    python3 "${PROJECT_ROOT}/cli/summarize_pr.py" \
        --template "${policy_out}/pr_summary.md" \
        --findings "${policy_out}/findings.json" \
        --avc-summary "${policy_out}/avc_summary.txt" \
        --out "${policy_out}/pr_summary.md" \
        --app-name "${app_name}"
}
