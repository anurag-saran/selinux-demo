#!/usr/bin/env bash
#
# post_pr_policy_diff_comment.sh — CI: post or update PR comment with policy access delta.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_NAME="${POLICY_APP:-myapp}"
MARKER="<!-- selinux-policy-module-diff -->"

[[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_EVENT_PATH:-}" ]] || {
    echo "post_pr_policy_diff_comment: requires GitHub Actions context" >&2
    exit 1
}

PR_NUM="$(python3 - "${GITHUB_EVENT_PATH}" <<'PY'
import json, sys
ev = json.load(open(sys.argv[1], encoding="utf-8"))
print(ev["pull_request"]["number"])
PY
)"

diff_body="$(mktemp)"
comment_file="$(mktemp)"
payload_file="$(mktemp)"
trap 'rm -f "${diff_body}" "${comment_file}" "${payload_file}"' EXIT

bash "${PROJECT_ROOT}/scripts/lib/policy_module_diff.sh" \
    --app-name "${APP_NAME}" \
    --from-merge-base \
    --cand-dir "${PROJECT_ROOT}/selinux" \
    --output "${diff_body}" \
    --format markdown

{
    printf '%s\n\n' "${MARKER}"
    cat "${diff_body}"
} > "${comment_file}"

existing_id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUM}/comments" \
    --jq ".[] | select(.body | startswith(\"${MARKER}\")) | .id" | head -1)"

if [[ -n "${existing_id}" ]]; then
    jq -n --rawfile body "${comment_file}" '{body: $body}' > "${payload_file}"
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" \
        --input "${payload_file}" >/dev/null
    echo "Updated policy diff comment ${existing_id} on PR #${PR_NUM}"
else
    gh pr comment "${PR_NUM}" --body-file "${comment_file}"
    echo "Created policy diff comment on PR #${PR_NUM}"
fi
