#!/usr/bin/env python3
"""Unit tests for redshift_tool.py. Docstrings carry the [RS-nn] tags proven; results are appended to
--results FILE as "STATUS<TAB>redshift<TAB>name" for check_rule_coverage.py. No Redshift needed: the
Data API path runs against the stub AWS CLI; a live run happens only when REDSHIFT_DATABASE and
REDSHIFT_WORKGROUP (or REDSHIFT_CLUSTER) are set."""
import argparse
import contextlib
import io
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest

if os.name == "nt" and not sys.flags.utf8_mode:
    import subprocess as _sp
    os.environ["PYTHONUTF8"] = "1"
    sys.exit(_sp.call([sys.executable, "-X", "utf8", *sys.argv]))

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
SKILL = SCRIPTS.parent
EX = SKILL / "references" / "examples"
ENGINE = SKILL.parent / "sql-conversion" / "scripts"
STUB = ENGINE / "tests" / "stub" / ("aws.cmd" if os.name == "nt" else "aws")
_STATE = pathlib.Path(tempfile.mkdtemp(prefix="redshift-test-"))
os.environ["MIGRATION_LOG_DIR"] = str(_STATE / "audit"); os.environ["MIGRATION_STATE_DIR"] = str(_STATE / "state")
os.environ["MIGRATION_OFFLINE"] = "1"; os.environ.setdefault("MIGRATION_RUN_ID", "2bf7651916cd43dd8448eb211c80319d")
sys.path.insert(0, str(SCRIPTS))
import redshift_tool as tool  # noqa: E402

EXAMPLES = ["01_sales_tables", "02_customer_summary_view", "03_load_customer_summary", "04_org_chart", "05_secure_employee_view"]


def run(cmd, *args):
    buf, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
        old = sys.argv
        try:
            sys.argv = ["redshift_tool.py", cmd, *args]
            rc = tool.main()
        except SystemExit as ex:
            rc = ex.code
        finally:
            sys.argv = old
    return rc, buf.getvalue() + err.getvalue()


def rules(problems):
    return {p["rule"] for p in problems}


class StubAws(contextlib.ContextDecorator):
    """Routes migkit Services at the stub AWS CLI (records every call in STUB_LOG)."""
    def __init__(self, tmp, scenario="ok", **extra):
        self.tmp, self.scenario, self.extra = pathlib.Path(tmp), scenario, extra

    def __enter__(self):
        self.cfg = self.tmp / "services.json"; self.log = self.tmp / "stub.jsonl"
        self.cfg.write_text(json.dumps({"aws_cli": str(STUB), "region": "us-east-1", "probe_cache_seconds": 0}))
        self.old = {k: os.environ.get(k) for k in ("MIGRATION_OFFLINE", "MIGRATION_SERVICES_CONFIG", "STUB_LOG", "STUB_SCENARIO", *self.extra)}
        os.environ.pop("MIGRATION_OFFLINE", None)
        os.environ.update({"MIGRATION_SERVICES_CONFIG": str(self.cfg), "STUB_LOG": str(self.log), "STUB_SCENARIO": self.scenario, **self.extra})
        return self

    def __exit__(self, *a):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def calls(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.exists() else []


class RedshiftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = pathlib.Path(tempfile.mkdtemp(prefix="redshift-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    # ---------------------------------------------------------------- unsupported constructs
    def test_unsupported_constructs_are_problems(self):
        """RS-T01 triggers, table functions, table variables, CHECK, sequences, FOR XML, nested cursors, INSTEAD OF, linked servers are flagged [RS-01] [RS-02] [RS-03] [RS-04] [RS-05] [RS-06] [RS-07] [RS-08] [RS-09]"""
        cases = {
            "RS-01": "CREATE TRIGGER tr_x ON t AFTER INSERT AS BEGIN SELECT 1; END;",
            "RS-02": "CREATE FUNCTION f(@a INT) RETURNS TABLE AS RETURN (SELECT 1 AS x);",
            "RS-03": "DECLARE @t TABLE (id INT); INSERT INTO @t VALUES (1);",
            "RS-04": "CREATE TABLE t (qty INT CHECK (qty > 0));",
            "RS-05": "CREATE SEQUENCE s; SELECT NEXT VALUE FOR s;",
            "RS-06": "SELECT id FROM t FOR XML PATH('');",
            "RS-07": "DECLARE c1 CURSOR FOR SELECT 1; DECLARE c2 CURSOR FOR SELECT 2;",
            "RS-08": "CREATE TRIGGER v_ins ON v INSTEAD OF INSERT AS BEGIN SELECT 1; END;",
            "RS-09": "SELECT * FROM OPENQUERY(remote, 'select 1');",
        }
        for rule, sql in cases.items():
            probs, _ = tool.check_text(sql)
            self.assertIn(rule, rules(probs), f"{rule} not raised for {sql}")
        probs, _ = tool.check_text("-- CREATE TRIGGER in a comment\nSELECT 'DECLARE @t TABLE' AS s;")
        self.assertEqual(rules(probs), set(), "comments and literals must be ignored")

    # ---------------------------------------------------------------- functions
    def test_kept_functions_and_replacements(self):
        """RS-T02 GETDATE/DATEADD/DATEDIFF/CHARINDEX/LEN/TOP are kept with a ledger row; ISNULL/IIF/STRING_AGG/+/N''/NEWID/OBJECT_ID/[brackets]/NOLOCK/TRY_CAST are flagged [RS-10] [RS-11] [RS-12] [RS-13] [RS-14] [RS-15] [RS-16] [RS-17] [RS-18] [RS-19]"""
        kept = "SELECT TOP 5 GETDATE(), DATEADD(day, -1, GETDATE()), DATEDIFF(day, a, b), CHARINDEX('x', s), LEN(s) FROM sales.t;"
        probs, _ = tool.check_text(kept)
        self.assertEqual(rules(probs), set(), probs)
        led = {r["rule"] for r in tool.infer_ledger(kept, kept)}
        self.assertIn("RS-10", led)
        self.assertTrue(all(r["targetTreatment"] == "kept" for r in tool.infer_ledger(kept, kept) if r["rule"] == "RS-10"))
        cases = {"RS-11": "SELECT ISNULL(a, 0) FROM t;", "RS-12": "SELECT IIF(a > 1, 'y', 'n') FROM t;",
                 "RS-13": "SELECT STRING_AGG(name, ',') FROM t;", "RS-14": "SELECT 'a' + b FROM t;", "RS-15": "SELECT NEWID();",
                 "RS-16": "IF OBJECT_ID('dbo.t') IS NOT NULL SELECT 1;", "RS-17": "SELECT [Name] FROM [dbo].[T];",
                 "RS-18": "SELECT a FROM t WITH (NOLOCK);", "RS-19": "SELECT TRY_CAST(a AS INT) FROM t;"}
        for rule, sql in cases.items():
            probs, _ = tool.check_text(sql)
            self.assertIn(rule, rules(probs), f"{rule} not raised for {sql}")
        probs, _ = tool.check_text("SELECT N'x' AS s;")
        self.assertIn("RS-14", rules(probs))
        led = {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger("SELECT ISNULL(a,0), IIF(b,1,2), STRING_AGG(c, ',') FROM t", "SELECT NVL(a,0), CASE WHEN b THEN 1 ELSE 2 END, LISTAGG(c, ',') WITHIN GROUP (ORDER BY c) FROM t")}
        self.assertTrue({("RS-11", "NVL()/COALESCE()"), ("RS-12", "CASE WHEN … END"), ("RS-13", "LISTAGG() WITHIN GROUP")} <= led, led)
        _, warns = tool.check_text("SELECT LISTAGG(c, ',') FROM t GROUP BY k;")
        self.assertIn("RS-13", rules(warns))
        _, warns = tool.check_text("SELECT LISTAGG(c, ',') WITHIN GROUP (ORDER BY c) FROM t GROUP BY k;")
        self.assertNotIn("RS-13", rules(warns))

    # ---------------------------------------------------------------- types
    def test_type_map(self):
        """RS-T03 datatype map: NVARCHAR bytes, MAX/TEXT → VARCHAR(65535), MONEY, BIT, UUID, DATETIME, VARBINARY, XML/ROWVERSION/GEOGRAPHY decisions [RS-20] [RS-21] [RS-22] [RS-23] [RS-24] [RS-25] [RS-26] [RS-27]"""
        def m(raw):
            toks = list(tool.ddl.tokenize(raw)); dt, _ = tool.ddl.parse_datatype(toks, 0); return tool.map_type(dt)
        self.assertEqual(m("NVARCHAR(200)")[0:2], ("VARCHAR(200)", "RS-20"))
        self.assertEqual(m("TINYINT")[0:2], ("SMALLINT", "RS-20"))
        self.assertEqual(m("DECIMAL(40,2)")[0:2], ("DECIMAL(38,2)", "RS-20"))
        self.assertEqual(m("NVARCHAR(MAX)")[0:2], ("VARCHAR(65535)", "RS-21"))
        self.assertEqual(m("TEXT")[0:2], ("VARCHAR(65535)", "RS-21"))
        self.assertEqual(m("MONEY")[0:2], ("DECIMAL(19,4)", "RS-22"))
        self.assertEqual(m("SMALLMONEY")[0], "DECIMAL(10,4)")
        self.assertEqual(m("BIT")[0:2], ("BOOLEAN", "RS-23"))
        self.assertEqual(m("UNIQUEIDENTIFIER")[0:2], ("VARCHAR(36)", "RS-24"))
        self.assertEqual(m("DATETIME2(7)")[0:2], ("TIMESTAMP", "RS-25"))
        self.assertEqual(m("DATETIMEOFFSET")[0:2], ("TIMESTAMPTZ", "RS-25"))
        self.assertEqual(m("VARBINARY(MAX)")[0:2], ("VARBYTE(16777216)", "RS-26"))
        self.assertEqual(m("XML")[0:2], ("SUPER", "RS-27"))
        self.assertEqual(m("ROWVERSION")[1], "RS-27"); self.assertEqual(m("GEOGRAPHY")[0:2], ("GEOGRAPHY", "RS-27"))
        self.assertIsNone(m("CURSOR")[0])
        self.assertEqual(m("INT")[0:2], ("INTEGER", None)); self.assertEqual(m("VARCHAR(50)")[0:2], ("VARCHAR(50)", None))
        # the linter catches residual types in hand-written Redshift SQL
        for rule, sql in {"RS-21": "CREATE TABLE t (n TEXT);", "RS-22": "CREATE TABLE t (m MONEY);", "RS-23": "CREATE TABLE t (b BIT);",
                          "RS-24": "CREATE TABLE t (u UNIQUEIDENTIFIER);", "RS-25": "CREATE TABLE t (d DATETIME2);", "RS-26": "CREATE TABLE t (v VARBINARY(10));"}.items():
            self.assertIn(rule, rules(tool.check_text(sql)[0]), rule)

    # ---------------------------------------------------------------- table design
    def test_convert_ddl_with_design_file(self):
        """RS-T04 convert-ddl: DISTSTYLE/SORTKEY from the design file, indexes → sort-key candidates, PK/FK informational, IDENTITY kept, GETDATE default kept, NEWID default flagged, computed column flagged, CHECK dropped with a ledger row [RS-30] [RS-31] [RS-32] [RS-33] [RS-34] [RS-35] [RS-04]"""
        src = (EX / "01_sales_tables.sqlserver.sql").read_text(encoding="utf-8")
        design = json.loads((EX / "01_sales_tables.design.json").read_text(encoding="utf-8"))
        sql, ledger, warnings, status = tool.convert_ddl(src, design)
        self.assertEqual(status, "PARTIAL")  # NEWID default + computed column need review
        self.assertIn("DISTSTYLE ALL", sql); self.assertIn("COMPOUND SORTKEY(customer_key)", sql)
        self.assertIn("DISTSTYLE KEY\nDISTKEY(customer_key)\nCOMPOUND SORTKEY(sale_date)", sql)
        self.assertIn("CREATE TABLE sales.dim_customer", sql)
        self.assertIn("customer_key INTEGER IDENTITY(1,1) NOT NULL", sql)
        self.assertIn("created_at TIMESTAMP DEFAULT GETDATE() NOT NULL", sql)
        self.assertIn("is_active BOOLEAN DEFAULT TRUE NOT NULL", sql)
        self.assertIn("PRIMARY KEY (customer_key)  -- informational", sql)
        self.assertIn("FOREIGN KEY (customer_key) REFERENCES sales.dim_customer (customer_key)  -- informational", sql)
        self.assertIn("-- CHECK (Region IN('EMEA', 'AMER', 'APAC')) dropped", sql)
        self.assertIn("index IX_FactSales_SaleDate on (sale_date, customer_key) not created: sort-key candidate (RS-31)", sql)
        self.assertIn("TODO: MANUAL REVIEW REQUIRED — computed column line_total", sql)
        self.assertIn("TODO: MANUAL REVIEW REQUIRED — DEFAULT NEWID()", sql)
        by_rule = {}
        for r in ledger:
            by_rule.setdefault(r["rule"], []).append(r)
        for rule in ("RS-04", "RS-15", "RS-20", "RS-21", "RS-22", "RS-23", "RS-24", "RS-25", "RS-30", "RS-31", "RS-32", "RS-33", "RS-34", "RS-35"):
            self.assertIn(rule, by_rule, rule)
        self.assertTrue(any(r["manualReview"] for r in by_rule["RS-31"]), "filtered unique index needs manual review")
        self.assertEqual(len(warnings), 2, warnings)
        probs, _ = tool.check_text(sql)
        self.assertEqual(rules(probs), set(), probs)

    def test_convert_ddl_defaults_to_auto(self):
        """RS-T05 without a design decision every table gets DISTSTYLE AUTO / SORTKEY AUTO and a ledger row; never an invented DISTKEY [RS-30]"""
        sql, ledger, warnings, status = tool.convert_ddl("CREATE TABLE dbo.Orders (OrderId INT NOT NULL PRIMARY KEY, CustomerId INT NOT NULL, Amount DECIMAL(10,2));")
        self.assertEqual(status, "GENERATED"); self.assertEqual(warnings, [])
        self.assertIn("DISTSTYLE AUTO\nSORTKEY AUTO;", sql); self.assertNotIn("DISTKEY", sql)
        self.assertTrue(any(r["rule"] == "RS-30" and "automatic table optimization" in r["reason"] for r in ledger))
        rc, out = run("convert-ddl", str(EX / "01_sales_tables.sqlserver.sql"), "--design", str(EX / "01_sales_tables.design.json"),
                      "--out", str(self.tmp / "o.sql"), "--ledger", str(self.tmp / "l.json"))
        self.assertEqual(rc, 1, out)  # PARTIAL → exit 1
        self.assertIn("ruleLedger", json.loads((self.tmp / "l.json").read_text(encoding="utf-8")))

    # ---------------------------------------------------------------- procedures
    def test_procedure_rules(self):
        """RS-T06 result sets, transactions, TRY/CATCH, dynamic SQL, OUTPUT, cursor loops and RETURN codes are flagged in T-SQL and explained in the ledger of the converted procedure [RS-40] [RS-41] [RS-42] [RS-43] [RS-44] [RS-45] [RS-46]"""
        src = (EX / "03_load_customer_summary.sqlserver.sql").read_text(encoding="utf-8")
        tgt = (EX / "03_load_customer_summary.redshift.sql").read_text(encoding="utf-8")
        probs, _ = tool.check_text(src)
        for rule in ("RS-41", "RS-42", "RS-44", "RS-46", "RS-50", "RS-55", "RS-16", "RS-18"):
            self.assertIn(rule, rules(probs), rule)
        self.assertIn("RS-43", rules(tool.check_text("EXEC sp_executesql @sql;")[0]))
        self.assertIn("RS-45", rules(tool.check_text("WHILE @@FETCH_STATUS = 0 BEGIN FETCH NEXT FROM c INTO @x; END")[0]))
        self.assertIn("RS-40", rules(tool.check_text("CREATE FUNCTION f() RETURNS TABLE AS RETURN SELECT 1;")[0]))
        probs, warns = tool.check_text(tgt, src)
        self.assertEqual(rules(probs), set(), probs)
        self.assertIn("RS-42", rules(warns))
        led = {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger(src, tgt)}
        for want in (("RS-40", "INOUT refcursor"), ("RS-41", "implicit transaction of the CALL"), ("RS-42", "EXCEPTION WHEN OTHERS"),
                     ("RS-44", "INOUT argument"), ("RS-46", "INOUT return-code argument"), ("RS-16", "GET DIAGNOSTICS n := ROW_COUNT"),
                     ("RS-50", "UPDATE + INSERT … WHERE NOT EXISTS"), ("RS-55", "CREATE TEMP TABLE t AS")):
            self.assertIn(want, led, want)
        led = {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger("EXEC sp_executesql @s", "EXECUTE v_sql")}
        self.assertIn(("RS-43", "EXECUTE with quote_ident/quote_literal"), led)

    # ---------------------------------------------------------------- DML and views
    def test_dml_and_view_rules(self):
        """RS-T07 MERGE restrictions, duplicate-source warning, late-binding qualification, recursive CTE rules, UPDATE FROM JOIN, SELECT INTO, TOP+LIMIT, QUALIFY [RS-50] [RS-51] [RS-52] [RS-53] [RS-54] [RS-55] [RS-56] [RS-57]"""
        self.assertIn("RS-50", rules(tool.check_text("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a WHEN NOT MATCHED BY SOURCE THEN DELETE;")[0]))
        self.assertIn("RS-50", rules(tool.check_text("MERGE INTO sales.t USING sales.t ON 1 = 1 WHEN MATCHED THEN DELETE;")[0]))
        self.assertIn("RS-50", rules(tool.check_text("WITH s AS (SELECT 1 AS id) MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE;")[0]))
        ok = "MERGE INTO sales.t USING sales.stage s ON sales.t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a WHEN NOT MATCHED THEN INSERT (id, a) VALUES (s.id, s.a);"
        probs, warns = tool.check_text(ok)
        self.assertEqual(rules(probs), set()); self.assertIn("RS-51", rules(warns))
        _, warns = tool.check_text("MERGE INTO sales.t USING (SELECT id, a FROM sales.stage QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY ts DESC) = 1) s ON sales.t.id = s.id WHEN MATCHED THEN DELETE;")
        self.assertNotIn("RS-51", rules(warns))
        self.assertIn("RS-52", rules(tool.check_text("CREATE VIEW sales.v AS SELECT a FROM t JOIN sales.u ON u.id = t.id WITH NO SCHEMA BINDING;")[0]))
        self.assertEqual(rules(tool.check_text("CREATE VIEW sales.v AS SELECT a FROM sales.t JOIN sales.u ON u.id = t.id WITH NO SCHEMA BINDING;")[0]), set())
        self.assertIn("RS-53", rules(tool.check_text("CREATE VIEW sales.v AS WITH RECURSIVE c(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM c WHERE id < 3) SELECT id FROM c WITH NO SCHEMA BINDING;")[0]))
        self.assertIn("RS-54", rules(tool.check_text("UPDATE t SET a = s.a FROM t JOIN s ON s.id = t.id;")[0]))
        self.assertIn("RS-55", rules(tool.check_text("SELECT a INTO #tmp FROM t;")[0]))
        self.assertIn("RS-56", rules(tool.check_text("SELECT TOP 10 a FROM t ORDER BY a LIMIT 10;")[0]))
        src = (EX / "04_org_chart.sqlserver.sql").read_text(encoding="utf-8"); tgt = (EX / "04_org_chart.redshift.sql").read_text(encoding="utf-8")
        led = {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger(src, tgt)}
        self.assertIn(("RS-53", "WITH RECURSIVE cte(cols)"), led); self.assertIn(("RS-57", "QUALIFY"), led)
        led = {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger("UPDATE t SET a = 1 FROM t JOIN s ON s.id = t.id", "UPDATE t SET a = 1 FROM s WHERE s.id = t.id")}
        self.assertIn(("RS-54", "UPDATE … FROM s WHERE"), led)
        led = {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger("CREATE VIEW v AS SELECT 1 AS a", "CREATE VIEW s.v AS SELECT 1 AS a WITH NO SCHEMA BINDING")}
        self.assertIn(("RS-52", "late-binding view"), led)

    # ---------------------------------------------------------------- collation, security
    def test_collation_and_security(self):
        """RS-T08 collation made explicit, identity functions → RLS policy, credentials/UNLOAD/COPY/CREATE USER in generated SQL are refused or flagged [RS-60] [RS-61] [RS-62]"""
        sql, ledger, _, _ = tool.convert_ddl("CREATE TABLE dbo.T (Name NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL, Code VARCHAR(10) COLLATE Latin1_General_CS_AS);")
        self.assertIn("name VARCHAR(50) COLLATE CASE_INSENSITIVE NOT NULL", sql)
        self.assertNotIn("code VARCHAR(10) COLLATE", sql)
        self.assertEqual(len([r for r in ledger if r["rule"] == "RS-60"]), 2)
        _, warns = tool.check_text("SELECT a FROM sales.t WHERE a ILIKE 'x%';"); self.assertIn("RS-60", rules(warns))
        led = {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger("SELECT 1 WHERE n LIKE 'a%'", "SELECT 1 WHERE LOWER(n) LIKE 'a%'")}
        self.assertIn(("RS-60", "LOWER()/CASE_INSENSITIVE"), led)
        src = (EX / "05_secure_employee_view.sqlserver.sql").read_text(encoding="utf-8"); tgt = (EX / "05_secure_employee_view.redshift.sql").read_text(encoding="utf-8")
        self.assertIn("RS-61", rules(tool.check_text(src)[0]))
        probs, _ = tool.check_text(tgt, src); self.assertEqual(rules(probs), set(), probs)
        self.assertIn(("RS-61", "RLS policy"), {(r["rule"], r["targetTreatment"]) for r in tool.infer_ledger(src, tgt)})
        probs, _ = tool.check_text("COPY sales.t FROM 's3://b/k' CREDENTIALS 'aws_access_key_id=AKIAIOSFODNN7EXAMPLE;aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';")
        self.assertTrue(rules(probs) & {"SEC-03", "RS-62"}, probs)
        probs, warns = tool.check_text("UNLOAD ('select * from sales.t') TO 's3://b/x' IAM_ROLE 'arn:aws:iam::123456789012:role/r';")
        self.assertIn("RS-62", rules(warns) | rules(probs))
        probs, _ = tool.check_text("CREATE USER etl PASSWORD 'Str0ngPassw0rd!';")
        self.assertIn("RS-62", rules(probs))
        probs, _ = tool.check_text("SELECT 1; UNLOAD ('select * from sales.t') TO 's3://b/x' IAM_ROLE 'arn:aws:iam::123456789012:role/r';", "SELECT 1;")
        self.assertIn("SEC-09", rules(probs), "introduced data movement must be reported against the source")

    # ---------------------------------------------------------------- examples
    def test_worked_examples_are_clean(self):
        """RS-T09 every worked example: the SQL Server side raises problems, the Redshift side raises none and the ledger is non-empty [RS-10] [RS-52] [RS-53] [RS-61]"""
        for n in EXAMPLES:
            src = (EX / f"{n}.sqlserver.sql").read_text(encoding="utf-8"); tgt = (EX / f"{n}.redshift.sql").read_text(encoding="utf-8")
            self.assertTrue(tool.check_text(src)[0], f"{n}: source should raise problems")
            probs, _ = tool.check_text(tgt, src)
            self.assertEqual(rules(probs), set(), f"{n}: {probs}")
            self.assertTrue(tool.infer_ledger(src, tgt), f"{n}: empty ledger")
            rc, out = run("check", str(EX / f"{n}.redshift.sql"), "--source", str(EX / f"{n}.sqlserver.sql"), "--json")
            self.assertEqual(rc, 0, out)

    # ---------------------------------------------------------------- execution evidence
    def test_split_statements(self):
        """RS-T10 statements are split on top-level semicolons only (strings, comments and $$ bodies preserved) [RS-70]"""
        parts = tool.split_statements("SELECT ';' AS a; -- c;\nCREATE PROCEDURE p() AS $$ BEGIN SELECT 1; SELECT 2; END; $$ LANGUAGE plpgsql; /* x; */ SELECT 2")
        self.assertEqual(len(parts), 3, parts)
        self.assertTrue(parts[1].startswith("CREATE PROCEDURE") and "SELECT 2; END" in parts[1])

    def test_run_data_api_guardrails(self):
        """RS-T11 run: only test/dev/sandbox/local databases, security scan first, batch-execute-statement via the Data API with a client token, describe-statement polled, evidence V-004 written; unavailable service degrades to unexecuted [RS-70]"""
        f = self.tmp / "run.sql"; f.write_text("CREATE TABLE public.t (id INTEGER);\nSELECT 1 AS ok;", encoding="utf-8")
        rc, out = run("run", str(f), "--database", "prod_dw", "--workgroup-name", "wg"); self.assertEqual(rc, 3, out)
        bad = self.tmp / "bad.sql"; bad.write_text("COPY public.t FROM 's3://b/k' CREDENTIALS 'aws_access_key_id=AKIAIOSFODNN7EXAMPLE;aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';", encoding="utf-8")
        with StubAws(self.tmp) as st:
            rc, out = run("run", str(bad), "--database", "dw_test", "--workgroup-name", "wg"); self.assertEqual(rc, 3, out)
            self.assertEqual(st.calls(), [], "refused SQL must never reach AWS")
            ev = self.tmp / "evidence.json"
            rc, out = run("run", str(f), "--database", "dw_test", "--workgroup-name", "wg", "--evidence", str(ev)); self.assertEqual(rc, 0, out)
            calls = st.calls()
            self.assertEqual(calls[0]["argv"][:2], ["redshift-data", "batch-execute-statement"])
            self.assertIn("--client-token", calls[0]["argv"]); self.assertIn("--workgroup-name", calls[0]["argv"])
            self.assertEqual(calls[0]["argv"][calls[0]["argv"].index("--sqls") + 1], "CREATE TABLE public.t (id INTEGER)")
            self.assertTrue(any(c["argv"][:2] == ["redshift-data", "describe-statement"] for c in calls))
            e = json.loads(ev.read_text(encoding="utf-8"))
            self.assertEqual(e["status"], "FINISHED"); self.assertEqual(e["evidence"]["V-004"]["status"], "PASS"); self.assertEqual(e["statements"], 2)
        with StubAws(self.tmp, STUB_REDSHIFT_FAIL="ERROR: relation \"public.t\" already exists"):
            rc, out = run("run", str(f), "--database", "dw_test", "--cluster-identifier", "c1"); self.assertEqual(rc, 1, out)
            self.assertIn("already exists", out)
        with StubAws(self.tmp, scenario="down"):
            rc, out = run("run", str(f), "--database", "dw_test", "--workgroup-name", "wg"); self.assertEqual(rc, 1, out)
            self.assertIn("UNAVAILABLE", out)
        audit = (_STATE / "audit")
        text = "".join(p.read_text(encoding="utf-8") for p in audit.rglob("*.jsonl")) if audit.exists() else ""
        self.assertIn("redshift.execute", text); self.assertIn("security.refused", text)
        self.assertNotIn("wJalrXUtnFEMI", text, "secrets must never reach the audit log")

    def test_package(self):
        """RS-T12 package writes request, output contract, ledger, validation manifest and hashed files; execution evidence upgrades GENERATED to VALIDATED [RS-70]"""
        src, tgt = EX / "02_customer_summary_view.sqlserver.sql", EX / "02_customer_summary_view.redshift.sql"
        pkg = self.tmp / "pkg"
        rc, out = run("package", str(src), str(tgt), "--out", str(pkg)); self.assertEqual(rc, 0, out)
        o = json.loads((pkg / "output.json").read_text(encoding="utf-8"))
        self.assertEqual(o["status"], "GENERATED"); self.assertTrue(o["analysis"]["ruleLedger"])
        self.assertIn("V-004", [x["id"] for x in o["validation"]["unexecutedChecks"]])
        self.assertTrue((pkg / "rule-ledger.md").exists() and (pkg / "manifest.json").exists())
        ev = self.tmp / "ev.json"; ev.write_text(json.dumps({"evidence": {"V-004": {"status": "PASS", "evidence": "stmt-0001 FINISHED"}}}), encoding="utf-8")
        rc, out = run("package", str(src), str(tgt), "--out", str(self.tmp / "pkg2"), "--evidence", str(ev)); self.assertEqual(rc, 0, out)
        self.assertEqual(json.loads((self.tmp / "pkg2" / "output.json").read_text(encoding="utf-8"))["status"], "VALIDATED")
        rc, out = run("package", str(src), str(src), "--out", str(self.tmp / "pkg3")); self.assertEqual(rc, 1, out)
        o = json.loads((self.tmp / "pkg3" / "output.json").read_text(encoding="utf-8"))
        self.assertEqual(o["status"], "PARTIAL"); self.assertIn("STATIC_VALIDATION_FAILED", o["analysis"]["stopCodes"])

    @unittest.skipUnless(os.environ.get("REDSHIFT_DATABASE") and (os.environ.get("REDSHIFT_WORKGROUP") or os.environ.get("REDSHIFT_CLUSTER")),
                         "set REDSHIFT_DATABASE (name containing test/dev/sandbox) and REDSHIFT_WORKGROUP or REDSHIFT_CLUSTER for a live run")
    def test_live_redshift(self):
        """RS-T13 live: the worked view example executes on the configured test Redshift through the Data API [RS-70]"""
        os.environ.pop("MIGRATION_OFFLINE", None)
        f = self.tmp / "live.sql"; f.write_text("SELECT 1 AS ok;", encoding="utf-8")
        args = ["--database", os.environ["REDSHIFT_DATABASE"]]
        args += ["--workgroup-name", os.environ["REDSHIFT_WORKGROUP"]] if os.environ.get("REDSHIFT_WORKGROUP") else ["--cluster-identifier", os.environ["REDSHIFT_CLUSTER"]]
        rc, out = run("run", str(f), *args); self.assertEqual(rc, 0, out)


class TaggedResult(unittest.TextTestResult):
    lines = []

    def addSuccess(self, test):
        super().addSuccess(test); self.lines.append(("PASS", test))

    def addFailure(self, test, err):
        super().addFailure(test, err); self.lines.append(("FAIL", test))

    def addError(self, test, err):
        super().addError(test, err); self.lines.append(("ERROR", test))

    def addSkip(self, test, reason):
        super().addSkip(test, reason); self.lines.append(("SKIP", test))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--results"); a = ap.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RedshiftTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=TaggedResult).run(suite)
    if a.results:
        with open(a.results, "a", encoding="utf-8") as f:
            for status, test in TaggedResult.lines:
                f.write(f"{status}\tredshift\t{(test.shortDescription() or test.id()).strip()}\n")
    sys.exit(0 if result.wasSuccessful() else 1)
