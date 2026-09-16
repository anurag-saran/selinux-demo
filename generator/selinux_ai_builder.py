#!/usr/bin/env python3
"""Backward-compatible shim — use dev_generate_policy.sh + summarize_pr.py instead."""

import sys
from pathlib import Path

if __name__ == "__main__":
    if "--legacy-full-policy" not in sys.argv:
        print(
            "selinux_ai_builder: use bash scripts/dev_generate_policy.sh "
            "(deterministic policy).\n"
            "Optional LLM: python3 cli/summarize_pr.py\n"
            "Legacy all-in-one LLM: python3 cli/selinux_gen.py --legacy-full-policy …",
            file=sys.stderr,
        )
        raise SystemExit(2)
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cli"))
    from selinux_gen import main  # noqa: E402

    raise SystemExit(main())
