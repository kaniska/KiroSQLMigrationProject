#!/usr/bin/env python3
"""Tests for the kit MCP server placeholder (MCP-nn, catalog supporting-files/mcp/README.md). Results → --results FILE."""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

if os.name == "nt" and not sys.flags.utf8_mode:
    import subprocess as _sp
    os.environ["PYTHONUTF8"] = "1"
    sys.exit(_sp.call([sys.executable, "-X", "utf8", *sys.argv]))

HERE = pathlib.Path(__file__).resolve().parent
SERVER = HERE.parent / "kit_mcp_server.py"
ROOT = HERE.parents[2]
_STATE = pathlib.Path(tempfile.mkdtemp(prefix="mcp-test-"))
ENV = dict(os.environ, MIGRATION_LOG_DIR=str(_STATE / "audit"), MIGRATION_STATE_DIR=str(_STATE / "state"), MIGRATION_OFFLINE="1", MIGRATION_RUN_ID="7ff7651916cd43dd8448eb211c803192")


def talk(messages: list) -> list:
    inp = "".join(json.dumps(m) + "\n" for m in messages)
    p = subprocess.run([sys.executable, str(SERVER)], input=inp, capture_output=True, text=True, cwd=ROOT, env=ENV, timeout=300)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip()]


class McpTests(unittest.TestCase):
    def test_protocol(self):
        """MCP-T01 initialize, initialized notification, ping, unknown method and bad JSON are handled per JSON-RPC [MCP-01]"""
        out = talk([{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
                    {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": 2, "method": "ping"}, {"jsonrpc": "2.0", "id": 3, "method": "resources/list"}])
        self.assertEqual(len(out), 3)
        self.assertEqual(out[0]["result"]["serverInfo"]["name"], "sqlmigration-kit"); self.assertIn("tools", out[0]["result"]["capabilities"]); self.assertTrue(out[0]["result"]["protocolVersion"])
        self.assertEqual(out[1], {"jsonrpc": "2.0", "id": 2, "result": {}}); self.assertEqual(out[2]["error"]["code"], -32601)
        p = subprocess.run([sys.executable, str(SERVER)], input="{not json}\n", capture_output=True, text=True, cwd=ROOT, env=ENV)
        self.assertEqual(json.loads(p.stdout.strip())["error"]["code"], -32700)

    def test_tools_list(self):
        """MCP-T02 tools/list returns the catalog with schemas; every tool maps to an existing read-only or dry-run CLI [MCP-02]"""
        out = talk([{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
        tools = {t["name"]: t for t in out[0]["result"]["tools"]}
        self.assertEqual(set(tools), {"assess_object", "check_sql", "compare_schemas", "toolbox", "audit_tail"})
        for t in tools.values():
            self.assertEqual(t["inputSchema"]["type"], "object"); self.assertTrue(t["description"])
        sys.path.insert(0, str(SERVER.parent)); import kit_mcp_server as srv
        sample = {"assess_object": {"path": "source"}, "check_sql": {"path": "x.sql", "target": "redshift"}, "compare_schemas": {"source": "a", "target": "b", "profile": "aurora"}, "toolbox": {"target": "athena"}, "audit_tail": {"run": "abcd1234"}}
        for name, spec in srv.TOOLS.items():
            argv = spec["argv"](sample[name])
            self.assertTrue((ROOT / argv[0]).exists(), argv[0])
            self.assertIn(argv[1], ("assess", "check", "compare", "toolbox", "tail"), name)
        p = subprocess.run([sys.executable, str(SERVER), "--list"], capture_output=True, text=True, cwd=ROOT, env=ENV); self.assertIn("compare_schemas", p.stdout)

    def test_tools_call_and_audit(self):
        """MCP-T03 tools/call runs the kit CLI inside the workspace and returns text with isError/exit code; the call is audited under the run id [MCP-03]"""
        out = talk([{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "check_sql", "arguments": {"path": ".kiro/skills/sql-conversion-redshift/references/examples/02_customer_summary_view.redshift.sql", "target": "redshift"}}},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "toolbox", "arguments": {"target": "athena", "need": "gap"}}},
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "check_sql", "arguments": {"path": ".kiro/skills/sql-conversion-redshift/references/examples/02_customer_summary_view.sqlserver.sql", "target": "redshift"}}}])
        r1 = out[0]["result"]; self.assertFalse(r1["isError"]); self.assertEqual(r1["_meta"]["exitCode"], 0); self.assertIn('"problems": []', r1["content"][0]["text"])
        self.assertIn("RD-01", out[1]["result"]["content"][0]["text"]); self.assertIn("UNNEST", out[1]["result"]["content"][0]["text"])
        r3 = out[2]["result"]; self.assertEqual(r3["_meta"]["exitCode"], 1); self.assertFalse(r3["isError"]); self.assertIn("RS-", r3["content"][0]["text"])
        text = "".join(p.read_text(encoding="utf-8") for p in (_STATE / "audit").rglob("*.jsonl"))
        self.assertIn('"event":"mcp.tool"', text); self.assertIn("7ff76519", text)

    def test_argument_validation(self):
        """MCP-T04 unknown tools/arguments, enum violations, absolute or traversal paths, missing files and non-hex run ids are refused without executing anything [MCP-04]"""
        cases = [{"name": "drop_everything", "arguments": {}}, {"name": "check_sql", "arguments": {"path": "README.md", "target": "oracle"}},
                 {"name": "check_sql", "arguments": {"path": "/etc/passwd", "target": "redshift"}}, {"name": "check_sql", "arguments": {"path": "../outside.sql", "target": "redshift"}},
                 {"name": "check_sql", "arguments": {"path": "does/not/exist.sql", "target": "redshift"}}, {"name": "check_sql", "arguments": {"path": "README.md", "target": "redshift", "extra": "x"}},
                 {"name": "audit_tail", "arguments": {"run": "abc; rm -rf /"}}, {"name": "compare_schemas", "arguments": {"source": "README.md", "profile": "aurora"}}]
        out = talk([{"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": c} for i, c in enumerate(cases, 1)])
        self.assertEqual(len(out), len(cases))
        for r in out:
            self.assertTrue(r["result"]["isError"], r); self.assertTrue(r["result"]["content"][0]["text"].startswith("refused:"), r)
        text = "".join(p.read_text(encoding="utf-8") for p in (_STATE / "audit").rglob("*.jsonl"))
        self.assertIn('"event":"mcp.refused"', text)


class TaggedResult(unittest.TextTestResult):
    lines = []

    def addSuccess(self, test):
        super().addSuccess(test); self.lines.append(("PASS", test))

    def addFailure(self, test, err):
        super().addFailure(test, err); self.lines.append(("FAIL", test))

    def addError(self, test, err):
        super().addError(test, err); self.lines.append(("ERROR", test))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--results"); a = ap.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(McpTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=TaggedResult).run(suite)
    if a.results:
        with open(a.results, "a", encoding="utf-8") as f:
            for status, test in TaggedResult.lines:
                f.write(f"{status}\tmcp\t{(test.shortDescription() or test.id()).strip()}\n")
    sys.exit(0 if result.wasSuccessful() else 1)
