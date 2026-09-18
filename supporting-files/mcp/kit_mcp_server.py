#!/usr/bin/env python3
"""
kit_mcp_server.py — PLACEHOLDER / PREVIEW: exposes the kit's skill tools as an MCP server (stdio, JSON-RPC 2.0,
newline-delimited messages) so other agents and IDEs can call them. Standard library only.

  python3 supporting-files/mcp/kit_mcp_server.py            # serve on stdin/stdout (register in .kiro/settings/mcp.json, disabled by default)
  python3 supporting-files/mcp/kit_mcp_server.py --list     # print the tool catalog and exit

Tools (read-only or dry-run; every call is audited under the run id and refused outside the workspace):
  assess_object      migration-assessment: classify one SQL file (consumer, target)
  check_sql          redshift / iceberg / report checks on one converted file
  compare_schemas    schema-conformance: compare two snapshots (profile)
  toolbox            sql-reporting: dialect rows for a need on a target
  audit_tail         what one run did
Not exposed on purpose: anything that writes to a target, applies patches, injects XML or runs on a database.
Roadmap: package the server (uvx), per-tool schemas generated from the CLIs, resources for catalogs, prompts for intake questions.
"""
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(os.environ.get("MIGRATION_WORKSPACE_ROOT") or pathlib.Path(__file__).resolve().parents[2]).resolve()
sys.path.insert(0, str(ROOT / ".kiro" / "skills" / "sql-conversion" / "scripts"))
from migkit.audit import AuditLogger  # noqa: E402

SERVER_VERSION = "0.1.0-preview"
PROTOCOL = "2025-06-18"
LOG = AuditLogger("kit_mcp_server")
PY = sys.executable
SK = ".kiro/skills"
TOOLS = {
    "assess_object": {"description": "Classify one SQL Server object: construct inventory, role (M2RVE), complexity, target candidates with blockers, recommended skill (migration-assessment). Read-only.",
                      "inputSchema": {"type": "object", "properties": {"path": {"type": "string", "description": "workspace-relative .sql file or folder"}, "consumer": {"type": "string", "enum": ["app", "api", "bi", "etl", "unknown"]},
                                                                       "target": {"type": "string", "enum": ["AuroraPostgreSQL", "Redshift", "Iceberg", "TBD"]}}, "required": ["path"]},
                      "argv": lambda a: [f"{SK}/migration-assessment/scripts/assess_tool.py", "assess", a["path"], "--consumer", a.get("consumer", "unknown"), "--target", a.get("target", "TBD"), "--json"]},
    "check_sql": {"description": "Static check of one converted file: target 'redshift' (RS rules), 'athena'/'spark' (IB rules) or 'report:<postgres|redshift|athena|spark>' (reporting dialect rules). Read-only.",
                  "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "target": {"type": "string", "enum": ["redshift", "athena", "spark", "report:postgres", "report:redshift", "report:athena", "report:spark"]}}, "required": ["path", "target"]},
                  "argv": lambda a: ([f"{SK}/sql-conversion-redshift/scripts/redshift_tool.py", "check", a["path"], "--json"] if a["target"] == "redshift" else
                                     [f"{SK}/sql-conversion-iceberg/scripts/iceberg_tool.py", "check", a["path"], "--dialect", a["target"], "--json"] if a["target"] in ("athena", "spark") else
                                     [f"{SK}/sql-reporting/scripts/report_tool.py", "check", a["path"], "--target", a["target"].split(":", 1)[1], "--json"])},
    "compare_schemas": {"description": "Compare two schema snapshots (schema-conformance): EXACT / APPROVED_TRANSFORM / MISSING_* / CONFLICT / UNVERIFIED per column. Read-only; writes compare.json/compare.md under generated/schema/.",
                        "inputSchema": {"type": "object", "properties": {"source": {"type": "string"}, "target": {"type": "string"}, "profile": {"type": "string", "enum": ["aurora", "redshift", "iceberg"]}}, "required": ["source", "target", "profile"]},
                        "argv": lambda a: [f"{SK}/schema-conformance/scripts/schema_tool.py", "compare", a["source"], a["target"], "--profile", a["profile"], "--out", "generated/schema/mcp-compare"]},
    "toolbox": {"description": "Reporting dialect rows (RD-nn) for a need on a target (sql-reporting).",
                "inputSchema": {"type": "object", "properties": {"target": {"type": "string", "enum": ["postgres", "redshift", "athena", "spark"]}, "need": {"type": "string"}}, "required": ["target"]},
                "argv": lambda a: [f"{SK}/sql-reporting/scripts/report_tool.py", "toolbox", "--target", a["target"]] + (["--need", a["need"]] if a.get("need") else [])},
    "audit_tail": {"description": "Everything one run did (hash-chained audit log).",
                   "inputSchema": {"type": "object", "properties": {"run": {"type": "string", "description": "first 8+ hex characters of the run id"}}, "required": ["run"]},
                   "argv": lambda a: [f"{SK}/sql-conversion/scripts/migkit/audit.py", "tail", "--run", a["run"]]},
}


class ToolError(Exception):
    pass


def _safe_path(p: str) -> str:
    if not isinstance(p, str) or not p or p.startswith(("/", "~")) or ".." in pathlib.PurePosixPath(p).parts or "\\" in p:
        raise ToolError(f"path must be workspace-relative without '..': {p!r}")
    if not (ROOT / p).exists():
        raise ToolError(f"not found in the workspace: {p}")
    return p


def call_tool(name: str, args: dict) -> dict:
    if name not in TOOLS:
        raise ToolError(f"unknown tool {name}")
    schema = TOOLS[name]["inputSchema"]
    for req in schema.get("required", []):
        if req not in args:
            raise ToolError(f"missing argument {req}")
    for k, v in args.items():
        prop = schema["properties"].get(k)
        if prop is None:
            raise ToolError(f"unexpected argument {k}")
        if "enum" in prop and v not in prop["enum"]:
            raise ToolError(f"{k} must be one of {prop['enum']}")
        if not isinstance(v, str) or len(v) > 512:
            raise ToolError(f"{k} must be a short string")
    for k in ("path", "source"):
        if k in args:
            _safe_path(args[k])
    if name == "compare_schemas":
        _safe_path(args["target"])
    if name == "audit_tail" and not all(c in "0123456789abcdef" for c in args["run"].lower()):
        raise ToolError("run must be hexadecimal")
    argv = [PY, *TOOLS[name]["argv"](args)]
    env = dict(os.environ, MIGRATION_INHERIT_SESSION="0")
    p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=300, env=env)
    LOG.log("mcp.tool", name, "INFO" if p.returncode in (0, 1) else "ERROR", tool=name, args={k: (v if k != "run" else v[:8]) for k, v in args.items()}, exit_code=p.returncode)
    text = (p.stdout or "") + (("\n" + p.stderr) if p.returncode not in (0, 1) and p.stderr else "")
    return {"content": [{"type": "text", "text": text[-20000:]}], "isError": p.returncode not in (0, 1), "_meta": {"exitCode": p.returncode, "runId": LOG.run_id}}


def handle(msg: dict):
    mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": PROTOCOL, "capabilities": {"tools": {"listChanged": False}},
                                                       "serverInfo": {"name": "sqlmigration-kit", "version": SERVER_VERSION}, "instructions": "Read-only and dry-run tools of the SQL migration kit. Paths are workspace-relative."}}
    if method == "notifications/initialized" or method.startswith("notifications/"):
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": n, "description": t["description"], "inputSchema": t["inputSchema"]} for n, t in TOOLS.items()]}}
    if method == "tools/call":
        try:
            return {"jsonrpc": "2.0", "id": mid, "result": call_tool(params.get("name", ""), params.get("arguments") or {})}
        except ToolError as ex:
            LOG.log("mcp.refused", str(ex), "WARN", tool=params.get("name"))
            return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": f"refused: {ex}"}], "isError": True}}
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}}


def serve(inp=sys.stdin, out=sys.stdout):
    LOG.log("mcp.start", SERVER_VERSION, root=str(ROOT))
    for line in inp:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            out.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}) + "\n"); out.flush(); continue
        resp = handle(msg)
        if resp is not None:
            out.write(json.dumps(resp, ensure_ascii=False) + "\n"); out.flush()


if __name__ == "__main__":
    if "--list" in sys.argv:
        for n, t in TOOLS.items():
            print(f"{n:<16} {t['description']}")
        sys.exit(0)
    serve()
