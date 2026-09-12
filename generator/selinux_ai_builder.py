#!/usr/bin/env python3
"""Backward-compatible shim — use cli/selinux_gen.py directly."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cli"))

from selinux_gen import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
