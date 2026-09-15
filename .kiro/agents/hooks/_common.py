"""Shared helpers for the sql-migration-agent hooks (stdin JSON → decision + audit record)."""
import json
import os
import pathlib
import sys

_HOOK_ROOT = pathlib.Path(__file__).resolve().parents[3]    # .kiro/agents/hooks/_common.py → workspace
ROOT = pathlib.Path(os.environ.get("MIGRATION_WORKSPACE_ROOT") or _HOOK_ROOT).resolve()
sys.path.insert(0, str(_HOOK_ROOT / ".kiro" / "skills" / "sql-conversion" / "scripts"))

from migkit.audit import AuditLogger, session_file, new_run_id, redact  # noqa: E402
from migkit import security  # noqa: E402
from migkit.platform_compat import utf8_stdio, detach_kwargs  # noqa: E402


def read_event() -> dict:
    # bytes: Kiro sends UTF-8 JSON; Windows would decode a pipe with the ANSI code page
    raw = sys.stdin.buffer.read().decode("utf-8", errors="replace") if not sys.stdin.isatty() else ""
    try:
        ev = json.loads(raw) if raw.strip() else {}
    except ValueError:
        ev = {"_unparsed": raw[:500]}
    return ev if isinstance(ev, dict) else {"_unparsed": str(ev)[:500]}


def logger(service: str) -> AuditLogger:
    os.environ.setdefault("MIGRATION_LOG_DIR", str(ROOT / "logs" / "audit"))
    return AuditLogger(service)


def summarize_input(tool_input) -> dict:
    """Redacted, length-capped view of a tool input for the audit log (never file contents)."""
    if not isinstance(tool_input, dict):
        return {"value": redact(str(tool_input))[:500]}
    out = {}
    for k, v in tool_input.items():
        if k in ("file_text", "new_str", "old_str", "content", "text") and isinstance(v, str):
            out[k] = {"chars": len(v), "sha256": __import__("hashlib").sha256(v.encode("utf-8")).hexdigest()}
        else:
            out[k] = redact(v if not isinstance(v, str) else v[:1000], k)
    return out
