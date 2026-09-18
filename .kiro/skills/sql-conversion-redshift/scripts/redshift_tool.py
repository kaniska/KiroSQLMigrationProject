#!/usr/bin/env python3
"""
redshift_tool.py — deterministic helper for converting SQL Server objects to Amazon Redshift.

  convert-ddl <tsql.sql> [--design design.json] [--out out.sql] [--ledger out.json]
        T-SQL CREATE TABLE → Redshift DDL with the approved type map, identity, defaults,
        informational constraints, DISTSTYLE/SORTKEY from the design file (else AUTO), index
        columns recorded as sort-key candidates. Columns that cannot be mapped are flagged, never dropped.
  check <converted.sql> [--source tsql.sql] [--json]
        Redshift static review: residual T-SQL, unsupported features (triggers, sequences, CHECK,
        table functions, table variables, FOR XML, bare TEXT …), late-binding view rules, MERGE
        restrictions, security findings (SEC-01..04), and SEC-09 constructs introduced vs the source.
  ledger <tsql.sql> <converted.sql> [--json]
        infers the rule ledger (kept / replaced / removed constructs) between source and target.
  run <converted.sql> --database DB (--workgroup-name WG | --cluster-identifier ID) [--secret-arn ARN] [--timeout 120]
        executes on Amazon Redshift through the Data API (batch-execute-statement): only databases
        whose name contains test/dev/sandbox/local, only after a security scan, fully audited.
  package <tsql.sql> <converted.sql> --out DIR [--classification FILE] [--evidence run.json]
        writes the conversion package (request, output contract, ledger, validation manifest, files, hashes).

Exit codes: 0 ok · 1 problems · 2 usage · 3 security refusal.
"""
import argparse
import json
import os
import pathlib
import re
import sys
import time

_KIT = pathlib.Path(os.environ.get("MIGKIT_PATH") or pathlib.Path(__file__).resolve().parents[2] / "sql-conversion" / "scripts")
sys.path.insert(0, str(_KIT))
try:
    from migkit import contract, ddl, security
    from migkit.audit import AuditLogger, now_rfc3339, sha256_bytes
    from migkit.platform_compat import utf8_stdio
except ImportError as _ex:
    sys.stderr.write(f"ERROR: migkit not found at {_KIT} ({_ex}); install the sql-conversion skill next to this one\n")
    sys.exit(2)

TOOL_VERSION = "1.0.0"
LOG = AuditLogger("redshift_tool")
EXIT_SECURITY = 3
TEST_DB = re.compile(r"(test|dev|sandbox|local)", re.I)
MAX_DATA_API_BYTES = 200 * 1024


class SecurityRefusal(SystemExit):
    def __init__(self, message, findings=()):
        LOG.log("security.refused", message, "ERROR", findings=[{k: f.get(k) for k in ("rule", "name", "severity", "line")} for f in list(findings)[:50]])
        sys.stderr.write(f"REFUSED (security): {message}\n" + "".join(f"  {f['rule']} {f['severity']:<8} {f['name']} line {f.get('line', 0)} — {f['message']}\n" for f in list(findings)[:20]))
        super().__init__(EXIT_SECURITY)


# ---------------------------------------------------------------- naming and types
def snake(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_]+", "_", name)
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", s)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", s)
    return re.sub(r"_+", "_", s).strip("_").lower()


def map_type(dt: dict) -> tuple:
    """(redshift_type, rule, note) — rule None when the type is kept 1:1."""
    b, ln, p, s = dt["base"], dt["length"], dt["precision"], dt["scale"]
    if b in ("int", "integer"):
        return "INTEGER", None, ""
    if b == "bigint":
        return "BIGINT", None, ""
    if b == "smallint":
        return "SMALLINT", None, ""
    if b == "tinyint":
        return "SMALLINT", "RS-20", "TINYINT 0–255 range is not enforced (no CHECK on Redshift)"
    if b == "bit":
        return "BOOLEAN", "RS-23", "1/0 literals become TRUE/FALSE"
    if b in ("decimal", "numeric", "dec"):
        pp, ss = min(p or 18, 38), min(s or 0, 37)
        return f"DECIMAL({pp},{ss})", ("RS-20" if (p or 18) > 38 else None), ("precision capped at 38" if (p or 18) > 38 else "")
    if b == "money":
        return "DECIMAL(19,4)", "RS-22", "no money type"
    if b == "smallmoney":
        return "DECIMAL(10,4)", "RS-22", "no money type"
    if b == "float":
        return ("REAL" if (p and p <= 24) else "DOUBLE PRECISION"), None, ""
    if b == "real":
        return "REAL", None, ""
    if b in ("char", "nchar"):
        n = ln if isinstance(ln, int) else 1
        return f"CHAR({n})", ("RS-20" if b == "nchar" else None), ("CHAR holds single-byte characters only; use VARCHAR(4n) for multibyte text" if b == "nchar" else "")
    if b in ("varchar", "nvarchar", "sysname"):
        if b == "sysname":
            return "VARCHAR(128)", None, ""
        if ln == "MAX":
            return "VARCHAR(65535)", "RS-21", "MAX → VARCHAR(65535) (bytes)"
        n = ln if isinstance(ln, int) else 256
        return f"VARCHAR({n})", ("RS-20" if b == "nvarchar" else None), ("length is bytes on Redshift: multiply by up to 4 for non-Latin text" if b == "nvarchar" else "")
    if b in ("text", "ntext"):
        return "VARCHAR(65535)", "RS-21", "bare TEXT would become VARCHAR(256)"
    if b == "date":
        return "DATE", None, ""
    if b == "time":
        return "TIME", None, ""
    if b in ("datetime", "datetime2", "smalldatetime"):
        return "TIMESTAMP", "RS-25", "microsecond precision; SQL Server DATETIME 1/300 s rounding is lost"
    if b == "datetimeoffset":
        return "TIMESTAMPTZ", "RS-25", "stored as UTC; the original offset is lost"
    if b == "uniqueidentifier":
        return "VARCHAR(36)", "RS-24", "no UUID type"
    if b in ("varbinary", "binary", "image"):
        n = 16777216 if ln == "MAX" or b == "image" else (ln if isinstance(ln, int) else 64000)
        return f"VARBYTE({n})", "RS-26", "VARBYTE cannot be used in Python/Lambda UDFs"
    if b == "xml":
        return "SUPER", "RS-27", "XML stored as SUPER/VARCHAR; XML methods must be rewritten"
    if b in ("geography", "geometry"):
        return b.upper(), "RS-27", "spatial functions differ; representation decision required"
    if b in ("rowversion", "timestamp"):
        return "VARBYTE(8)", "RS-27", "ROWVERSION has no equivalent: version column maintained by the load"
    if b == "hierarchyid":
        return "VARCHAR(4000)", "RS-27", "HIERARCHYID stored as its string path; hierarchy functions must be rewritten"
    if b == "sql_variant":
        return "SUPER", "RS-27", "SQL_VARIANT → SUPER; type per row must be decided"
    return None, "RS-27", f"no approved mapping for {dt['raw']}"


def map_default(expr: str | None) -> tuple:
    if expr is None:
        return None, None, ""
    e = expr.strip()
    inner = e[1:-1].strip() if e.startswith("(") and e.endswith(")") else e
    up = inner.upper().replace(" ", "")
    if up in ("GETDATE()", "SYSDATETIME()", "CURRENT_TIMESTAMP"):
        return "GETDATE()", "RS-34", "statement start time (SYSDATE = transaction start)"
    if up in ("GETUTCDATE()", "SYSUTCDATETIME()"):
        return "GETDATE()", "RS-34", "UTC default: set the session/cluster time zone to UTC; GETDATE() is session-time"
    if up in ("NEWID()", "NEWSEQUENTIALID()"):
        return None, "RS-15", "NEWID() default has no equivalent: generate the key upstream (manual review)"
    if up in ("SUSER_SNAME()", "ORIGINAL_LOGIN()", "USER_NAME()"):
        return "CURRENT_USER", "RS-61", "identity default mapped to CURRENT_USER — approve the identity mapping"
    return inner, None, ""


def convert_ddl(text: str, design: dict | None = None):
    """→ (sql, ledger_rows, warnings, status)"""
    design = design or {}
    tables = ddl.parse_tables(text, "tsql")
    ledger = contract.RuleLedger()
    warnings, out, status = [], [], "GENERATED"
    for t in tables:
        schema = design.get("schema", "public") if t["schema"] is None or t["schema"].lower() == "dbo" else snake(t["schema"])
        tname = snake(t["name"])
        key = f"{t['schema'] or 'dbo'}.{t['name']}"
        d = design.get("tables", {}).get(key) or design.get("tables", {}).get(t["name"]) or {}
        cols = []
        for c in t["columns"]:
            cname = snake(c["name"])
            if c["computed"]:
                warnings.append(f"{key}.{c['name']}: computed column ({c['computed']}) — Redshift has no generated columns; materialize it in the load or in a view (RS-35)")
                ledger.add("RS-35", f"{c['name']} AS {c['computed']}", "omitted from the table; TODO comment", "no generated columns", manual=True)
                cols.append(f"    -- TODO: MANUAL REVIEW REQUIRED — computed column {cname} AS {c['computed']} (RS-35)")
                status = "PARTIAL"; continue
            rtype, rule, note = map_type(c["datatype"])
            if rtype is None:
                warnings.append(f"{key}.{c['name']}: {note} (RS-27)")
                ledger.add("RS-27", f"{c['name']} {c['datatype']['raw']}", "no mapping", note, manual=True)
                cols.append(f"    -- TODO: MANUAL REVIEW REQUIRED — {cname} {c['datatype']['raw']}: {note}")
                status = "PARTIAL"; continue
            if rule:
                ledger.add(rule, f"{c['name']} {c['datatype']['raw']}", rtype, note, manual=rule == "RS-27")
                if rule == "RS-27":
                    status = "PARTIAL"; warnings.append(f"{key}.{c['name']}: {note} (RS-27)")
            line = f"    {cname} {rtype}"
            if c["collation"]:  # Redshift syntax: COLLATE directly after the data type
                ci = "_ci" in c["collation"].lower()
                line += " COLLATE CASE_INSENSITIVE" if ci else ""
                ledger.add("RS-60", f"COLLATE {c['collation']}", "COLLATE CASE_INSENSITIVE" if ci else "case-sensitive (default)", "column collation made explicit")
            if c["identity"]:
                seed, inc = c["identity"]["seed"], c["identity"]["increment"]
                if rtype not in ("INTEGER", "BIGINT"):
                    warnings.append(f"{key}.{c['name']}: IDENTITY requires INT or BIGINT on Redshift (RS-33)")
                line += f" IDENTITY({seed},{inc})"
                ledger.add("RS-33", f"IDENTITY({seed},{inc})", f"IDENTITY({seed},{inc})", "values unique but not contiguous and not in load order; use GENERATED BY DEFAULT AS IDENTITY when explicit keys must load")
            dflt, drule, dnote = map_default(c["default"])
            todo = ""
            if c["default"] is not None:
                if dflt is None:
                    warnings.append(f"{key}.{c['name']}: default {c['default']} — {dnote}")
                    ledger.add(drule, f"DEFAULT {c['default']}", "no default", dnote, manual=True); status = "PARTIAL"
                    todo = f" /* TODO: MANUAL REVIEW REQUIRED — DEFAULT {c['default']} ({drule}) */"
                else:
                    if rtype == "BOOLEAN" and dflt in ("1", "0"):
                        dflt = "TRUE" if dflt == "1" else "FALSE"
                    line += f" DEFAULT {dflt}"
                    if drule:
                        ledger.add(drule, f"DEFAULT {c['default']}", f"DEFAULT {dflt}", dnote)
            if not c["nullable"]:
                line += " NOT NULL"
            if c["unresolved"]:
                warnings.append(f"{key}.{c['name']}: unparsed column options {c['unresolved']} (manual review)")
                todo += f" /* TODO: MANUAL REVIEW REQUIRED — {'; '.join(c['unresolved'])} */"; status = "PARTIAL"
            cols.append(line + todo)
        for con in t["constraints"]:
            cn = snake(con["name"]) if con["name"] else None
            if con["type"] == "CHECK":
                ledger.add("RS-04", f"CHECK {con['expression']}", "dropped", "CHECK constraints are unsupported; validate with a query (V-009)", manual=True)
                cols.append(f"    -- CHECK ({con['expression']}) dropped: unsupported on Redshift (RS-04); validate with a query")
                continue
            colsn = ", ".join(snake(x) for x in con["columns"])
            if con["type"] == "FOREIGN KEY":
                rs, rn = ddl.split_qualified(con["ref_table"])
                ref = f"{design.get('schema', 'public') if (rs or 'dbo').lower() == 'dbo' else snake(rs)}.{snake(rn)}"
                cols.append(f"    {'CONSTRAINT ' + cn + ' ' if cn else ''}FOREIGN KEY ({colsn}) REFERENCES {ref} ({', '.join(snake(x) for x in con['ref_columns'])})  -- informational")
            else:
                cols.append(f"    {'CONSTRAINT ' + cn + ' ' if cn else ''}{con['type']} ({colsn})  -- informational, not enforced")
            ledger.add("RS-32", f"{con['type']} {con['name'] or ''}", "kept (informational)", "Redshift does not enforce PK/UNIQUE/FK; prove uniqueness with V-014")
        dist = []
        if d.get("diststyle"):
            dist.append(f"DISTSTYLE {d['diststyle'].upper()}")
            if d["diststyle"].upper() == "KEY" and d.get("distkey"):
                dist.append(f"DISTKEY({snake(d['distkey'])})")
        else:
            dist.append("DISTSTYLE AUTO")
        if d.get("sortkey"):
            style = (d.get("sortstyle") or "COMPOUND").upper()
            dist.append(f"{style} SORTKEY({', '.join(snake(x) for x in d['sortkey'])})")
        else:
            dist.append("SORTKEY AUTO")
        ledger.add("RS-30", "table design", " ".join(dist), "design file decision" if d else "no design decision supplied: automatic table optimization")
        for ix in t["indexes"]:
            ledger.add("RS-31", f"INDEX {ix['name']} ({', '.join(ix['columns'])}){' WHERE ' + ix['filter'] if ix['filter'] else ''}", "not created; sort-key candidate",
                       "Redshift has no indexes" + ("; a filtered unique index cannot be expressed" if ix["filter"] else ""), manual=bool(ix["unique"] and ix["filter"]))
            cols.append(f"    -- index {ix['name']} on ({', '.join(snake(x) for x in ix['columns'])}) not created: sort-key candidate (RS-31)")
        items = [x for x in cols if not x.lstrip().startswith("--")]
        body = []
        for i, line in enumerate(items):  # the comma must precede any trailing line comment
            txt, _, cmt = line.partition("  -- ")
            body.append(txt + ("," if i < len(items) - 1 else "") + (f"  -- {cmt}" if cmt else ""))
        out.append(f"CREATE TABLE {schema}.{tname} (\n" + "\n".join(body) + "\n)\n" + "\n".join(dist) + ";")
        # comment-only lines must not break the column list: re-emit them after the statement
        comments = [x.strip() for x in cols if x.lstrip().startswith("--")]
        if comments:
            out[-1] = out[-1] + "\n" + "\n".join(comments)
        for u in t["unresolved"]:
            warnings.append(f"{key}: unparsed table item — {u}"); status = "PARTIAL"
    header = (f"-- Generated by redshift_tool.py convert-ddl v{TOOL_VERSION} on {now_rfc3339()}\n"
              f"-- Source sha256 {sha256_bytes(text.encode('utf-8'))}\n-- Rules: .kiro/steering/redshift.md · ledger in the conversion package\n\n")
    return header + "\n\n".join(out) + "\n", ledger.to_list(), warnings, status


# ---------------------------------------------------------------- static review
CHECKS = [  # (rule, severity, regex, message) applied to comment/literal-stripped code
    ("RS-01", "problem", r"\bCREATE\s+(OR\s+REPLACE\s+)?TRIGGER\b", "triggers are not supported on Redshift"),
    ("RS-02", "problem", r"\bRETURNS\s+(TABLE|SETOF|@\w+\s+TABLE)\b", "table-valued functions are not supported (scalar UDFs only)"),
    ("RS-03", "problem", r"\bDECLARE\s+@\w+\s+TABLE\b|\bREADONLY\b", "table variables / table-valued parameters are not supported: CREATE TEMP TABLE"),
    ("RS-04", "problem", r"\bCHECK\s*\(", "CHECK constraints are not supported: drop and validate with a query"),
    ("RS-05", "problem", r"\bCREATE\s+SEQUENCE\b|\bNEXT\s+VALUE\s+FOR\b|\b(BIG|SMALL)?SERIAL\b|\bnextval\s*\(", "sequences are not supported: IDENTITY or upstream keys"),
    ("RS-06", "problem", r"\bFOR\s+(XML|JSON)\b|\bOPENJSON\s*\(|\.(value|query|nodes|exist)\s*\(", "FOR XML/JSON and XML methods are not supported: SUPER + JSON functions"),
    ("RS-07", "problem", r"\bDECLARE\s+\w+\s+CURSOR\b[\s\S]*\bDECLARE\s+\w+\s+CURSOR\b", "more than one cursor: only one open cursor per session"),
    ("RS-08", "problem", r"\bINSTEAD\s+OF\b|\bWITH\s+CHECK\s+OPTION\b", "views are read-only on Redshift"),
    ("RS-09", "problem", r"\b(OPENQUERY|OPENROWSET|OPENDATASOURCE)\s*\(|\bxp_\w+|\bEXTERNAL\s+NAME\b", "linked servers / CLR have no equivalent"),
    ("RS-11", "problem", r"\bISNULL\s*\(", "ISNULL → NVL/COALESCE"),
    ("RS-12", "problem", r"\bIIF\s*\(", "IIF → CASE WHEN … END or DECODE"),
    ("RS-13", "problem", r"\bSTRING_AGG\s*\(", "STRING_AGG → LISTAGG(...) WITHIN GROUP (ORDER BY ...)"),
    ("RS-14", "problem", r"(?<![\w'])N'", "N'' literal prefix is not Redshift SQL"),
    ("RS-14", "problem", r"'\s*\+\s*[\w'(]|[\w')]\s*\+\s*'", "string concatenation with + → ||"),
    ("RS-15", "problem", r"\bNEW(SEQUENTIAL)?ID\s*\(", "NEWID() has no equivalent: generate keys upstream"),
    ("RS-16", "problem", r"\bOBJECT_ID\s*\(|@@ROWCOUNT|\bSCOPE_IDENTITY\s*\(|@@IDENTITY|\bIDENT_CURRENT\s*\(", "SQL Server system functions: use SVV_/PG_ catalog queries or GET DIAGNOSTICS"),
    ("RS-17", "problem", r"\[[A-Za-z_][\w ]*\]", "[bracketed identifier] → unquoted lower-case name"),
    ("RS-18", "problem", r"\bSET\s+NOCOUNT\b|\bWITH\s*\(\s*(NOLOCK|UPDLOCK|TABLOCK|ROWLOCK|HOLDLOCK)|\bOPTION\s*\(|^\s*GO\s*$|^\s*USE\s+\[?\w+\]?\s*$", "SQL Server session/hint syntax must be removed"),
    ("RS-19", "problem", r"\bTRY_(CAST|CONVERT|PARSE)\s*\(", "TRY_CAST/TRY_CONVERT have no equivalent: guard with CASE"),
    ("RS-21", "problem", r"\b(TEXT|NTEXT)\b(?!\s*\()", "bare TEXT becomes VARCHAR(256): use VARCHAR(n) or VARCHAR(65535)"),
    ("RS-22", "problem", r"\b(SMALL)?MONEY\b", "MONEY → DECIMAL(19,4)"),
    ("RS-23", "problem", r"\bBIT\b(?!\s*\()", "BIT → BOOLEAN"),
    ("RS-24", "problem", r"\bUNIQUEIDENTIFIER\b|\bUUID\b", "no UUID type: VARCHAR(36)"),
    ("RS-25", "problem", r"\b(DATETIME2?|SMALLDATETIME|DATETIMEOFFSET)\b", "DATETIME types → TIMESTAMP / TIMESTAMPTZ"),
    ("RS-26", "problem", r"\b(VARBINARY|IMAGE|BYTEA)\b", "binary → VARBYTE"),
    ("RS-26", "problem", r"\bNVARCHAR\b|\bNCHAR\b", "NVARCHAR/NCHAR → VARCHAR/CHAR (bytes)"),
    ("RS-40", "problem", r"\bRETURNS\s+TABLE\b|\bRETURN\s+QUERY\b", "RETURN QUERY / RETURNS TABLE: return results through an INOUT refcursor or a temp table"),
    ("RS-41", "problem", r"\bBEGIN\s+TRAN(SACTION)?\b|\bSET\s+XACT_ABORT\b|\bSAVE\s+TRAN", "T-SQL transaction control: implicit transaction per CALL, COMMIT/ROLLBACK only outside a transaction block, NONATOMIC for per-statement commits"),
    ("RS-42", "problem", r"\bBEGIN\s+TRY\b|\bRAISERROR\s*\(|\bTHROW\b|\bBEGIN\s+CATCH\b", "TRY/CATCH/RAISERROR/THROW → EXCEPTION WHEN OTHERS / RAISE (limited)"),
    ("RS-43", "problem", r"\bsp_executesql\b|\bEXEC(UTE)?\s*\(\s*@", "dynamic SQL → EXECUTE with quote_ident/quote_literal"),
    ("RS-44", "problem", r"@\w+\s+[\w()]+\s+(OUT|OUTPUT)\b", "OUTPUT parameters → INOUT arguments"),
    ("RS-45", "problem", r"\bWHILE\s+@@FETCH_STATUS\b|\bFETCH\s+NEXT\s+FROM\b", "row-by-row cursor loops must become set-based SQL"),
    ("RS-46", "problem", r"\bRETURN\s+-?\d+\s*;?\s*$", "RETURN <code> is not supported: INOUT return-code argument or RAISE"),
    ("RS-50", "problem", r"\bWHEN\s+NOT\s+MATCHED\s+BY\s+SOURCE\b|\bWHEN\s+MATCHED\s+AND\b|\bWITH\b[\s\S]{0,400}\bMERGE\s+INTO\b", "Redshift MERGE: one WHEN MATCHED (UPDATE|DELETE), one WHEN NOT MATCHED (INSERT), no WITH clause"),
    ("RS-54", "problem", r"\bUPDATE\s+\w+\s+SET\b[\s\S]{0,300}\bFROM\b[\s\S]{0,200}\bJOIN\b|\bDELETE\s+\w+\s+FROM\b[\s\S]{0,200}\bJOIN\b", "UPDATE … FROM … JOIN / DELETE alias FROM → UPDATE … FROM s WHERE / DELETE FROM t USING s WHERE"),
    ("RS-55", "problem", r"\bSELECT\b[\s\S]{0,400}\bINTO\s+#\w+", "SELECT INTO #t → CREATE TEMP TABLE t AS SELECT"),
    ("RS-56", "problem", r"\bTOP\s*\(?\s*\d+\)?[\s\S]*\bLIMIT\s+\d+", "TOP and LIMIT cannot be used in the same query"),
    ("RS-53", "problem", r"\bWITH\s+NO\s+SCHEMA\s+BINDING\b[\s\S]*\bRECURSIVE\b|\bRECURSIVE\b[\s\S]*\bWITH\s+NO\s+SCHEMA\s+BINDING\b", "recursive CTEs are not allowed in late-binding views"),
    ("RS-61", "problem", r"\b(ORIGINAL_LOGIN|SUSER_SNAME|SUSER_NAME|SYSTEM_USER|IS_MEMBER|IS_ROLEMEMBER|HAS_PERMS_BY_NAME|SESSION_CONTEXT)\s*\(", "SQL Server identity functions: RLS/masking policy with an approved identity mapping"),
    ("RS-42", "warning", r"\bEXCEPTION\s+WHEN\b", "exception blocks have no subtransactions on Redshift: statements before the error may already be applied (NONATOMIC re-RAISE only)"),
    ("RS-02", "warning", r"\bLANGUAGE\s+plpythonu\b", "Python UDFs are deprecated after 2026-06-30: prefer SQL or Lambda UDFs"),
    ("RS-13", "warning", r"\bLISTAGG\s*\((?:[^()]|\([^()]*\))*\)(?!\s*WITHIN)", "LISTAGG without WITHIN GROUP (ORDER BY …) is non-deterministic"),
    ("RS-30", "warning", r"\bINTERLEAVED\s+SORTKEY\b", "interleaved sort keys should not be used on monotonically increasing columns"),
    ("RS-60", "warning", r"\bILIKE\b", "ILIKE works but hides a collation decision (RS-60): confirm CASE_INSENSITIVE design"),
]
CHECK_RES = [(r, sev, re.compile(p, re.I | re.M), m) for r, sev, p, m in CHECKS]
LBV_RE = re.compile(r"CREATE\s+(OR\s+REPLACE\s+)?VIEW\s+([\w.\"]+)\s+AS\s*([\s\S]*?)WITH\s+NO\s+SCHEMA\s+BINDING", re.I)


def check_text(code_text: str, source_text: str | None = None, source_name: str = "") -> tuple:
    """→ (problems, warnings) lists of dicts {rule, line, message}"""
    code = ddl.strip_comments(code_text)
    code_nolit = re.sub(r"N?'(?:[^']|'')*'", "''", code)
    problems, warnings = [], []
    for rule, sev, rx, msg in CHECK_RES:
        target = code if rule in ("RS-14",) else code_nolit
        for m in rx.finditer(target):
            item = {"rule": rule, "line": target.count("\n", 0, m.start()) + 1, "message": msg, "excerpt": m.group(0)[:60].replace("\n", " ")}
            (problems if sev == "problem" else warnings).append(item)
            break
    for m in LBV_RE.finditer(code_nolit):
        body = m.group(3)
        for r in re.finditer(r"\b(FROM|JOIN)\s+([A-Za-z_][\w]*)\b(?!\s*\.)", body, re.I):
            if r.group(2).lower() not in ("select", "lateral", "unnest", "generate_series"):
                problems.append({"rule": "RS-52", "line": code_nolit.count("\n", 0, m.start()) + 1, "message": f"late-binding view references unqualified object {r.group(2)}: every object must be schema.object", "excerpt": r.group(0)})
                break
    if re.search(r"\bMERGE\s+INTO\s+([\w.]+)\s+USING\s+\1\b", code_nolit, re.I):
        problems.append({"rule": "RS-50", "line": 0, "message": "MERGE source and target cannot be the same table", "excerpt": "MERGE … USING same table"})
    for m in re.finditer(r"\bMERGE\s+INTO\s+[\w.]+\s+USING\s+([\w.]+)(?:\s+(?:AS\s+)?\w+)?\s+ON\b", code_nolit, re.I):
        warnings.append({"rule": "RS-51", "line": code_nolit.count("\n", 0, m.start()) + 1, "excerpt": m.group(0)[:60],
                         "message": f"MERGE source {m.group(1)} is a bare table: a target row matching more than one source row fails ('Found multiple matches') — prove uniqueness (V-014) or deduplicate with ROW_NUMBER() … QUALIFY rn = 1"})
    for x in security.scan_text(code_text, "pgsql", source_name):
        if x["rule"] in ("SEC-01", "SEC-02", "SEC-03"):
            problems.append({"rule": x["rule"], "line": x["line"], "message": f"{x['name']}: {x['message']}", "excerpt": x["excerpt"]})
        elif x["rule"] == "SEC-04":
            (problems if x["severity"] == "critical" else warnings).append({"rule": "RS-62" if x["name"] in ("unload-to-s3", "copy-from-s3", "external-schema-or-function", "redshift-user-password") else x["rule"],
                                                                            "line": x["line"], "message": f"{x['name']}: {x['message']}", "excerpt": x["excerpt"]})
    if source_text is not None:
        for x in security.diff_introduced(source_text, code_text):
            if x["severity"] in ("critical", "high"):
                problems.append({"rule": "SEC-09", "line": x["line"], "message": f"{x['name']}: {x['message']}", "excerpt": x["excerpt"]})
    return problems, warnings


# ---------------------------------------------------------------- ledger inference
LEDGER_RULES = [  # (rule, source regex, target regex or None, source feature, target treatment, reason)
    ("RS-10", r"\bGETDATE\s*\(", r"\bGETDATE\s*\(", "GETDATE()", "kept", "supported on Redshift (statement start time)"),
    ("RS-10", r"\bDATEADD\s*\(", r"\bDATEADD\s*\(", "DATEADD()", "kept", "supported; check datepart names (m = minutes)"),
    ("RS-10", r"\bDATEDIFF\s*\(", r"\bDATEDIFF\s*\(", "DATEDIFF()", "kept", "supported; counts boundaries crossed"),
    ("RS-10", r"\bCHARINDEX\s*\(", r"\bCHARINDEX\s*\(", "CHARINDEX()", "kept", "supported (1-based, 0 when not found)"),
    ("RS-10", r"\bLEN\s*\(", r"\bLEN\s*\(", "LEN()", "kept", "supported (synonym of LENGTH)"),
    ("RS-10", r"\bTOP\s*\(?\s*\d", r"\bTOP\s*\(?\s*\d", "TOP n", "kept", "supported (not together with LIMIT)"),
    ("RS-10", r"\bTOP\s*\(?\s*\d", r"\bLIMIT\s+\d", "TOP n", "LIMIT n", "equivalent; ORDER BY required for determinism"),
    ("RS-11", r"\bISNULL\s*\(", r"\b(NVL|COALESCE)\s*\(", "ISNULL()", "NVL()/COALESCE()", "no ISNULL on Redshift"),
    ("RS-12", r"\bIIF\s*\(", r"\bCASE\s+WHEN\b|\bDECODE\s*\(", "IIF()", "CASE WHEN … END", "no IIF on Redshift"),
    ("RS-13", r"\bSTRING_AGG\s*\(", r"\bLISTAGG\s*\(", "STRING_AGG()", "LISTAGG() WITHIN GROUP", "ordering and 65535-byte limit"),
    ("RS-14", r"'\s*\+\s*|\+\s*'", r"\|\|", "'+' concatenation", "||", "NULL propagates in both"),
    ("RS-14", r"(?<![\w'])N'", None, "N'…' literals", "plain literals", "no N prefix"),
    ("RS-17", r"\[[A-Za-z_][\w ]*\]", None, "[bracketed] identifiers", "lower-case identifiers", "Redshift folds names to lower case"),
    ("RS-18", r"\bWITH\s*\(\s*NOLOCK", None, "WITH (NOLOCK)", "removed", "no lock hints; behaviour not identical"),
    ("RS-18", r"\bSET\s+NOCOUNT\b", None, "SET NOCOUNT ON", "removed", "not needed"),
    ("RS-40", r"\bSELECT\b[\s\S]*\bEND\b", r"\bINOUT\s+\w+\s+refcursor\b", "result set", "INOUT refcursor", "procedures return rows through a cursor"),
    ("RS-40", r"\bSELECT\b", r"\bCREATE\s+TEMP\s+TABLE\b", "result set / SELECT INTO", "temp table", "caller reads the temp table"),
    ("RS-41", r"\bBEGIN\s+TRAN", r"\bCOMMIT\b", "BEGIN TRAN … COMMIT", "implicit transaction / COMMIT", "atomic mode: COMMIT only outside a transaction block"),
    ("RS-42", r"\bBEGIN\s+TRY\b", r"\bEXCEPTION\s+WHEN\b", "TRY … CATCH", "EXCEPTION WHEN OTHERS", "limited: no subtransactions"),
    ("RS-42", r"\b(RAISERROR|THROW)\b", r"\bRAISE\b", "RAISERROR/THROW", "RAISE EXCEPTION", "message and code mapping"),
    ("RS-43", r"\bsp_executesql\b|\bEXEC\s*\(", r"\bEXECUTE\b", "dynamic SQL", "EXECUTE with quote_ident/quote_literal", "no variable substitution in the string"),
    ("RS-44", r"\bOUTPUT\b", r"\bINOUT\b", "OUTPUT parameter", "INOUT argument", "required for nested calls"),
    ("RS-16", r"@@ROWCOUNT", r"\bGET\s+DIAGNOSTICS\b", "@@ROWCOUNT", "GET DIAGNOSTICS n := ROW_COUNT", "procedure-only row count"),
    ("RS-46", r"\bRETURN\s+-?\d+", r"\bp_return_code\b|\bINOUT\s+\w*(return|rc|status)\w*\b", "RETURN <code>", "INOUT return-code argument", "procedures have no return value"),
    ("RS-41", r"\bBEGIN\s+TRAN", r"\bLANGUAGE\s+plpgsql\b", "BEGIN TRAN … COMMIT/ROLLBACK", "implicit transaction of the CALL", "atomic mode: the whole CALL commits or rolls back; NONATOMIC for per-statement commits"),
    ("RS-50", r"\bMERGE\b", r"\bMERGE\s+INTO\b", "MERGE", "Redshift MERGE", "one WHEN MATCHED, one WHEN NOT MATCHED, no WITH, source ≠ target"),
    ("RS-50", r"\bMERGE\b", r"\bUPDATE\b[\s\S]*\bINSERT\s+INTO\b[\s\S]*\bNOT\s+EXISTS\b", "MERGE", "UPDATE + INSERT … WHERE NOT EXISTS", "decomposed to respect Redshift MERGE restrictions"),
    ("RS-52", r"\bCREATE\s+(OR\s+ALTER\s+)?VIEW\b", r"\bWITH\s+NO\s+SCHEMA\s+BINDING\b", "view", "late-binding view", "no dependency on base tables; schema-qualified references"),
    ("RS-53", r"\bUNION\s+ALL\b", r"\bWITH\s+RECURSIVE\b", "recursive CTE", "WITH RECURSIVE cte(cols)", "column list required"),
    ("RS-54", r"\bUPDATE\s+\w+\s+SET\b[\s\S]{0,300}\bFROM\b", r"\bUPDATE\b[\s\S]{0,300}\bFROM\b[\s\S]{0,200}\bWHERE\b", "UPDATE … FROM JOIN", "UPDATE … FROM s WHERE", "Redshift join-update form"),
    ("RS-55", r"\bINTO\s+#\w+", r"\bCREATE\s+TEMP\s+TABLE\b", "SELECT INTO #t", "CREATE TEMP TABLE t AS", "temp table form"),
    ("RS-57", r"\bROW_NUMBER\s*\(\)\s*OVER\b", r"\bQUALIFY\b", "ROW_NUMBER filter", "QUALIFY", "window filter without a subquery"),
    ("RS-60", r"\bLIKE\b", r"\bLOWER\s*\(|COLLATE\s+CASE_INSENSITIVE|\bILIKE\b", "case-insensitive LIKE (_CI_AS)", "LOWER()/CASE_INSENSITIVE", "collation made explicit"),
    ("RS-61", r"\b(ORIGINAL_LOGIN|SUSER_SNAME|IS_MEMBER)\s*\(", r"\bCREATE\s+RLS\s+POLICY\b", "identity function in view", "RLS policy", "identity mapping must be approved"),
]


def infer_ledger(source: str, target: str) -> list:
    led = contract.RuleLedger()
    s = ddl.strip_comments(source); t = ddl.strip_comments(target)
    for rule, srx, trx, feat, treat, reason in LEDGER_RULES:
        if not re.search(srx, s, re.I):
            continue
        if trx is None:
            if not re.search(srx, t, re.I):
                led.add(rule, feat, treat, reason)
        elif re.search(trx, t, re.I):
            led.add(rule, feat, treat, reason)
    return led.to_list()


# ---------------------------------------------------------------- Data API execution
def split_statements(sql: str) -> list:
    """Split on top-level ';' outside strings, comments and $$ bodies."""
    parts, cur, i, n = [], [], 0, len(sql)
    in_str = in_line = in_block = in_dollar = False
    while i < n:
        ch, nxt = sql[i], sql[i + 1] if i + 1 < n else ""
        if in_line:
            cur.append(ch); i += 1
            if ch == "\n":
                in_line = False
            continue
        if in_block:
            cur.append(ch); i += 1
            if ch == "*" and nxt == "/":
                cur.append("/"); i += 1; in_block = False
            continue
        if in_dollar:
            cur.append(ch); i += 1
            if ch == "$" and nxt == "$":
                cur.append("$"); i += 1; in_dollar = False
            continue
        if in_str:
            cur.append(ch); i += 1
            if ch == "'":
                in_str = False
            continue
        if ch == "'":
            in_str = True
        elif ch == "-" and nxt == "-":
            in_line = True
        elif ch == "/" and nxt == "*":
            in_block = True
        elif ch == "$" and nxt == "$":
            in_dollar = True; cur.append("$"); i += 1
        elif ch == ";":
            parts.append("".join(cur).strip()); cur = []; i += 1; continue
        cur.append(ch); i += 1
    if "".join(cur).strip():
        parts.append("".join(cur).strip())
    lead = re.compile(r"^(\s*(--[^\n]*(\n|$)|/\*.*?\*/))*\s*", re.S)  # drop leading comments so each part starts with SQL
    parts = [lead.sub("", p).strip() for p in parts]
    return [p for p in parts if p]


def run_on_redshift(sql_text: str, database: str, workgroup: str | None, cluster: str | None, secret_arn: str | None, timeout: int = 120, source: str = "") -> dict:
    from migkit.services import Services, ServiceUnavailable
    if not TEST_DB.search(database or ""):
        raise SecurityRefusal(f"database '{database}' is not a test database (name must contain test/dev/sandbox/local)", [])
    crit = [x for x in security.scan_text(sql_text, "pgsql", source) if x["rule"] in ("SEC-01", "SEC-02", "SEC-03") or (x["rule"] == "SEC-04" and x["severity"] == "critical")]
    if crit:
        raise SecurityRefusal("SQL failed the security scan; it will not be executed", crit)
    stmts = split_statements(sql_text)
    if not stmts:
        return {"status": "SKIPPED", "statements": 0}
    if sum(len(s.encode("utf-8")) for s in stmts) > MAX_DATA_API_BYTES:
        raise SystemExit(f"SQL exceeds the Data API limit of {MAX_DATA_API_BYTES} bytes per request: split the file")
    svc = Services(logger=LOG)
    args = ["redshift-data", "batch-execute-statement", "--database", database, "--sqls"] + stmts + ["--client-token", LOG.run_id + ":" + sha256_bytes(sql_text.encode("utf-8"))[:16]]
    args += ["--workgroup-name", workgroup] if workgroup else ["--cluster-identifier", cluster]
    if secret_arn:
        args += ["--secret-arn", secret_arn]
    started = time.monotonic()
    try:
        r = svc.aws(*args, timeout=30)
        sid = r.get("Id")
        LOG.log("redshift.execute", f"{len(stmts)} statement(s) submitted", statement_id=sid, database=database, workgroup=workgroup, cluster=cluster, sql_sha256=sha256_bytes(sql_text.encode("utf-8")))
        status = "SUBMITTED"; desc = {}
        while time.monotonic() - started < timeout:
            desc = svc.aws("redshift-data", "describe-statement", "--id", sid)
            status = desc.get("Status")
            if status in ("FINISHED", "FAILED", "ABORTED"):
                break
            time.sleep(min(2.0, max(0.2, timeout / 60)))
    except ServiceUnavailable as ex:
        LOG.log("redshift.unavailable", str(ex), "WARN", database=database)
        return {"status": "UNAVAILABLE", "error": str(ex), "statements": len(stmts), "evidence": {"V-004": {"status": "ERROR", "evidence": f"Redshift Data API unavailable: {ex}"}}}
    result = {"status": status, "statementId": sid, "statements": len(stmts), "durationMs": desc.get("Duration", 0) // 1_000_000 if desc.get("Duration") else None,
              "error": desc.get("Error"), "subStatements": [{"id": s.get("Id"), "status": s.get("Status"), "error": s.get("Error")} for s in desc.get("SubStatements", [])],
              "database": database, "executedAt": now_rfc3339(), "runId": LOG.run_id}
    result["evidence"] = {"V-004": {"status": "PASS" if status == "FINISHED" else "FAIL", "evidence": f"Redshift Data API statement {sid} {status}" + (f": {desc.get('Error')}" if desc.get("Error") else "")}}
    LOG.log("redshift.result", status, "INFO" if status == "FINISHED" else "ERROR", statement_id=sid, error=desc.get("Error"), statements=len(stmts))
    return result


# ---------------------------------------------------------------- commands
def _read(p):
    path = pathlib.Path(p)
    big = security.check_size(path)
    if big:
        raise SecurityRefusal(f"{path} is too large", big)
    return path.read_text(encoding="utf-8-sig", errors="replace")


def cmd_convert_ddl(a):
    text = _read(a.tsql)
    design = contract.load_json(a.design) if a.design else None
    with LOG.span("redshift.convert_ddl", source=str(a.tsql)) as o:
        sql, ledger, warnings, status = convert_ddl(text, design)
        o.update(status=status, warnings=len(warnings))
    if a.out:
        pathlib.Path(a.out).write_text(sql, encoding="utf-8", newline="\n")
        print(f"wrote {a.out} ({status}, {len(ledger)} ledger row(s), {len(warnings)} warning(s))")
    else:
        print(sql)
    if a.ledger:
        pathlib.Path(a.ledger).write_text(contract.canonical_json({"status": status, "ruleLedger": ledger, "warnings": warnings}), encoding="utf-8")
    for w in warnings:
        print(f"WARN  {w}")
    LOG.log("redshift.convert_ddl.done", status, "WARN" if status != "GENERATED" else "INFO", tables=sql.count("CREATE TABLE"), ledger_rows=len(ledger), warnings=warnings[:50])
    return 0 if status == "GENERATED" else 1


def cmd_check(a):
    text = _read(a.file)
    src = _read(a.source) if a.source else None
    with LOG.span("redshift.check", file=str(a.file)) as o:
        problems, warnings = check_text(text, src, str(a.file))
        o.update(problems=len(problems), warnings=len(warnings))
    if a.json:
        print(contract.canonical_json({"problems": problems, "warnings": warnings}))
    else:
        for w in warnings:
            print(f"WARN  {a.file}:{w['line']}: {w['rule']} {w['message']} — {w['excerpt']}")
        for p in problems:
            print(f"FAIL  {a.file}:{p['line']}: {p['rule']} {p['message']} — {p['excerpt']}")
        print(f"check: {len(problems)} problem(s), {len(warnings)} warning(s)")
    LOG.log("redshift.check.done", f"{len(problems)} problem(s)", "WARN" if problems else "INFO", file=str(a.file), problems=[p["rule"] for p in problems][:50])
    return 1 if problems else 0


def cmd_ledger(a):
    rows = infer_ledger(_read(a.tsql), _read(a.converted))
    if a.json:
        print(contract.canonical_json(rows))
    else:
        led = contract.RuleLedger(); led.rows = rows
        print(led.markdown())
    return 0


def cmd_run(a):
    text = _read(a.file)
    with LOG.span("redshift.run", file=str(a.file), database=a.database) as o:
        r = run_on_redshift(text, a.database, a.workgroup_name, a.cluster_identifier, a.secret_arn, a.timeout, str(a.file))
        o.update(status=r["status"])
    if a.evidence:
        pathlib.Path(a.evidence).write_text(contract.canonical_json(r), encoding="utf-8")
    print(contract.canonical_json(r))
    return 0 if r["status"] == "FINISHED" else 1


def cmd_package(a):
    src, tgt = _read(a.tsql), _read(a.converted)
    problems, warnings = check_text(tgt, src, str(a.converted))
    ledger = infer_ledger(src, tgt)
    inv = ddl.inventory(src)
    req = contract.new_request(a.request_id or pathlib.Path(a.tsql).stem, "SQLServer", inv["object_type"], pathlib.Path(a.tsql).stem, src, "Redshift")
    out = contract.new_output(req["requestId"])
    if a.classification and pathlib.Path(a.classification).exists():
        cls = contract.load_json(a.classification)
        out["classification"] = cls.get("classification", out["classification"])
        out["analysis"]["securityFindings"] = cls.get("analysis", {}).get("securityFindings", [])
    out["artifacts"]["convertedCode"] = tgt
    out["analysis"]["ruleLedger"] = ledger
    out["analysis"]["constructInventory"] = [{"construct": k, "count": v} for k, v in sorted(inv["constructs"].items())]
    out["analysis"]["warnings"] = [f"{w['rule']} line {w['line']}: {w['message']}" for w in warnings]
    out["analysis"]["manualReviewItems"] = [f"{p['rule']} line {p['line']}: {p['message']}" for p in problems] + \
                                           [f"-- TODO at line {i + 1}: {l.strip()[:120]}" for i, l in enumerate(tgt.splitlines()) if "MANUAL REVIEW REQUIRED" in l]
    executed = {"V-001": {"status": "PASS", "evidence": "contract validated"}, "V-002": {"status": "PASS", "evidence": f"sha256 {sha256_bytes(src.encode('utf-8'))}"}}
    if problems:
        contract.set_status(out, "PARTIAL", "STATIC_VALIDATION_FAILED")
        executed["V-004"] = {"status": "FAIL", "evidence": f"{len(problems)} static problem(s)"}
    if out["analysis"]["manualReviewItems"]:
        contract.set_status(out, "PARTIAL", "UNSUPPORTED_CONSTRUCT")
    if a.evidence and pathlib.Path(a.evidence).exists():
        ev = contract.load_json(a.evidence)
        executed.update(ev.get("evidence", {}))
        if executed.get("V-004", {}).get("status") == "PASS" and out["status"] == "GENERATED":
            out["status"] = "VALIDATED"
    applicable = ["V-001", "V-002", "V-004", "V-005", "V-012", "V-013", "V-014", "V-035", "V-036"] + (["V-023", "V-033"] if inv["constructs"].get("merge") else [])
    out["validation"] = contract.validation_manifest(applicable, executed)
    m = contract.write_package(a.out, req, out, files={pathlib.Path(a.converted).name: tgt, pathlib.Path(a.tsql).name: src})
    print(f"package → {a.out} ({out['status']}, {len(ledger)} ledger rows, {len(problems)} problems)")
    LOG.log("redshift.package", out["status"], package=str(a.out), files=len(m["files"]), status=out["status"])
    return 0 if out["status"] in ("GENERATED", "VALIDATED") else 1


def main():
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("convert-ddl"); p.add_argument("tsql"); p.add_argument("--design"); p.add_argument("--out"); p.add_argument("--ledger"); p.set_defaults(fn=cmd_convert_ddl)
    p = sub.add_parser("check"); p.add_argument("file"); p.add_argument("--source"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_check)
    p = sub.add_parser("ledger"); p.add_argument("tsql"); p.add_argument("converted"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_ledger)
    p = sub.add_parser("run"); p.add_argument("file"); p.add_argument("--database", required=True); p.add_argument("--workgroup-name"); p.add_argument("--cluster-identifier")
    p.add_argument("--secret-arn"); p.add_argument("--timeout", type=int, default=120); p.add_argument("--evidence"); p.set_defaults(fn=cmd_run)
    p = sub.add_parser("package"); p.add_argument("tsql"); p.add_argument("converted"); p.add_argument("--out", required=True); p.add_argument("--classification")
    p.add_argument("--evidence"); p.add_argument("--request-id"); p.set_defaults(fn=cmd_package)
    a = ap.parse_args()
    with LOG.span(f"redshift.{a.cmd}", argv=[str(x) for x in sys.argv[1:]], tool_version=TOOL_VERSION) as o:
        rc = a.fn(a)
        o.update(status="ok" if rc == 0 else "failed", exit_code=rc)
        return rc


if __name__ == "__main__":
    sys.exit(main())
