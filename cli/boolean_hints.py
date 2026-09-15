"""Match AVC access needs against curated boolean hints (offline triage)."""

from __future__ import annotations

from pathlib import Path

import yaml

from avc_preprocess import AccessNeed

DEFAULT_HINTS_PATH = Path(__file__).resolve().parent.parent / "config" / "boolean_hints.yml"


def load_boolean_hints(path: Path | None = None) -> list[dict]:
    hint_path = path or DEFAULT_HINTS_PATH
    if not hint_path.is_file():
        return []
    data = yaml.safe_load(hint_path.read_text(encoding="utf-8")) or {}
    hints = data.get("hints")
    return hints if isinstance(hints, list) else []


def match_boolean_hint(need: AccessNeed, hints: list[dict]) -> tuple[str, str, str] | None:
    """Return (boolean_name, rendered_setsebool, note) when a hint matches."""
    for row in hints:
        if not isinstance(row, dict):
            continue
        match = row.get("match")
        if not isinstance(match, dict):
            continue
        if match.get("src_type") and match["src_type"] != need.src_type:
            continue
        if match.get("tgt_type") and match["tgt_type"] != need.tgt_type:
            continue
        if match.get("tclass") and match["tclass"] != need.tclass:
            continue
        required = match.get("perms") or []
        if required:
            required_set = frozenset(str(p) for p in required)
            if not required_set <= need.perms:
                continue
        boolean = str(row.get("boolean") or "").strip()
        if not boolean:
            continue
        note = str(row.get("note") or f"Toggle boolean {boolean} instead of adding allow rules.")
        rendered = f"setsebool -P {boolean} on"
        return boolean, rendered, note
    return None
