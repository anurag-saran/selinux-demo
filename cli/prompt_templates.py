"""
Prompt templates for AI-driven SELinux Policy-as-Code generation.
"""

from __future__ import annotations

POLICY_JSON_SCHEMA = {
    "module_name": "myapp",
    "te_content": "raw .te policy source",
    "fc_content": "raw .fc file contexts source",
    "rationale": "brief explanation of allow rules",
    "pr_summary": "<markdown PR body section with required headings listed below>"
}

SYSTEM_PROMPT = """You are an expert SELinux policy author for Shift-Left Policy-as-Code workflows.

OUTPUT FORMAT (CRITICAL):
- Respond with ONLY valid JSON. No markdown fences outside JSON values.
- Schema:
{
  "module_name": "myapp",
  "te_content": "<complete compilable .te file>",
  "fc_content": "<complete .fc file>",
  "rationale": "<brief technical explanation>",
  "pr_summary": "<markdown for PR body — MUST include these exact headings:\\n### Network Bindings\\n### File System Access\\n### Process Execution\\n### Explicit Denials Maintained>"
}

POLICY SYNTAX (CRITICAL — compilation will fail otherwise):
1. Use policy_module(myapp, MAJOR.MINOR.PATCH) at the top — NEVER bare `module myapp 1.0.1;`
2. Declare NEW types OUTSIDE require blocks: `type myapp_t;` then `require { type init_t; ... }`
3. NEVER put `type myapp_t` inside require { } — require lists EXISTING base-policy types only
4. Do NOT use m4 macros unless standard: init_daemon_domain, files_type, domain_auto_trans,
   corenet_tcp_bind_all_unreserved_ports. Do NOT use logging_send_syslog() — use explicit
   `allow myapp_t syslogd_t:unix_stream_socket connectto;`
5. Extend existing policy incrementally; preserve custom types: myapp_t, myapp_exec_t,
   myapp_var_lib_t, myapp_script_exec_t

LEAST PRIVILEGE:
- Grant ONLY permissions required by supplied AVC denials
- Add allow rules ONLY for rows under "Net-new access needs" in the user prompt
- Do NOT duplicate rules already listed under "Already covered by existing policy"
- Map each net-new row to one minimal allow rule (or extend an existing allow block)
- FORBIDDEN: allow myapp_t *:* * *; allow myapp_t self:* *; wildcard object types

REQUIRED PATTERNS (when AVCs indicate need):
- init_daemon_domain(myapp_t, myapp_exec_t) for systemd
- files_type() for file object types
- myapp_var_lib_t dir/file rules for /var/myapp (write, create, rename for logrotate)
- domain_auto_trans for /opt/myapp/bin/backup.sh execution
- tcp_socket name_bind for port 8888 via unreserved_port_t (NOT port_t):
  `allow myapp_t unreserved_port_t:tcp_socket name_bind;`
- HTTP serving needs read/write on accepted sockets:
  `allow myapp_t self:tcp_socket { create bind listen accept read write ... };`
- logrotate may need: dir { rmdir rename unlink write remove_name }; file { rename unlink }

PR_SUMMARY FORMAT (pr_summary field — required headings):
### Network Bindings
- Bullet list: ports, socket classes (use unreserved_port_t for 8888)

### File System Access
- Bullet list: paths and custom types (_var_lib_t, _exec_t, etc.)

### Process Execution
- Bullet list: scripts, transitions, helper domains

### Explicit Denials Maintained
- Bullet list: no shadow_t, unconfined_t, sysadm_t, wildcard allows, broad var_t write

FILE CONTEXTS (fc_content) — include FCOS /var/opt symlink paths:
/opt/myapp/app\\.py                    -- gen_context(system_u:object_r:myapp_exec_t,s0)
/opt/myapp/bin/.*                     -- gen_context(system_u:object_r:myapp_script_exec_t,s0)
/opt/myapp/venv(/.*)?                 -- gen_context(system_u:object_r:myapp_exec_t,s0)
/var/opt/myapp/app\\.py                -- gen_context(system_u:object_r:myapp_exec_t,s0)
/var/opt/myapp/bin/.*                 -- gen_context(system_u:object_r:myapp_script_exec_t,s0)
/var/opt/myapp/venv(/.*)?             -- gen_context(system_u:object_r:myapp_exec_t,s0)
/var/myapp(/.*)?                      -- gen_context(system_u:object_r:myapp_var_lib_t,s0)
/var/opt/myapp(/.*)?                  -- gen_context(system_u:object_r:myapp_var_lib_t,s0)
"""

USER_PROMPT_TEMPLATE = """Update the SELinux policy module for this application.

## Application Context
- Service: Order Processor App (Flask, systemd unit myapp.service)
- Domain: {domain}
- User: myapp
- Install: /opt/myapp (venv at /opt/myapp/venv)
- Data: /var/myapp
- Script: /opt/myapp/bin/backup.sh
- Listen: 0.0.0.0:8888

## Endpoints / triggers
- GET /save-log — append /var/myapp/data.log
- GET /run-script — execute backup.sh
- GET /rotate-log — simulate logrotate (rename/create under /var/myapp)
- Process start — bind TCP 8888

## Target module version
policy_module({app_name}, {version})

## Existing Type Enforcement (extend, do not discard types)
```te
{existing_te}
```

## Existing File Contexts
```fc
{existing_fc}
```

## Access needs derived from AVCs
{avc_logs}

Use the structured tables above:
- **Net-new access needs** — add or extend allow rules for these permissions only
- **Already covered** — confirm existing policy; do not duplicate these allows
- If stats show no_changes_needed, return existing te_content unchanged with minimal rationale
- If stats show fallback_merged, treat all merged rows as candidates but still avoid duplicating existing .te rules

Produce JSON with updated te_content (full file, version {version}), fc_content, rationale, and pr_summary markdown."""

FIX_PROMPT_TEMPLATE = """The SELinux policy below failed compilation.

## Compiler error
```
{compile_error}
```

## Current te_content
```te
{te_content}
```

Fix syntax ONLY. Return JSON with corrected te_content, fc_content (unchanged unless needed), rationale, pr_summary.
Use policy_module({app_name}, {version}). Declare types OUTSIDE require blocks. No invalid macros."""


def build_user_prompt(
    domain: str,
    avc_logs: str,
    *,
    app_name: str,
    version: str,
    existing_te: str,
    existing_fc: str,
) -> str:
    if not avc_logs.strip():
        avc_logs = "(No AVC lines — infer minimal allows from application context above.)"
    return USER_PROMPT_TEMPLATE.format(
        domain=domain,
        app_name=app_name,
        version=version,
        existing_te=existing_te.strip() or "(none)",
        existing_fc=existing_fc.strip() or "(none)",
        avc_logs=avc_logs.strip(),
    )


def build_fix_prompt(
    te_content: str,
    compile_error: str,
    *,
    app_name: str,
    version: str,
) -> str:
    return FIX_PROMPT_TEMPLATE.format(
        te_content=te_content,
        compile_error=compile_error.strip(),
        app_name=app_name,
        version=version,
    )
