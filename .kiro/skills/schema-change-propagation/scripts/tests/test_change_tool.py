#!/usr/bin/env python3
"""Unit tests for change_tool.py. Docstrings carry the [CP-nn] tags proven; results are appended to
--results FILE as "STATUS<TAB>change<TAB>name" for check_rule_coverage.py. No database or AWS needed."""
import argparse
import contextlib
import copy
import io
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
import zipfile

if os.name == "nt" and not sys.flags.utf8_mode:
    import subprocess as _sp
    os.environ["PYTHONUTF8"] = "1"
    sys.exit(_sp.call([sys.executable, "-X", "utf8", *sys.argv]))

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
SKILL = SCRIPTS.parent
EX = SKILL / "references" / "examples"
_STATE = pathlib.Path(tempfile.mkdtemp(prefix="change-test-"))
os.environ["MIGRATION_LOG_DIR"] = str(_STATE / "audit"); os.environ["MIGRATION_STATE_DIR"] = str(_STATE / "state")
os.environ["MIGRATION_OFFLINE"] = "1"; os.environ.setdefault("MIGRATION_RUN_ID", "5ef7651916cd43dd8448eb211c803190")
sys.path.insert(0, str(SCRIPTS))
import change_tool as tool  # noqa: E402


def run(cmd, *args):
    buf, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
        old = sys.argv
        try:
            sys.argv = ["change_tool.py", cmd, *args]
            rc = tool.main()
        except SystemExit as ex:
            rc = ex.code
        finally:
            sys.argv = old
    return rc, buf.getvalue() + err.getvalue()


def load(name):
    return json.loads((EX / name).read_text(encoding="utf-8"))


def make_xlsx(path: pathlib.Path, rows: list):
    def cell(ref, v):
        return f'<c r="{ref}" t="inlineStr"><is><t>{v}</t></is></c>'
    body = "".join(f'<row r="{i + 1}">' + "".join(cell(f"{chr(65 + j)}{i + 1}", v) for j, v in enumerate(r)) + "</row>" for i, r in enumerate(rows))
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"></Types>')
        z.writestr("xl/worksheets/sheet1.xml", f'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>{body}</sheetData></worksheet>')


class ChangeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = pathlib.Path(tempfile.mkdtemp(prefix="change-"))
        cls.changes = tool.ingest(EX / "changes.csv")
        cls.snap, cls.layers, cls.policy, cls.profile = load("target.snapshot.json"), load("layers.json"), load("policy.json"), load("profile.json")
        cls.flow = tool._load_flow(EX / "flow")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def _plan(self, changes=None, snap="default", layers=None, policy=None, profile="default", flow=None):
        return tool.plan(changes or self.changes, self.snap if snap == "default" else snap, layers or self.layers, policy or self.policy, self.profile if profile == "default" else profile, flow or self.flow)

    def test_ingest(self):
        """CP-T01 CSV and XLSX templates ingest with normalised headers and case/whitespace, a checksum and untouched values; change types are required-field checked [CP-01] [CP-02]"""
        c = self.changes
        self.assertEqual(c["headers"][:3], ["Change_Type", "Current_Schema", "Current_Table"]); self.assertEqual(len(c["sha256"]), 64); self.assertEqual(len(c["rows"]), 5)
        self.assertEqual(c["rows"][4]["Current_Schema"], "ETL"); self.assertEqual(c["rows"][3]["Justification"], "legacy request (suspicious)")
        x = self.tmp / "t.xlsx"; make_xlsx(x, [["change type", "current schema", "Current Table", "Current Column", "New Column"], ["rename_column", "etl", "asset_summary", "asset_code", "asset_id"]])
        cx = tool.ingest(x); self.assertEqual(cx["rows"][0]["Change_Type"], "RENAME_COLUMN"); self.assertEqual(cx["rows"][0]["New_Column"], "asset_id"); self.assertEqual(cx["headers"][0], "Change_Type")
        bad = copy.deepcopy(self.changes); bad["rows"][1]["New_Datatype"] = ""; bad["rows"][0]["Change_Type"] = "MOVE_TABLE"
        v = tool.validate(bad, self.snap, self.layers, self.policy)
        msgs = [d["message"] for d in v["diagnostics"]]
        self.assertTrue(any("CAST_COLUMN needs New_Datatype" in m for m in msgs)); self.assertTrue(any("unknown Change_Type" in m for m in msgs)); self.assertIn("INVALID_INPUT", v["stopCodes"])
        rc, out = run("ingest", str(EX / "changes.csv"), "--out", str(self.tmp / "c.json")); self.assertEqual(rc, 0, out)

    def test_duplicates_conflicts_collisions(self):
        """CP-T02 duplicate rows, conflicting rows and rename collisions are reported; collisions block before generation [CP-03] [CP-04]"""
        dup = copy.deepcopy(self.changes); dup["rows"].append(dict(dup["rows"][2], rowId="R006"))
        v = tool.validate(dup, self.snap, self.layers, self.policy); self.assertTrue(any("duplicate of R003" in d["message"] for d in v["diagnostics"]))
        con = copy.deepcopy(self.changes); con["rows"].append(dict(con["rows"][2], rowId="R006", New_Column="asset_key"))
        v = tool.validate(con, self.snap, self.layers, self.policy); self.assertTrue(any("conflicts with R003" in d["message"] for d in v["diagnostics"]))
        col = copy.deepcopy(self.changes); col["rows"][4]["New_Column"] = "asset_id"
        v = tool.validate(col, self.snap, self.layers, self.policy)
        self.assertEqual(v["status"], "BLOCKED"); self.assertIn("RENAME_COLLISION", v["stopCodes"])
        p = tool.plan(col, self.snap, self.layers, self.policy, self.profile, self.flow); self.assertEqual(p["operations"], [])

    def test_metadata_and_schema_policy(self):
        """CP-T03 blank datatypes resolve only from the snapshot with provenance (else METADATA_NOT_FOUND, no cast claim); blank New_Schema needs the approved policy [CP-05] [CP-06]"""
        v = tool.validate(copy.deepcopy(self.changes), self.snap, self.layers, self.policy)
        self.assertEqual(v["status"], "GENERATED")
        r2 = next(r for r in v["rows"] if r["rowId"] == "R002"); self.assertEqual(r2["currentType"]["raw"], "INTEGER"); self.assertTrue(r2["metadataProvenance"].startswith("ddl-parse:"))
        self.assertEqual(next(r for r in v["rows"] if r["rowId"] == "R001")["schemaResolvedBy"], "policy:retain_current_schema")
        v = tool.validate(copy.deepcopy(self.changes), None, self.layers, self.policy)
        self.assertEqual(v["status"], "BLOCKED"); self.assertIn("METADATA_NOT_FOUND", v["stopCodes"])
        p = tool.plan(copy.deepcopy(self.changes), None, self.layers, self.policy, None, self.flow); self.assertEqual(p["operations"], []); self.assertEqual(p["risks"], [])
        v = tool.validate(copy.deepcopy(self.changes), self.snap, self.layers, {"retain_current_schema": False})
        self.assertEqual(v["status"], "BLOCKED"); self.assertIn("TARGET_SCHEMA_DECISION_REQUIRED", v["stopCodes"])
        amb = copy.deepcopy(self.changes); amb["rows"][4]["Current_Datatype"] = "DATE"
        v = tool.validate(amb, self.snap, self.layers, self.policy); self.assertIn("METADATA_AMBIGUOUS", v["stopCodes"])

    def test_layers(self):
        """CP-T04 protected-layer rows are refused, editable allowlist enforced, protected files untouched by patching [CP-07] [CP-21]"""
        prot = copy.deepcopy(self.changes); prot["rows"][2]["Current_Schema"] = "src"; prot["rows"][2]["Current_Table"] = "asset"
        v = tool.validate(prot, self.snap, self.layers, self.policy)
        self.assertTrue(any("protected layer" in d["message"] for d in v["diagnostics"])); self.assertTrue(next(r for r in v["rows"] if r["rowId"] == "R003").get("refused"))
        outside = copy.deepcopy(self.changes); outside["rows"][2]["Current_Schema"] = "other"
        v = tool.validate(outside, self.snap, self.layers, self.policy); self.assertIn("TARGET_DECISION_REQUIRED", v["stopCodes"])
        p = self._plan(); res = tool.apply_patches(p, self.flow, self.layers)
        self.assertEqual(res["files"]["flow/src_asset_view.sql"], self.flow["flow/src_asset_view.sql"]); self.assertEqual(res["files"]["flow/lookup_labels.sql"], self.flow["flow/lookup_labels.sql"])
        scan = tool.residual_scan(p, self.flow, res["files"], self.layers); self.assertTrue(scan["protectedDiffClean"])
        self.assertIn("flow/src_asset_view.sql", res["protected"])

    def test_cast_safety(self):
        """CP-T05 cast-safety matrix, high-risk casts need evidence and disposition, overflow/parse failures quantified with on_failure rule, original vs cast-induced nulls [CP-10] [CP-11] [CP-12] [CP-13]"""
        cs = lambda col, a, b: tool.cast_safety(col, tool.norm_raw(a), tool.norm_raw(b))["risk"]
        self.assertEqual(cs("qty", "INTEGER", "BIGINT"), "SAFE"); self.assertEqual(cs("qty", "BIGINT", "INTEGER"), "LOSSY"); self.assertEqual(cs("amt", "NUMERIC(19,4)", "NUMERIC(10,2)"), "LOSSY")
        self.assertEqual(cs("code", "VARCHAR(20)", "INTEGER"), "LOSSY"); self.assertEqual(cs("asset_desc", "VARCHAR(200)", "INTEGER"), "HIGH_RISK"); self.assertEqual(cs("created_at", "VARCHAR(30)", "INTEGER"), "HIGH_RISK")
        self.assertEqual(cs("flag", "INTEGER", "BOOLEAN"), "HIGH_RISK"); self.assertEqual(cs("n", "VARCHAR(50)", "VARCHAR(20)"), "LOSSY"); self.assertEqual(cs("n", "VARCHAR(20)", "TEXT"), "SAFE")
        self.assertEqual(cs("d", "DATE", "TIMESTAMP"), "SAFE"); self.assertEqual(cs("g", "GEOGRAPHY", "INTEGER"), "UNSUPPORTED")
        p = self._plan()
        hr = next(r for r in p["risks"] if r["row"] == "R004")
        self.assertEqual(hr["risk"], "HIGH_RISK"); self.assertTrue(hr["outcome"].startswith("REJECTED")); self.assertEqual(hr["originalNulls"], 10); self.assertEqual(hr["castInducedNulls"], 1187)
        self.assertFalse(any(o["row"] == "R004" for o in p["operations"])); self.assertEqual(p["status"], "GENERATED")
        # no disposition → review required, PARTIAL, no silent default
        pol = copy.deepcopy(self.policy); pol.pop("cast_dispositions")
        p2 = self._plan(policy=pol); self.assertEqual(p2["status"], "PARTIAL"); self.assertIn("UNSAFE_CAST_REVIEW_REQUIRED", p2["stopCodes"])
        self.assertTrue(next(r for r in p2["risks"] if r["row"] == "R004")["outcome"].startswith("REVIEW_REQUIRED"))
        p3 = self._plan(policy=pol, profile=None); self.assertIn("no data profile", next(r for r in p3["risks"] if r["row"] == "R004")["outcome"])
        # overflow on a lossy cast: blocked without an on_failure rule, generated with one
        over = copy.deepcopy(self.changes); over["rows"] = [dict(over["rows"][1], New_Datatype="SMALLINT", rowId="R002")]
        prof = {"etl.asset_summary.asset_code": {"rows": 10, "nulls": 1, "non_numeric": 0, "overflow": 2, "sample_keys": ["70000", "80001"]}}
        pa = tool.plan(over, self.snap, self.layers, {"retain_current_schema": True}, prof, {}); self.assertEqual(pa["status"], "PARTIAL"); self.assertEqual(pa["operations"], [])
        pb = tool.plan(over, self.snap, self.layers, {"retain_current_schema": True, "on_failure": "NULL_AND_QUARANTINE", "cast_dispositions": {"etl.asset_summary.asset_code": {"decision": "APPROVED", "by": "owner"}}}, prof, {})
        self.assertEqual(len(pb["operations"]), 1); self.assertEqual(pb["operations"][0]["onFailure"], "NULL_AND_QUARANTINE"); self.assertEqual(pb["risks"][0]["castInducedNulls"], 2); self.assertEqual(pb["risks"][0]["originalNulls"], 1)

    def test_ordered_plan_and_propagation(self):
        """CP-T06 casts reference the current column and precede renames, table renames last, every operation row-linked; propagation sites listed per file/line; rollback reversed [CP-14] [CP-15] [CP-23]"""
        p = self._plan()
        ops = [(o["op"], o.get("column"), o["row"]) for o in p["operations"]]
        self.assertEqual(ops, [("CAST_COLUMN", "asset_code", "R002"), ("RENAME_COLUMN", "asset_code", "R003"), ("RENAME_COLUMN", "last_seen", "R005"), ("RENAME_TABLE", None, "R001")])
        self.assertIn("ALTER COLUMN asset_code TYPE BIGINT USING (asset_code)::BIGINT", p["operations"][0]["sql"]); self.assertIn("RENAME COLUMN asset_code TO asset_id", p["operations"][1]["sql"])
        self.assertTrue(all(o["row"] for o in p["operations"])); self.assertEqual({r["rule"] for r in p["ruleLedger"]} <= {"CP-11", "CP-14", "CP-10"}, True)
        sites = {(s["file"], s["kind"], s["old"]) for s in p["propagation"]}
        self.assertIn(("flow/etl_load_asset_summary.sql", "column", "asset_code"), sites); self.assertIn(("flow/tests_asset_summary.sql", "table", "etl.asset_summary"), sites)
        self.assertFalse(any(s["file"] == "flow/src_asset_view.sql" for s in p["propagation"]), "protected source view is not a target-flow site")
        rb = [r["sql"] for r in p["rollback"]]
        self.assertTrue(rb[0].startswith("ALTER TABLE etl.asset_summary_v2 RENAME TO asset_summary")); self.assertIn("RENAME COLUMN asset_id TO asset_code", rb[2]); self.assertIn("TYPE INTEGER", rb[3])
        self.assertTrue(any("lossy" in r["note"] for r in p["rollback"]))

    def test_token_aware_patch_and_residuals(self):
        """CP-T07 only identifier tokens of the target table change (not comments, literals, aliases of protected objects or similar names); diff produced; residual scan separates explained residues [CP-20] [CP-22]"""
        p = self._plan(); res = tool.apply_patches(p, self.flow, self.layers)
        after = res["files"]["flow/etl_load_asset_summary.sql"]
        self.assertIn("INSERT INTO etl.asset_summary_v2 (asset_id, asset_desc, last_seen_at)", after)
        self.assertIn("SELECT s.asset_code, s.asset_desc, s.last_seen", after, "source alias columns stay")
        self.assertIn("l.asset_code = a.asset_id", after, "lookup alias stays, target alias changes")
        self.assertIn("-- asset_code comes from the protected source view; 'asset_code' literal must stay", after)
        self.assertIn("RAISE NOTICE 'loaded asset_code rows into asset_summary'", after)
        self.assertIn("l.asset_code_label", after, "similar name untouched")
        self.assertIn("asset_id BIGINT NOT NULL", res["files"]["flow/etl_schema.sql"], "cast applied to the DDL before the rename")
        self.assertIn("CREATE TABLE etl.asset_summary_v2 (", res["files"]["flow/etl_schema.sql"])
        self.assertTrue(res["diffs"]["flow/etl_load_asset_summary.sql"].startswith("--- a/flow/etl_load_asset_summary.sql"))
        scan = tool.residual_scan(p, self.flow, res["files"], self.layers)
        self.assertEqual(scan["unexplained"], []); self.assertTrue(any(e["where"] == "comment/literal" for e in scan["explained"]))
        # an unpatched editable file leaves unexplained residues
        scan2 = tool.residual_scan(p, self.flow, self.flow, self.layers); self.assertTrue(scan2["unexplained"])
        self.assertTrue(any(u["file"] == "flow/tests_asset_summary.sql" for u in scan2["unexplained"]))

    def test_idempotent_and_no_apply(self):
        """CP-T08 same inputs produce identical plans and patches apart from run metadata; --apply is refused with PRODUCTION_WRITE_DENIED and audited [CP-24] [CP-25]"""
        a, b = self._plan(), self._plan()
        for d in (a, b):
            d.pop("generatedAt"); d.pop("runId")
        self.assertEqual(tool.contract.canonical_json(a), tool.contract.canonical_json(b))
        ra, rb = tool.apply_patches(a, self.flow, self.layers), tool.apply_patches(b, self.flow, self.layers)
        self.assertEqual(ra["files"], rb["files"])
        (self.tmp / "plan.json").write_text(tool.contract.canonical_json(self._plan()), encoding="utf-8")
        rc, out = run("patch", str(self.tmp / "plan.json"), "--flow", str(EX / "flow"), "--out", str(self.tmp / "p"), "--apply"); self.assertEqual(rc, 3); self.assertIn("PRODUCTION_WRITE_DENIED", out)
        text = "".join(f.read_text(encoding="utf-8") for f in (_STATE / "audit").rglob("*.jsonl"))
        self.assertIn("PRODUCTION_WRITE_DENIED", text)

    def test_commands_and_package(self):
        """CP-T09 end-to-end CLI: ingest → validate → plan → patch → scan → package with ledger rows per template row and the validation manifest [CP-26] [CP-01]"""
        c, pl, pt, pk = self.tmp / "c.json", self.tmp / "plan.json", self.tmp / "patches", self.tmp / "pkg"
        rc, out = run("ingest", str(EX / "changes.csv"), "--out", str(c)); self.assertEqual(rc, 0, out)
        rc, out = run("validate", str(c), "--snapshot", str(EX / "target.snapshot.json"), "--layers", str(EX / "layers.json"), "--policy", str(EX / "policy.json")); self.assertEqual(rc, 0, out)
        rc, out = run("plan", str(c), "--snapshot", str(EX / "target.snapshot.json"), "--layers", str(EX / "layers.json"), "--policy", str(EX / "policy.json"), "--profile", str(EX / "profile.json"), "--flow", str(EX / "flow"), "--out", str(pl)); self.assertEqual(rc, 0, out)
        rc, out = run("patch", str(pl), "--flow", str(EX / "flow"), "--out", str(pt)); self.assertEqual(rc, 0, out)
        for f in ("changes.diff", "migration.sql", "rollback.sql", "residual-scan.json", "after/flow/etl_schema.sql"):
            self.assertTrue((pt / f).exists(), f)
        self.assertIn("-- DRY RUN", (pt / "migration.sql").read_text(encoding="utf-8"))
        rc, out = run("scan", str(pl), "--flow", str(EX / "flow"), "--patched", str(pt)); self.assertEqual(rc, 0, out)
        rc, out = run("package", str(pl), "--patches", str(pt), "--out", str(pk)); self.assertEqual(rc, 0, out)
        o = json.loads((pk / "output.json").read_text(encoding="utf-8"))
        self.assertEqual(o["status"], "GENERATED"); self.assertEqual({r["rule"] for r in o["analysis"]["ruleLedger"]} & {"CP-14"}, {"CP-14"})
        rows = {r["sourceFeature"].split()[0] for r in o["analysis"]["ruleLedger"]}
        self.assertEqual(rows, {"R001", "R002", "R003", "R004", "R005"}, "every template row has a ledger row")
        ex = {e["id"]: e["status"] for e in o["validation"]["executedChecks"]}; self.assertEqual(ex["V-004"], "PASS"); self.assertEqual(ex["V-039"], "PASS")
        self.assertIn("V-012", [x["id"] for x in o["validation"]["unexecutedChecks"]])
        self.assertTrue((pk / "files" / "plan.json").exists() or (pk / "plan.json").exists() or any(pk.rglob("plan.json")))


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
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ChangeTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=TaggedResult).run(suite)
    if a.results:
        with open(a.results, "a", encoding="utf-8") as f:
            for status, test in TaggedResult.lines:
                f.write(f"{status}\tchange\t{(test.shortDescription() or test.id()).strip()}\n")
    sys.exit(0 if result.wasSuccessful() else 1)
