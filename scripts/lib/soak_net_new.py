#!/usr/bin/env python3
"""Ops RPM entry point for net-new AVC analysis (repo checkout or libexec install)."""

from __future__ import annotations

import sys
from pathlib import Path

_LIB = Path(__file__).resolve().parent
_REPO_CLI = _LIB.parents[1] / "cli"
_PAC_CLI = _LIB / "pac_cli"
for candidate in (_REPO_CLI, _PAC_CLI):
    if candidate.is_dir():
        sys.path.insert(0, str(candidate))

from soak_net_new import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
