"""
policy_rules.py — Shared house rules for deterministic generation and CI alignment.
"""

from __future__ import annotations

# High-privilege / sensitive targets (align with validate_forbidden_patterns.sh)
FORBIDDEN_TARGET_TYPES = frozenset(
    {
        "shadow_t",
        "unconfined_t",
        "sysadm_t",
        "security_t",
        "selinux_config_t",
        "passwd_file_t",
    }
)

GENERIC_FILE_TYPES = frozenset(
    {
        "var_t",
        "var_lib_t",
        "var_log_t",
        "var_run_t",
        "usr_t",
        "etc_t",
        "tmp_t",
        "default_t",
        "unlabeled_t",
    }
)

GENERIC_PORT_TYPES = frozenset(
    {
        "unreserved_port_t",
        "port_t",
        "reserved_port_t",
        "ephemeral_port_t",
    }
)

PATTERN_MACROS: list[tuple[frozenset[str], str]] = [
    (
        frozenset(
            {
                "create",
                "write",
                "unlink",
                "rename",
                "setattr",
                "append",
                "read",
                "open",
                "getattr",
            }
        ),
        "manage_files_pattern",
    ),
    (
        frozenset(
            {
                "create",
                "write",
                "add_name",
                "remove_name",
                "rmdir",
                "search",
                "read",
                "open",
                "getattr",
            }
        ),
        "manage_dirs_pattern",
    ),
    (
        frozenset({"read", "open", "getattr", "lock", "ioctl"}),
        "read_files_pattern",
    ),
    (
        frozenset({"search", "read", "open", "getattr"}),
        "list_dirs_pattern",
    ),
]

VERDICT_FC = "fc_fix"
VERDICT_FC_DRIFT = "fc_drift"
VERDICT_PORT = "private_port"
VERDICT_FORBIDDEN = "forbidden"
VERDICT_BASELINE = "baseline"
VERDICT_INTERFACE = "interface"
VERDICT_DIRECT = "direct"
VERDICT_TOOLCHAIN = "toolchain_required"
VERDICT_BOOLEAN = "boolean"

# What the author should do next (not a live host patch).
NEXT_ACTION = {
    VERDICT_FC: "update_fc_and_restorecon",
    VERDICT_FC_DRIFT: "update_fc_and_restorecon",
    VERDICT_PORT: "add_manifest_port",
    VERDICT_BOOLEAN: "setsebool_host",
    VERDICT_DIRECT: "update_te_allow",
    VERDICT_INTERFACE: "update_te_allow",
    VERDICT_FORBIDDEN: "refuse",
    VERDICT_TOOLCHAIN: "install_sepolgen",
    VERDICT_BASELINE: "",
}
