#!/usr/bin/env bash
#
# run_blast_radius_fixtures.sh — CI + local gate for classify_policy_blast_radius.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_ROOT="${PROJECT_ROOT}/tests/fixtures/blast_radius"
CLASSIFY="${PROJECT_ROOT}/scripts/classify_policy_blast_radius.sh"
COMMON="${FIXTURE_ROOT}/_common"

run_python_branch_tests() {
    python3 - <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path("scripts/lib")))
from blast_radius_classify import classify_added_rules

cases = [
    (["allow myapp_t myapp_var_lib_t:dir search;"], "low", 1),
    (["allow myapp_t dns_port_t:udp_socket name_connect;"], "medium", 3),
    (["allow myapp_t bin_t:file execute;"], "high", 7),
    (["type_transition myapp_t myapp_exec_t:process myapp_t;"], "high", 7),
    (["allow myapp_t myapp_exec_t:file entrypoint;"], "high", 7),
]
for lines, tier, days in cases:
    out = classify_added_rules(lines)
    assert out["tier"] == tier, (lines, out)
    assert out["min_days"] == days, (lines, out)
print("branch_tests OK")
PY
}

run_fixture() {
    local name="$1"
    local dir="${FIXTURE_ROOT}/${name}"
    local work
    work="$(mktemp -d)"
    mkdir -p "${work}/base" "${work}/cand"
    cp "${COMMON}/base.te" "${work}/base/myapp.te"
    cp "${COMMON}/base.fc" "${work}/base/myapp.fc"
    cp "${dir}/cand.te" "${work}/cand/myapp.te"
    cp "${COMMON}/base.fc" "${work}/cand/myapp.fc"

    local out expected
    out="$(mktemp)"
    expected="${dir}/expected.json"
    if ! bash "${CLASSIFY}" "${work}/base/myapp.te" "${work}/cand/myapp.te" >"${out}" 2>"${work}/err.log"; then
        echo "blast_radius fixture ${name}: classify exited non-zero" >&2
        cat "${work}/err.log" >&2
        rm -rf "${work}" "${out}"
        return 1
    fi
    python3 - "${out}" "${expected}" <<'PY'
import json, sys
got = json.load(open(sys.argv[1], encoding="utf-8"))
exp = json.load(open(sys.argv[2], encoding="utf-8"))
for key in ("tier", "min_days"):
    if got.get(key) != exp.get(key):
        raise SystemExit(f"mismatch {key}: got {got.get(key)!r} expected {exp.get(key)!r}\nfull={got}")
print(f"fixture OK tier={got['tier']} min_days={got['min_days']} reason={got.get('reason','')[:80]}")
PY
    rm -rf "${work}" "${out}"
}

run_fail_closed_corrupt() {
    local work out
    work="$(mktemp -d)"
    out="$(mktemp)"
    printf 'not-a-policy' > "${work}/base.pp"
    printf 'not-a-policy' > "${work}/cand.pp"
    bash "${CLASSIFY}" "${work}/base.pp" "${work}/cand.pp" >"${out}"
    python3 - "${out}" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["min_days"] == 7, p
assert p["tier"] == "high", p
print("fail_closed_corrupt OK")
PY
    rm -rf "${work}" "${out}"
}

cd "${PROJECT_ROOT}"
run_python_branch_tests

for name in low_private_type medium_interface high_base_type high_entrypoint; do
    run_fixture "${name}"
done

run_fail_closed_corrupt
echo "All blast_radius fixtures passed"
