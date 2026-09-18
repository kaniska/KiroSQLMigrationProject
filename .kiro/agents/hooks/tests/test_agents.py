#!/usr/bin/env python3
"""Structural tests for the two agents (AG-nn, catalog .kiro/agents/AGENTS.md). Results → --results FILE ("STATUS<TAB>agents<TAB>name")."""
import argparse
import glob
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import unittest

if os.name == "nt" and not sys.flags.utf8_mode:
    import subprocess as _sp
    os.environ["PYTHONUTF8"] = "1"
    sys.exit(_sp.call([sys.executable, "-X", "utf8", *sys.argv]))

HOOKS = pathlib.Path(__file__).resolve().parents[1]
ROOT = HOOKS.parents[2]
AGENTS = ["sql-migration-agent", "sql-reporting-agent"]
sys.path.insert(0, str(ROOT / ".kiro" / "skills" / "sql-conversion" / "scripts"))
from migkit import security  # noqa: E402

REPRESENTATIVE = {
    "sql-migration-agent": [
        "bash supporting-files/run_tests.sh --project", "bash .kiro/skills/sql-conversion-redshift/scripts/run_skill_tests.sh",
        "python3 .kiro/skills/migration-assessment/scripts/assess_tool.py assess source --consumer bi --out generated/assessment",
        "python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py convert-ddl source/schema/sales_db_schema.sql --design metadata/design/redshift.json --out generated/redshift/schema.sql",
        "python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py job generated/iceberg/load.job.json --out generated/iceberg/load.glue.py",
        "python3 .kiro/skills/schema-conformance/scripts/schema_tool.py compare generated/schema/s.json generated/schema/t.json --profile aurora --out generated/schema/compare",
        "python3 .kiro/skills/schema-change-propagation/scripts/change_tool.py patch generated/changes/plan.json --flow generated --out generated/changes/patches",
        "python3 .kiro/skills/informatica-etl-conversion/scripts/infa_sql_tool.py check generated/informatica/wf.sql --target redshift",
        "python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py tail --run 844d88f6", "python3 .kiro/skills/sql-conversion/scripts/migkit/security.py scan source/x.sql"],
    "sql-reporting-agent": [
        "bash .kiro/skills/sql-reporting/scripts/run_skill_tests.sh", "bash supporting-files/run_tests.sh --project",
        "python3 .kiro/skills/sql-reporting/scripts/report_tool.py check generated/reports/redshift/v_report_x.sql --target redshift",
        "python3 .kiro/skills/sql-reporting/scripts/report_tool.py toolbox --target athena --need gap",
        "python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot generated/schema.sql --dialect pgsql --out generated/schema/target.snapshot.json",
        "python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py run generated/reports/redshift/v_report_x.sql --database dw_test --workgroup-name wg",
        "python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py check generated/reports/athena/v_report_x.sql --dialect athena",
        "python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py tail --run 844d88f6"],
}
FORBIDDEN_FOR_REPORTING = ["python3 .kiro/skills/schema-change-propagation/scripts/change_tool.py patch p.json --flow generated --out o",
                           "python3 .kiro/skills/informatica-etl-conversion/scripts/infa_sql_tool.py inject a.xml d out.xml --map m.json",
                           "python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py convert-ddl s.sql --out o.sql"]


def load(name):
    return json.loads((ROOT / ".kiro" / "agents" / f"{name}.json").read_text(encoding="utf-8"))


def allowed(agent: dict, cmd: str) -> bool:
    return any(re.fullmatch(rx, cmd) for rx in agent["toolsSettings"]["execute_bash"]["allowedCommands"])


def glob_allowed(agent: dict, cmd: str) -> bool:
    import fnmatch
    shell = next(r for r in agent["permissions"]["rules"] if r["capability"] == "shell")
    return any(fnmatch.fnmatchcase(cmd, g) for g in shell["match"])


class AgentTests(unittest.TestCase):
    def test_files_and_prompts(self):
        """AG-T01 both agents parse, are named after their files, have prompt files and welcome messages with example prompts [AG-01]"""
        for name in AGENTS:
            a = load(name); self.assertEqual(a["name"], name)
            prompt = ROOT / ".kiro" / "agents" / a["prompt"].replace("file://./", "")
            self.assertTrue(prompt.exists(), prompt); self.assertGreater(len(prompt.read_text(encoding="utf-8")), 1500)
            self.assertIn("Try:", a["welcomeMessage"]); self.assertIn("examples.md", a["welcomeMessage"])
            self.assertTrue(a["description"])

    def test_resources_and_hooks_resolve(self):
        """AG-T02 every resource glob and skill path resolves to existing files; every hook command exists [AG-02]"""
        for name in AGENTS:
            a = load(name)
            for r in a["resources"]:
                rel = r.split("://", 1)[1]
                self.assertTrue(glob.glob(str(ROOT / rel), recursive=True), f"{name}: {r} resolves to nothing")
            for event, entries in a["hooks"].items():
                for e in entries:
                    script = e["command"].split()[1]
                    self.assertTrue((ROOT / script).exists(), f"{name}: {event} → {script}")
            self.assertTrue(any("guard_tool.py" in e["command"] for e in a["hooks"]["preToolUse"]), name)
            self.assertTrue(any("audit_event.py" in e["command"] for e in a["hooks"]["postToolUse"]), name)

    def test_allow_lists_cover_the_workflow(self):
        """AG-T03 representative workflow commands match an allowedCommands regex and a permissions glob; every regex compiles [AG-03]"""
        for name in AGENTS:
            a = load(name)
            for rx in a["toolsSettings"]["execute_bash"]["allowedCommands"]:
                re.compile(rx)
            for cmd in REPRESENTATIVE[name]:
                self.assertTrue(allowed(a, cmd), f"{name}: not in allowedCommands: {cmd}")
                self.assertTrue(glob_allowed(a, cmd), f"{name}: not in permissions: {cmd}")

    def test_write_scope_and_secrets(self):
        """AG-T04 write paths stay inside the workspace and outside .kiro/, logs/ and connection settings; MCP servers disabled by default; no credentials in the agent files [AG-04]"""
        for name in AGENTS:
            a = load(name)
            for p in a["toolsSettings"]["fs_write"]["allowedPaths"]:
                self.assertFalse(p.startswith(("/", "..", "~")), p)
                self.assertFalse(re.match(r"(\.kiro|logs|metadata/test_connection)", p), f"{name}: {p}")
            for srv, cfg in a["mcpServers"].items():
                self.assertTrue(cfg.get("disabled"), f"{name}: MCP server {srv} must start disabled")
            text = (ROOT / ".kiro" / "agents" / f"{name}.json").read_text(encoding="utf-8")
            self.assertEqual([f for f in security.scan_text(text, "text", name) if f["rule"] == "SEC-03"], [], name)

    def test_separation_of_concerns(self):
        """AG-T05 the reporting agent cannot convert, inject, patch or write the migration log; the migration agent can; both share guard and audit hooks [AG-05]"""
        m, r = load("sql-migration-agent"), load("sql-reporting-agent")
        for cmd in FORBIDDEN_FOR_REPORTING:
            self.assertFalse(allowed(r, cmd), f"reporting agent must not run: {cmd}")
            self.assertTrue(allowed(m, cmd), f"migration agent should run: {cmd}")
        self.assertNotIn("metadata/migration_log.json", r["toolsSettings"]["fs_write"]["allowedPaths"])
        self.assertIn("metadata/migration_log.json", m["toolsSettings"]["fs_write"]["allowedPaths"])
        self.assertTrue(all(p.startswith(("generated/reports/", "generated/schema/", "tests/")) for p in r["toolsSettings"]["fs_write"]["allowedPaths"]))
        self.assertEqual(m["hooks"], r["hooks"])

    def test_windows_twins(self):
        """AG-T06 Windows twins exist, are in sync with the generator and keep hooks and write paths [AG-06]"""
        p = subprocess.run([sys.executable, str(ROOT / "supporting-files" / "make_windows_agent.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        for name in AGENTS:
            w = load(name + "-windows"); a = load(name)
            self.assertEqual(w["name"], name + "-windows"); self.assertEqual(w["toolsSettings"]["fs_write"], a["toolsSettings"]["fs_write"])
            self.assertTrue(all(e["command"].startswith("python -X utf8 ") for es in w["hooks"].values() for e in es))

    def test_kiro_cli_validate(self):
        """AG-T07 kiro-cli agent validate accepts all four agent files when kiro-cli is installed [AG-07]"""
        cli = shutil.which("kiro-cli")
        if not cli:
            print("kiro-cli not installed: structural checks only (validate not run)"); return
        for name in AGENTS:
            for f in (f"{name}.json", f"{name}-windows.json"):
                p = subprocess.run([cli, "agent", "validate", "--path", str(ROOT / ".kiro" / "agents" / f)], capture_output=True, text=True, cwd=ROOT, timeout=60)
                self.assertEqual(p.returncode, 0, f"{f}: {p.stdout}{p.stderr}")

    def test_prompts_name_real_skills(self):
        """AG-T08 the router prompt names every existing skill and nothing else; examples.md has a section per skill [AG-08]"""
        skills = {p.parent.name for p in (ROOT / ".kiro" / "skills").glob("*/SKILL.md")}
        router = (ROOT / ".kiro" / "agents" / "prompts" / "sql-migration-agent.md").read_text(encoding="utf-8")
        for s in skills:
            self.assertIn(f"`{s}`", router, f"router prompt does not mention {s}")
        mentioned = set(re.findall(r"`([a-z][a-z0-9-]+)`", router))
        self.assertFalse({"schema-validation", "metadata-validation"} & mentioned, "retired skills must not be mentioned")
        ex = (ROOT / ".kiro" / "agents" / "prompts" / "examples.md").read_text(encoding="utf-8")
        for s in skills:
            self.assertIn(f"(`{s}`)", ex, f"examples.md has no section for {s}")


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
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(AgentTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=TaggedResult).run(suite)
    if a.results:
        with open(a.results, "a", encoding="utf-8") as f:
            for status, test in TaggedResult.lines:
                f.write(f"{status}\tagents\t{(test.shortDescription() or test.id()).strip()}\n")
    sys.exit(0 if result.wasSuccessful() else 1)
