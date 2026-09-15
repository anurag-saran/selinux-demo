#!/usr/bin/env bash
# demo_prep_talk.sh — presenter talk track for run_demo_prep.sh (source only)
set -euo pipefail

demop_role_app() {
    echo -e "${TLAB_DIM}Role:${TLAB_NC} Application team"
    echo
}

demop_role_admin() {
    echo -e "${TLAB_DIM}Role:${TLAB_NC} Security / RHEL admin"
    echo
}

demop_plain() {
    echo -e "${TLAB_YELLOW}In plain English:${TLAB_NC} $*"
    echo
}

demop_say() {
    echo -e "${TLAB_BOLD}Say to the audience:${TLAB_NC}"
    echo "  \"$*\""
    echo
}

demop_show_heading() {
    echo -e "${TLAB_DIM}Show on screen (typed for you):${TLAB_NC}"
    echo
}

demop_run_local() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    bash -lc "${cmd}"
}

demop_preamble() {
    local act="$1"
    tlab_print_section "Workshop Act ${act} — presenter notes"
    case "${act}" in
        1)
            demop_role_app
            demop_plain "Install the app, keep the OS Enforcing, put myapp_t in permissive mode, and hit all integration endpoints."
            demop_say "SSH, systemd, and everything else stay enforcing — only our app domain is log-only so we can collect accurate AVC evidence without blocking the demo."
            ;;
        2)
            demop_role_app
            demop_plain "Copy myapp-related denial lines from the audit log into policy_out/avc.log for the policy generator."
            demop_say "Every line here is myapp evidence from our tests — not SSH or cron denials from the rest of the server."
            ;;
        3)
            demop_role_app
            demop_plain "The CLI merges AVCs, subtracts what is already in selinux/myapp.te, and proposes net-new allows."
            demop_say "Policy is merged into the existing module — not replaced blindly. CI will reject wildcards and allows to shadow_t, unconfined_t, sysadm_t."
            ;;
        4)
            demop_role_app
            demop_plain "Assemble the GitHub PR body admins actually review — summary, AVC excerpt, access delta."
            demop_say "Developers do not paste free-form text — the pipeline assembles what admins need to sign off, including AVC excerpts and a rule-level diff against the merge base."
            ;;
        5)
            demop_role_app
            demop_plain "Run the same compile and forbidden-pattern gates as GitHub Actions before merge."
            demop_say "Admins should not review syntax errors — CI catches those before merge."
            ;;
        6)
            demop_role_admin
            demop_plain "Install the full policy module on the host but keep myapp_t permissive for canary soak."
            demop_say "We deploy the real module early, but we do not enforce until we have watched production-like workloads for a full business cycle."
            ;;
        7)
            demop_role_admin
            demop_plain "Verify file labels match policy and scan for new AVCs before enforce."
            demop_say "The most common production surprise is wrong file labels on existing data — we verify before restart."
            ;;
        8)
            demop_role_admin
            demop_plain "Production waits 7–14 real days after canary; demo prep simulates an completed soak with a pre-seeded marker."
            demop_say "In production we wait a full business cycle so weekly cron and logrotate fire. Demo mode only skips the calendar — permissive semantics are real."
            demop_say "Before this act, tell the audience: demo prep skips the calendar wait only; everything else is real SELinux and real policy."
            ;;
        9)
            demop_role_admin
            demop_plain "Remove permissive mode — missing permissions now block the app."
            demop_say "After enforce, any missing permission becomes a hard denial — that is why soak and monitoring matter."
            ;;
        10)
            demop_role_admin
            demop_plain "Walk through the outage playbook — commands are shown, not executed, in the workshop."
            demop_say "If enforce causes an outage, the first move is permissive domain — not disabling SELinux globally."
            ;;
        *)
            ;;
    esac
}

demop_show_screen() {
    local act="$1"
    local po="${PROJECT_ROOT}/policy_out"
    case "${act}" in
        1)
            demop_show_heading
            tlab_run_cmd "getenforce"
            tlab_semanage_permissive_list
            tlab_run_cmd "curl -sf http://127.0.0.1:8888/save-log | head -c 160; echo"
            ;;
        2)
            demop_show_heading
            demop_run_local "wc -l '${po}/avc.log' 2>/dev/null || echo '(avc.log not on this host yet — check VM export)'"
            demop_run_local "head -1 '${po}/avc.log' 2>/dev/null | cut -c1-200 || true"
            ;;
        3)
            demop_show_heading
            demop_run_local "head -25 '${po}/pr_summary.md' 2>/dev/null || head -25 '${po}/${APP_NAME:-myapp}.te' 2>/dev/null || true"
            ;;
        4)
            demop_show_heading
            demop_run_local "grep -E 'Policy access delta|Policy diff skipped|Network Bindings|forbidden-patterns' '${po}/pr_body.md' 2>/dev/null | head -8 || true"
            demop_run_local "head -20 '${po}/pr_body.md' 2>/dev/null || true"
            ;;
        5)
            demop_show_heading
            demop_run_local "ls -la '${po}/${APP_NAME:-myapp}.pp' 2>/dev/null || ls -la '${po}/' | head -8"
            ;;
        6)
            demop_show_heading
            tlab_run_cmd "getenforce"
            tlab_semanage_permissive_list
            tlab_run_cmd "sudo semodule -l 2>/dev/null | grep -E '^${APP_NAME:-myapp}$' || semodule -l 2>/dev/null | grep myapp || true"
            tlab_run_cmd "curl -sf http://127.0.0.1:8888/notify-socket | head -c 120; echo"
            ;;
        7)
            demop_show_heading
            echo -e "${TLAB_DIM}(Guardrails ran in the act above — re-check services.)${TLAB_NC}"
            tlab_run_cmd "systemctl is-active myapp.service myapp-backend.service"
            ;;
        8)
            demop_show_heading
            tlab_run_cmd "ls -l ${VAR_DIR:-/var/lib/myapp}/selinux_canary_deployed_at 2>/dev/null || echo '(marker after canary in act 6)'"
            ;;
        9)
            demop_show_heading
            tlab_semanage_permissive_list
            tlab_run_cmd 'for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do curl -sf "http://127.0.0.1:8888${path}" >/dev/null && echo "OK ${path}"; done'
            tlab_run_cmd "cat ${VAR_DIR:-/var/lib/myapp}/selinux_deploy_report.json 2>/dev/null | head -c 200; echo"
            ;;
        10)
            demop_show_heading
            echo -e "${TLAB_DIM}Act 10 prints rollback commands in the log above — narrate those three steps.${TLAB_NC}"
            ;;
    esac
    tlab_checkpoint "Act ${act} talk track + demo step complete — ready for the next act."
}
