#!/usr/bin/env python3
"""agentSpawn hook for sql-migration-agent: prints a short migration status.

Kiro adds a hook's stdout to the agent's context when the session starts, so the
agent knows what is converted, what is pending and how the last test run went.
Reads (never writes): source/*.sql, generated/*.sql, metadata/migration_log.json.
Exits 0 even when files are missing, so a broken workspace never blocks the agent.
"""
import json
import pathlib
import re
import sys

for _s in (sys.stdout, sys.stderr):  # UTF-8 output on Windows pipes
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

root = pathlib.Path.cwd()
src_dir, gen_dir = root / "source", root / "generated"
log_path = root / "metadata" / "migration_log.json"

try:
    log = json.loads(log_path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    log = {}

logged = {f.get("source_file") for f in log.get("files", [])}
sources = sorted(p for p in src_dir.glob("*.sql")) if src_dir.exists() else []

print("## Migration status (from .kiro/agents/hooks/migration_status.py)")
pending = []
for src in sources:
    rel = src.relative_to(root).as_posix()
    procs = re.findall(r"CREATE\s+(?:OR\s+ALTER\s+)?(?:PROCEDURE|PROC|FUNCTION|TRIGGER)\s+([\[\]\w.]+)",
                       src.read_text(encoding="utf-8", errors="replace"), re.I)
    state = "converted" if rel in logged else "PENDING"
    if state == "PENDING":
        pending.append(rel)
    print(f"- {rel}: {state} ({len(procs)} object(s))")

flags = [p for f in log.get("files", []) for p in f.get("procedures", []) if p.get("manual_review")]
print(f"- pending files: {len(pending)}" + (f" → {', '.join(pending)}" if pending else ""))
print(f"- manual-review flags open: {len(flags)}")
run = log.get("last_test_run")
if run:
    print(f"- last test run {run.get('date')}: {run.get('passed')} passed, "
          f"{run.get('failed')} failed, {run.get('errors')} errors ({run.get('result')})")
if gen_dir.exists():
    print(f"- generated files: {', '.join(sorted(p.name for p in gen_dir.glob('*.sql')))}")
