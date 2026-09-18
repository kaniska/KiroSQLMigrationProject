#!/usr/bin/env python3
"""
iceberg_tool.py — deterministic helper for landing SQL Server objects in Apache Iceberg tables on S3
(AWS Glue Data Catalog, Amazon Athena, AWS Glue Spark jobs).

  ddl <tsql.sql> [--design design.json] [--dialect athena|spark|both] [--out-dir DIR] [--ledger out.json]
        T-SQL CREATE TABLE → Iceberg DDL for Athena and/or Spark SQL: spec type map, lost lengths kept in
        COMMENTs, partition transforms and location/catalog from the design file, identity/constraints/
        defaults/computed columns/indexes recorded in the ledger (never dropped silently).
  check <file.sql|file.py> [--source tsql.sql] [--dialect spark|athena] [--json]
        static review of Spark SQL / Athena SQL / a Glue job: residual T-SQL, unsupported Iceberg DDL items,
        MERGE safety, portability warnings, security findings (SEC-01..04) and constructs introduced vs the source.
  ledger <tsql.sql> <converted.sql> [--json]
        infers the rule ledger between a SQL Server object and its Spark/Athena translation.
  job <spec.json> --out job.py
        renders the Glue 5.x PySpark MERGE job from scripts/templates and compiles it (py_compile) + scans it.
  run <file.sql> --database DB [--workgroup WG] [--output-location s3://…] [--catalog AwsDataCatalog] [--timeout 120]
        executes each statement on Amazon Athena (start-query-execution): only databases whose name contains
        test/dev/sandbox/local, after a security scan, fully audited.
  package <tsql.sql> <converted…> --out DIR [--classification FILE] [--evidence run.json]

Exit codes: 0 ok · 1 problems · 2 usage · 3 security refusal.
"""
import argparse
import json
import os
import pathlib
import py_compile
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
LOG = AuditLogger("iceberg_tool")
EXIT_SECURITY = 3
TEST_DB = re.compile(r"(test|dev|sandbox|local)", re.I)
TEMPLATES = pathlib.Path(__file__).resolve().parent / "templates"
PLACEHOLDER_LOCATION = "s3://TODO-bucket/TODO-prefix/"


class SecurityRefusal(SystemExit):
    def __init__(self, message, findings=()):
        LOG.log("security.refused", message, "ERROR", findings=[{k: f.get(k) for k in ("rule", "name", "severity", "line")} for f in list(findings)[:50]])
        sys.stderr.write(f"REFUSED (security): {message}\n" + "".join(f"  {f['rule']} {f['severity']:<8} {f['name']} line {f.get('line', 0)} — {f['message']}\n" for f in list(findings)[:20]))
        super().__init__(EXIT_SECURITY)


def snake(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_]+", "_", name)
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", s)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", s)
    return re.sub(r"_+", "_", s).strip("_").lower()


# ---------------------------------------------------------------- types
def map_type(dt: dict) -> tuple:
    """(iceberg_type, rule, note, comment) — rule None when 1:1; comment carries lost information."""
    b, ln, p, s = dt["base"], dt["length"], dt["precision"], dt["scale"]
    raw = dt["raw"]
    if b in ("int", "integer"):
        return "int", None, "", ""
    if b == "bigint":
        return "bigint", None, "", ""
    if b in ("smallint", "tinyint"):
        return "int", "IB-11", "no small integer types in the Iceberg spec", f"source: {raw}"
    if b == "bit":
        return "boolean", "IB-12", "1/0 → true/false", ""
    if b in ("decimal", "numeric", "dec"):
        pp, ss = p or 18, s or 0
        if pp > 38:
            return f"decimal(38,{min(ss, 38)})", "IB-21", "precision capped at 38", f"source: {raw}"
        return f"decimal({pp},{ss})", None, "", ""
    if b == "money":
        return "decimal(19,4)", "IB-13", "no money type", f"source: {raw}"
    if b == "smallmoney":
        return "decimal(10,4)", "IB-13", "no money type", f"source: {raw}"
    if b == "float":
        return ("float" if (p and p <= 24) else "double"), "IB-20", "", ""
    if b == "real":
        return "float", "IB-20", "", ""
    if b in ("char", "nchar", "varchar", "nvarchar", "text", "ntext", "sysname"):
        return "string", "IB-10", "length not enforced by the table format (V-006)", f"source: {raw}"
    if b == "date":
        return "date", None, "", ""
    if b == "time":
        return "string", "IB-16", "no time type in Athena/Spark Iceberg DDL", f"source: {raw}"
    if b in ("datetime", "datetime2", "smalldatetime"):
        return "timestamp", "IB-14", "µs (Spark) / ms (Athena); 1/300 s rounding lost", f"source: {raw}"
    if b == "datetimeoffset":
        return "timestamp", "IB-15", "normalised to UTC; offset lost (keep a side column when needed)", f"source: {raw} (UTC)"
    if b == "uniqueidentifier":
        return "string", "IB-17", "no UUID type", f"source: {raw}"
    if b in ("varbinary", "binary", "image", "rowversion", "timestamp"):
        return "binary", "IB-18", "", f"source: {raw}"
    if b in ("geography", "geometry"):
        return "binary", "IB-19", "WKB representation (or string WKT): spatial decision required", f"source: {raw} as WKB"
    if b in ("xml", "sql_variant", "hierarchyid"):
        return "string", "IB-22", f"{raw} has no equivalent: stored as text, manual review", f"source: {raw}"
    return None, "IB-22", f"no approved mapping for {raw}", ""


ATHENA_TRANSFORM = re.compile(r"^(year|month|day|hour)\((\w+)\)$|^bucket\((\d+),\s*(\w+)\)$|^truncate\((\d+),\s*(\w+)\)$|^(\w+)$", re.I)


def partition_clause(specs: list, dialect: str) -> tuple:
    """Design-file transforms → (clause_text, problems). Spark spells time transforms years/months/days/hours."""
    parts, problems = [], []
    for spec in specs or []:
        m = ATHENA_TRANSFORM.match(spec.strip())
        if not m:
            problems.append(f"unknown partition transform {spec!r} (allowed: year|month|day|hour(col), bucket(N, col), truncate(L, col), col)")
            continue
        if m.group(1):
            t = m.group(1).lower(); col = snake(m.group(2))
            parts.append(f"{t}s({col})" if dialect == "spark" else f"{t}({col})")
        elif m.group(3):
            parts.append(f"bucket({m.group(3)}, {snake(m.group(4))})")
        elif m.group(5):
            parts.append(f"truncate({m.group(5)}, {snake(m.group(6))})")
        else:
            parts.append(snake(m.group(7)))
    return (", ".join(parts), problems)


def convert_ddl(text: str, design: dict | None = None, dialects=("athena", "spark")):
    """→ ({dialect: sql}, ledger_rows, warnings, status)"""
    design = design or {}
    tables = ddl.parse_tables(text, "tsql")
    ledger = contract.RuleLedger()
    warnings, status = [], "GENERATED"
    out = {d: [] for d in dialects}
    db = design.get("database", "analytics")
    catalog = design.get("catalog", "glue_catalog")
    for t in tables:
        key = f"{t['schema'] or 'dbo'}.{t['name']}"
        d = design.get("tables", {}).get(key) or design.get("tables", {}).get(t["name"]) or {}
        tname = snake(t["name"])
        cols, trailers = [], []
        for c in t["columns"]:
            cname = snake(c["name"])
            if c["computed"]:
                ledger.add("IB-04", f"{c['name']} AS {c['computed']}", "computed in the load job / serving view", "no computed columns in the table format", manual=True)
                trailers.append(f"-- TODO: MANUAL REVIEW REQUIRED — computed column {cname} AS {c['computed']}: compute it in the load job (IB-04)")
                status = "PARTIAL"; continue
            itype, rule, note, comment = map_type(c["datatype"])
            if itype is None:
                warnings.append(f"{key}.{c['name']}: {note} (IB-22)")
                ledger.add("IB-22", f"{c['name']} {c['datatype']['raw']}", "no mapping", note, manual=True)
                trailers.append(f"-- TODO: MANUAL REVIEW REQUIRED — {cname} {c['datatype']['raw']}: {note}")
                status = "PARTIAL"; continue
            if rule:
                ledger.add(rule, f"{c['name']} {c['datatype']['raw']}", itype, note or "spec type", manual=rule in ("IB-19", "IB-22"))
                if rule == "IB-22":
                    status = "PARTIAL"; warnings.append(f"{key}.{c['name']}: {note} (IB-22)")
                if rule == "IB-19":
                    warnings.append(f"{key}.{c['name']}: GEOGRAPHY/GEOMETRY stored as WKB binary — confirm the spatial decision (IB-19)")
            if c["identity"]:
                ledger.add("IB-01", f"{c['name']} IDENTITY({c['identity']['seed']},{c['identity']['increment']})", "key generated by the load job", "no identity columns; monotonically_increasing_id() is not stable across runs", manual=True)
                trailers.append(f"-- identity {cname}: generated by the load job, not by the table (IB-01)")
            if c["default"] is not None:
                ledger.add("IB-03", f"{c['name']} DEFAULT {c['default']}", "applied in the load job (coalesce)", "no column defaults in Athena/Spark Iceberg DDL")
                trailers.append(f"-- default {cname} = {c['default']}: applied in the load job (IB-03)")
            if c["unresolved"]:
                warnings.append(f"{key}.{c['name']}: unparsed column options {c['unresolved']} (manual review)")
                trailers.append(f"-- TODO: MANUAL REVIEW REQUIRED — {cname}: {'; '.join(c['unresolved'])}"); status = "PARTIAL"
            nn = " NOT NULL" if not c["nullable"] else ""
            cm = f" COMMENT '{comment}'" if comment else ""
            cols.append((cname, itype, nn, cm))
        for con in t["constraints"]:
            ledger.add("IB-02", f"{con['type']} {con['name'] or ''} ({', '.join(con['columns'])})" if con["type"] != "CHECK" else f"CHECK {con['expression']}",
                       "not declared; validated by query", {"PRIMARY KEY": "uniqueness V-014", "UNIQUE": "uniqueness V-014", "FOREIGN KEY": "referential integrity V-018", "CHECK": "domain V-009"}[con["type"]])
            trailers.append(f"-- {con['type']} {con['name'] or ''}: not declared in Iceberg DDL; validated by query (IB-02)")
        for ix in t["indexes"]:
            ledger.add("IB-05", f"INDEX {ix['name']} ({', '.join(ix['columns'])})", "write-order / partition candidate", "no indexes in the table format")
            trailers.append(f"-- index {ix['name']} on ({', '.join(snake(x) for x in ix['columns'])}): WRITE ORDERED BY candidate (IB-05)")
        for u in t["unresolved"]:
            warnings.append(f"{key}: unparsed table item — {u}"); status = "PARTIAL"
        part = d.get("partition") or []
        if not part:
            ledger.add("IB-30", "partitioning", "unpartitioned", "no partition decision supplied in the design file")
        else:
            ledger.add("IB-30", "partitioning", ", ".join(part), "design file decision")
        for dialect in dialects:
            pclause, perr = partition_clause(part, dialect)
            for e in perr:
                warnings.append(f"{key}: {e}"); status = "PARTIAL"
            # Athena Iceberg DDL has no NOT NULL clause: nullability is validated by V-007 (Spark keeps it)
            body = ",\n".join(f"    {n} {ty}{nn if dialect == 'spark' else ''}{cm}" for n, ty, nn, cm in cols)
            if dialect == "athena":
                loc = d.get("location") or (design.get("location_prefix", "").rstrip("/") + f"/{tname}/" if design.get("location_prefix") else "")
                if not loc:
                    loc = PLACEHOLDER_LOCATION + tname + "/"
                    warnings.append(f"{key}: no S3 location in the design file — placeholder emitted (IB-31)"); status = "PARTIAL"
                props = {"table_type": "ICEBERG", "format": "parquet", "write_compression": "zstd"}
                if d.get("merge_heavy"):
                    props["write.delete.mode"] = "merge-on-read"; props["write.update.mode"] = "merge-on-read"; props["write.merge.mode"] = "merge-on-read"
                props.update(d.get("athena_properties", {}))
                stmt = (f"CREATE TABLE {db}.{tname} (\n{body}\n)\n" + (f"PARTITIONED BY ({pclause})\n" if pclause else "") +
                        f"LOCATION '{loc}'\nTBLPROPERTIES (" + ", ".join(f"'{k}'='{v}'" for k, v in props.items()) + ");")
            else:
                props = {"format-version": "2", "write.format.default": "parquet", "write.parquet.compression-codec": "zstd"}
                if d.get("merge_heavy"):
                    props["write.delete.mode"] = "merge-on-read"; props["write.update.mode"] = "merge-on-read"; props["write.merge.mode"] = "merge-on-read"
                props.update(d.get("spark_properties", {}))
                stmt = (f"CREATE TABLE {catalog}.{db}.{tname} (\n{body}\n)\nUSING iceberg\n" + (f"PARTITIONED BY ({pclause})\n" if pclause else "") +
                        "TBLPROPERTIES (" + ", ".join(f"'{k}'='{v}'" for k, v in props.items()) + ");")
            out[dialect].append(stmt + ("\n" + "\n".join(trailers) if trailers else ""))
        if any(nn for _, _, nn, _ in cols) and "athena" in dialects:
            ledger.add("IB-02", "NOT NULL columns", "declared in Spark DDL only", "Athena Iceberg DDL has no NOT NULL; validated by V-007")
        ledger.add("IB-32", "table properties", "ICEBERG/parquet/zstd" + (" + merge-on-read" if d.get("merge_heavy") else ""), "design defaults")
        ledger.add("IB-34", key, f"{db}.{tname}", "Glue catalog folds identifiers to lower case")
    header = (f"-- Generated by iceberg_tool.py ddl v{TOOL_VERSION} on {now_rfc3339()} — dialect %s\n"
              f"-- Source sha256 {sha256_bytes(text.encode('utf-8'))}\n-- Rules: .kiro/steering/iceberg.md · ledger in the conversion package\n\n")
    return {d: (header % d) + "\n\n".join(out[d]) + "\n" for d in dialects}, ledger.to_list(), warnings, status


# ---------------------------------------------------------------- static review
CHECKS = [  # (rule, severity, dialect|None, regex, message)
    ("IB-06", "problem", None, r"\bCREATE\s+(OR\s+REPLACE\s+|OR\s+ALTER\s+)?(TRIGGER|PROCEDURE|PROC|FUNCTION)\b", "no procedural engine on Iceberg: Glue job or Aurora"),
    ("IB-07", "problem", None, r"\bDECLARE\s+\w+\s+CURSOR\b|\bDECLARE\s+@\w+\s+TABLE\b|\bFETCH\s+NEXT\b|\bWHILE\s+@@", "cursors/table variables/loops: set-based Spark SQL"),
    ("IB-08", "problem", None, r"\bFOR\s+XML\b|\bOPENJSON\s*\(|\.(value|query|nodes|exist)\s*\(", "FOR XML / OPENJSON / XML methods: to_json/from_json/get_json_object (Spark), json_extract (Athena)"),
    ("IB-01", "problem", None, r"\bIDENTITY\s*\(|\bGENERATED\s+(ALWAYS|BY\s+DEFAULT)\s+AS\s+IDENTITY\b", "no identity columns in Iceberg DDL"),
    ("IB-02", "problem", None, r"\b(PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE\s*\(|REFERENCES\s+\w|CHECK\s*\()", "constraints are not declared in Athena/Spark Iceberg DDL"),
    ("IB-03", "problem", None, r"\bDEFAULT\s+(?!\bVALUES\b)[\w'(]", "column defaults are not supported in Athena/Spark Iceberg DDL: apply in the load"),
    ("IB-04", "problem", None, r"\bAS\s*\([^)]*\)\s*(PERSISTED|STORED)\b|\bGENERATED\s+ALWAYS\s+AS\s*\(", "computed/generated columns are not supported"),
    ("IB-05", "problem", None, r"\bCREATE\s+(UNIQUE\s+|CLUSTERED\s+|NONCLUSTERED\s+)*INDEX\b", "indexes do not exist: write order / partitioning"),
    ("IB-10", "problem", None, r"\b(N?VARCHAR|N?CHAR|NTEXT)\s*\(", "character types with length: use string (length kept in COMMENT)"),
    ("IB-11", "problem", None, r"\b(TINYINT|SMALLINT)\b", "no small integers: int"),
    ("IB-12", "problem", None, r"\bBIT\b(?!\s*\()", "BIT → boolean"),
    ("IB-13", "problem", None, r"\b(SMALL)?MONEY\b", "MONEY → decimal(19,4)"),
    ("IB-14", "problem", None, r"\b(DATETIME2?|SMALLDATETIME)\b", "DATETIME → timestamp"),
    ("IB-15", "problem", None, r"\bDATETIMEOFFSET\b|\bTIMESTAMP\s+WITH\s+(LOCAL\s+)?TIME\s+ZONE\b|\bTIMESTAMPTZ\b", "no time-zone timestamp in Athena Iceberg DDL: timestamp in UTC"),
    ("IB-16", "problem", None, r"\bTIME\s*(\(\d\))?\s*(,|\)|NOT|NULL|COMMENT)", "no time type: string"),
    ("IB-17", "problem", None, r"\bUNIQUEIDENTIFIER\b|\bUUID\b(?!\s*\()", "no UUID type: string"),
    ("IB-18", "problem", None, r"\b(VARBINARY|IMAGE|ROWVERSION|BYTEA)\b", "binary types → binary"),
    ("IB-19", "problem", None, r"\b(GEOGRAPHY|GEOMETRY)\b", "spatial types → binary (WKB) or string (WKT): decision required"),
    ("IB-20", "problem", None, r"\bREAL\b|\bFLOAT\s*\(\d+\)", "REAL/FLOAT(n) → float/double"),
    ("IB-22", "problem", None, r"\b(XML|SQL_VARIANT|HIERARCHYID)\b", "XML/SQL_VARIANT/HIERARCHYID → string with manual review"),
    ("IB-34", "problem", None, r"\[[A-Za-z_][\w ]*\]", "[bracketed identifier] → lower-case snake_case"),
    ("IB-40", "problem", None, r"\bISNULL\s*\(", "ISNULL → coalesce"),
    ("IB-41", "problem", None, r"\bIIF\s*\(", "IIF → if() (Spark) / CASE"),
    ("IB-42", "problem", None, r"\b(GETDATE|GETUTCDATE|SYSDATETIME|SYSUTCDATETIME)\s*\(", "GETDATE → current_timestamp()"),
    ("IB-43", "problem", None, r"\bDATE(ADD|DIFF)\s*\(\s*\w+\s*,\s*[^,()]+,", "3-argument DATEADD/DATEDIFF: date_add(d, n) / datediff(end, start) / timestampadd|timestampdiff"),
    ("IB-44", "problem", None, r"\bCHARINDEX\s*\(|\bLEN\s*\(", "CHARINDEX(x, s) → instr(s, x); LEN → length"),
    ("IB-45", "problem", None, r"\bTOP\s*\(?\s*\d+\)?", "TOP n → LIMIT n"),
    ("IB-46", "problem", None, r"(?<![\w'])N'|'\s*\+\s*[\w'(]|[\w')]\s*\+\s*'", "N'' literals and + concatenation → concat / ||"),
    ("IB-47", "problem", None, r"\bSTRING_AGG\s*\(", "STRING_AGG → listagg (Athena, Spark 4) / array_join(sort_array(collect_list(x)), ',')"),
    ("IB-48", "problem", None, r"\bNEW(SEQUENTIAL)?ID\s*\(", "NEWID() → uuid() (not for reruns)"),
    ("IB-50", "problem", None, r"\bCONVERT\s*\(\s*\w+", "CONVERT(type, x, style) → CAST / date_format"),
    ("IB-51", "problem", None, r"\bWITH\s*\(\s*NOLOCK|^\s*GO\s*$|@@\w+|\bsp_\w+|\bSET\s+NOCOUNT\b|\bINTO\s+#\w+|\bFROM\s+#\w+", "SQL Server session syntax / #temp tables must be removed (temp views)"),
    ("IB-63", "problem", None, r"\bSELECT\b[\s\S]{0,400}\bINTO\s+#\w+", "SELECT INTO #t → CREATE OR REPLACE TEMPORARY VIEW / CTAS"),
    ("IB-61", "problem", "athena", r"\bWHEN\s+NOT\s+MATCHED\s+BY\s+SOURCE\b", "Athena MERGE has no WHEN NOT MATCHED BY SOURCE: separate DELETE"),
    ("IB-61", "warning", "spark", r"\bWHEN\s+NOT\s+MATCHED\s+BY\s+SOURCE\b", "requires Spark 3.4+ / Iceberg 1.3+ (Glue 4.0+)"),
    ("IB-64", "warning", "spark", r"\bWITH\s+RECURSIVE\b", "recursive CTEs need Spark 4.1+; run on Athena instead"),
    ("IB-64", "problem", None, r"\bWITH\s+(\w+)\s*(?:\([^)]*\))?\s+AS\s*\(\s*SELECT\b[\s\S]{0,600}\bUNION\s+ALL\b[\s\S]{0,600}\bJOIN\s+\1\b", "T-SQL implicit recursive CTE: WITH RECURSIVE (Athena) or iterative job"),
    ("IB-65", "warning", None, r"\bQUALIFY\b", "QUALIFY is not portable (Athena, OSS Spark < 4): window in a subquery"),
    ("IB-62", "warning", None, r"^\s*(UPDATE|DELETE\s+FROM)\s+[\w.]+", "row-level UPDATE/DELETE creates delete files: schedule OPTIMIZE/VACUUM (rewrite_data_files)"),
    ("IB-49", "warning", None, r"(?<![\w.])\w+\s*/\s*\w+(?![\w.])", "'/' is floating-point division in Spark: use div for integer semantics"),
    ("IB-52", "warning", None, r"\bILIKE\b|\bCOLLATE\s+UTF8_LCASE\b", "case-insensitive comparison: Athena is case-sensitive (lower() both sides)"),
    ("IB-42", "warning", None, r"\bcurrent_timestamp\b", "session time zone: Athena current_timestamp is UTC, Spark uses spark.sql.session.timeZone"),
    ("IB-71", "problem", "job", r"\bspark\.sql\(\s*f?[\"']\s*MERGE\b(?![\s\S]*dropDuplicates|[\s\S]*row_number)", "job MERGE without source deduplication"),
]
CHECK_RES = [(r, sev, dia, re.compile(p, re.I | re.M), m) for r, sev, dia, p, m in CHECKS]


def check_text(text: str, source_text: str | None = None, source_name: str = "", dialect: str = "spark") -> tuple:
    """→ (problems, warnings). dialect: spark | athena | job (PySpark file)."""
    is_job = dialect == "job" or source_name.endswith(".py")
    code = text if is_job else ddl.strip_comments(text)
    code_nolit = re.sub(r"N?'(?:[^']|'')*'", "''", code) if not is_job else re.sub(r'"""[\s\S]*?"""', '""', code)
    problems, warnings = [], []
    for rule, sev, dia, rx, msg in CHECK_RES:
        if is_job != (dia == "job"):  # SQL rules apply to SQL files, job rules to PySpark files
            continue
        if dia not in (None, "job") and dia != dialect:
            continue
        target = code if rule in ("IB-46", "IB-71") else code_nolit
        m = rx.search(target)
        if m:
            item = {"rule": rule, "line": target.count("\n", 0, m.start()) + 1, "message": msg, "excerpt": m.group(0)[:60].replace("\n", " ")}
            (problems if sev == "problem" else warnings).append(item)
    for m in re.finditer(r"\bMERGE\s+INTO\s+[\w.]+(?:\s+(?:AS\s+)?\w+)?\s+USING\s+([\w.]+)(?:\s+(?:AS\s+)?\w+)?\s+ON\b", code_nolit, re.I):
        if not is_job:
            warnings.append({"rule": "IB-60", "line": code_nolit.count("\n", 0, m.start()) + 1, "excerpt": m.group(0)[:60],
                             "message": f"MERGE source {m.group(1)} is a bare table: a target row matching several source rows fails — deduplicate (row_number() = 1) or prove uniqueness (V-014)"})
    kind = security.kind_for(pathlib.Path(source_name or "x.sql")) if source_name else ("python" if is_job else "pgsql")
    for x in security.scan_text(text, kind, source_name):
        if x["rule"] in ("SEC-01", "SEC-02", "SEC-03"):
            problems.append({"rule": x["rule"], "line": x["line"], "message": f"{x['name']}: {x['message']}", "excerpt": x["excerpt"]})
        elif x["rule"] == "SEC-04":
            (problems if x["severity"] == "critical" or is_job else warnings).append({"rule": "IB-72" if is_job else x["rule"], "line": x["line"], "message": f"{x['name']}: {x['message']}", "excerpt": x["excerpt"]})
    if is_job:
        for name, rx in (("boto3-identity", r"boto3\.client\(\s*['\"](iam|sts|secretsmanager)['\"]"), ("shell", r"\bsubprocess\b|\bos\.system\b|\bos\.popen\b"),
                         ("inline-credentials", r"aws_access_key_id\s*=|aws_secret_access_key\s*=|AKIA[0-9A-Z]{16}")):
            m = re.search(rx, code)
            if m and not any(p["rule"] == "IB-72" and p["excerpt"] == m.group(0)[:60] for p in problems):
                problems.append({"rule": "IB-72", "line": code.count("\n", 0, m.start()) + 1, "message": f"{name}: the job role provides access; no credentials, identity calls or shell in jobs", "excerpt": m.group(0)[:60]})
    if source_text is not None and not is_job:
        for x in security.diff_introduced(source_text, text):
            if x["name"] == "network-reference" and re.search(r"LOCATION\s+'s3://", x["excerpt"], re.I):
                warnings.append({"rule": "IB-31", "line": x["line"], "message": "table LOCATION introduced by the conversion: confirm the bucket/prefix is the approved data-lake location", "excerpt": x["excerpt"]})
            elif x["severity"] in ("critical", "high"):
                problems.append({"rule": "SEC-09", "line": x["line"], "message": f"{x['name']}: {x['message']}", "excerpt": x["excerpt"]})
    return problems, warnings


# ---------------------------------------------------------------- ledger inference
LEDGER_RULES = [
    ("IB-40", r"\bISNULL\s*\(", r"\b(coalesce|nvl)\s*\(", "ISNULL()", "coalesce()", "no ISNULL"),
    ("IB-41", r"\bIIF\s*\(", r"\bif\s*\(|\bCASE\s+WHEN\b", "IIF()", "if() / CASE", "no IIF"),
    ("IB-42", r"\bGETDATE\s*\(|\bSYSUTCDATETIME\s*\(", r"\bcurrent_timestamp\b", "GETDATE()", "current_timestamp()", "session/UTC time zone"),
    ("IB-43", r"\bDATEADD\s*\(", r"\b(date_add|timestampadd|date_sub)\s*\(", "DATEADD(part, n, d)", "date_add(d, n) / timestampadd(unit, n, ts)", "argument order differs"),
    ("IB-43", r"\bDATEDIFF\s*\(", r"\b(datediff|date_diff|timestampdiff)\s*\(", "DATEDIFF(part, a, b)", "datediff(b, a) / timestampdiff(unit, a, b)", "argument order reversed"),
    ("IB-44", r"\bCHARINDEX\s*\(", r"\b(instr|locate|position|strpos)\s*\(", "CHARINDEX(x, s)", "instr(s, x)", "arguments swapped"),
    ("IB-44", r"\bLEN\s*\(", r"\blength\s*\(", "LEN()", "length()", ""),
    ("IB-45", r"\bTOP\s*\(?\s*\d", r"\bLIMIT\s+\d", "TOP n", "LIMIT n", "ORDER BY required"),
    ("IB-46", r"'\s*\+\s*|\+\s*'", r"\bconcat\s*\(|\|\|", "'+' concatenation", "concat() / ||", "NULL propagates"),
    ("IB-46", r"(?<![\w'])N'", None, "N'…' literals", "plain literals", ""),
    ("IB-47", r"\bSTRING_AGG\s*\(", r"\blistagg\s*\(|\barray_join\s*\(", "STRING_AGG()", "listagg() / array_join(sort_array(collect_list()))", "ordering explicit"),
    ("IB-48", r"\bNEWID\s*\(", r"\buuid\s*\(", "NEWID()", "uuid()", "non-deterministic"),
    ("IB-49", r"(?<![\w.])\w+\s*/\s*\w+(?![\w.])", r"\bdiv\b", "integer division", "div", "'/' is float division in Spark"),
    ("IB-50", r"\bTRY_CAST\s*\(", r"\btry_cast\s*\(", "TRY_CAST", "try_cast (kept)", "ANSI mode raises without try_"),
    ("IB-50", r"\bCONVERT\s*\(", r"\b(CAST|date_format|to_date|to_timestamp)\s*\(", "CONVERT(type, x, style)", "CAST / date_format", ""),
    ("IB-51", r"\[[A-Za-z_][\w ]*\]", None, "[bracketed] identifiers", "lower-case identifiers", "Glue catalog folds names"),
    ("IB-51", r"\bWITH\s*\(\s*NOLOCK", None, "WITH (NOLOCK)", "removed", ""),
    ("IB-52", r"\bLIKE\b|=", r"\blower\s*\(|COLLATE\s+UTF8_LCASE", "case-insensitive comparison (_CI_AS)", "lower() / UTF8_LCASE", "Athena is case-sensitive"),
    ("IB-60", r"\bMERGE\b", r"\bMERGE\s+INTO\b", "MERGE", "MERGE INTO with deduplicated source", "single-match rule"),
    ("IB-61", r"\bWHEN\s+NOT\s+MATCHED\s+BY\s+SOURCE\b", r"\bDELETE\s+FROM\b", "WHEN NOT MATCHED BY SOURCE", "separate DELETE", "Athena has no BY SOURCE"),
    ("IB-63", r"\bINTO\s+#\w+", r"\bTEMPORARY\s+VIEW\b|\bWITH\s+\w+\s+AS\s*\(", "SELECT INTO #t", "temporary view / CTE", ""),
    ("IB-64", r"\bUNION\s+ALL\b", r"\bWITH\s+RECURSIVE\b", "recursive CTE", "WITH RECURSIVE (Athena)", "Spark 4.1+ only"),
    ("IB-65", r"\bROW_NUMBER\s*\(\)\s*OVER\b", r"\bROW_NUMBER\s*\(\)\s*OVER\b[\s\S]*\)\s*\w*\s*WHERE\s+\w*\.?rn\s*=\s*1", "ROW_NUMBER filter", "window in a subquery", "QUALIFY is not portable"),
    ("IB-70", r"\bCREATE\s+(OR\s+ALTER\s+)?VIEW\b", r"\bCREATE\s+(OR\s+REPLACE\s+)?(PROTECTED\s+MULTI\s+DIALECT\s+)?VIEW\b", "view", "Athena view / Glue multi-dialect view", "Trino SQL for serving"),
    ("IB-73", r"\bSELECT\b", r"\bFOR\s+(TIMESTAMP|VERSION)\s+AS\s+OF\b", "snapshot", "time travel", "row counts at a snapshot (V-012)"),
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


# ---------------------------------------------------------------- Glue job rendering
def render_job(spec: dict) -> str:
    req = ("catalog", "source_table", "target_table", "merge_keys")
    missing = [k for k in req if not spec.get(k)]
    if missing:
        raise SystemExit(f"job spec missing {missing}; required: {req} (optional: update_columns, watermark_column, source_sql)")
    if not isinstance(spec["merge_keys"], list) or not all(re.fullmatch(r"[a-z_][a-z0-9_]*", k) for k in spec["merge_keys"]):
        raise SystemExit("merge_keys must be a list of lower-case snake_case column names")
    for k in ("catalog", "source_table", "target_table"):
        if not re.fullmatch(r"[A-Za-z_][\w.]*", spec[k]):
            raise SystemExit(f"{k} must be an identifier like catalog.db.table")
    tmpl = (TEMPLATES / "glue_iceberg_merge.py.tmpl").read_text(encoding="utf-8")
    transform = ""
    if spec.get("source_sql"):
        sql = spec["source_sql"].replace('"""', "'''")
        transform = f'src.createOrReplaceTempView("src_raw")\nsrc = spark.sql("""{sql}""")  # source transformation from the converted SQL'
    rep = {"__TOOL_VERSION__": TOOL_VERSION, "__GENERATED_AT__": now_rfc3339(), "__RUN_ID__": LOG.run_id, "__CATALOG__": spec["catalog"],
           "__SOURCE_TABLE__": spec["source_table"], "__TARGET_TABLE__": spec["target_table"], "__MERGE_KEYS__": json.dumps(spec["merge_keys"]),
           "__UPDATE_COLUMNS__": json.dumps(spec.get("update_columns")), "__WATERMARK_COLUMN__": json.dumps(spec.get("watermark_column")),
           "__SOURCE_TRANSFORM__": transform}
    for k, v in rep.items():
        tmpl = tmpl.replace(k, v)
    return tmpl


# ---------------------------------------------------------------- Athena execution
def split_statements(sql: str) -> list:
    parts, cur, in_str, in_line, in_block = [], [], False, False, False
    i, n = 0, len(sql)
    while i < n:
        ch, nxt = sql[i], sql[i + 1] if i + 1 < n else ""
        if in_line:
            cur.append(ch); in_line = ch != "\n"
        elif in_block:
            cur.append(ch)
            if ch == "*" and nxt == "/":
                cur.append("/"); i += 1; in_block = False
        elif in_str:
            cur.append(ch); in_str = ch != "'"
        elif ch == "'":
            in_str = True; cur.append(ch)
        elif ch == "-" and nxt == "-":
            in_line = True; cur.append(ch)
        elif ch == "/" and nxt == "*":
            in_block = True; cur.append(ch)
        elif ch == ";":
            parts.append("".join(cur)); cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    lead = re.compile(r"^(\s*(--[^\n]*(\n|$)|/\*.*?\*/))*\s*", re.S)
    return [p for p in (lead.sub("", x).strip() for x in parts) if p]


def run_on_athena(sql_text: str, database: str, workgroup: str | None, output_location: str | None, catalog: str = "AwsDataCatalog", timeout: int = 120, source: str = "") -> dict:
    from migkit.services import Services, ServiceUnavailable
    if not TEST_DB.search(database or ""):
        raise SecurityRefusal(f"database '{database}' is not a test database (name must contain test/dev/sandbox/local)", [])
    crit = [x for x in security.scan_text(sql_text, "pgsql", source) if x["rule"] in ("SEC-01", "SEC-02", "SEC-03") or (x["rule"] == "SEC-04" and x["severity"] == "critical")]
    if crit:
        raise SecurityRefusal("SQL failed the security scan; it will not be executed", crit)
    stmts = split_statements(sql_text)
    if not stmts:
        return {"status": "SKIPPED", "statements": 0}
    svc = Services(logger=LOG)
    results, overall = [], "SUCCEEDED"
    started = time.monotonic()
    try:
        for idx, stmt in enumerate(stmts, 1):
            args = ["athena", "start-query-execution", "--query-string", stmt, "--query-execution-context", f"Database={database},Catalog={catalog}",
                    "--client-request-token", f"{LOG.run_id}-{sha256_bytes(stmt.encode('utf-8'))[:20]}"]
            if workgroup:
                args += ["--work-group", workgroup]
            if output_location:
                args += ["--result-configuration", f"OutputLocation={output_location}"]
            r = svc.aws(*args, timeout=30)
            qid = r.get("QueryExecutionId")
            LOG.log("athena.execute", f"statement {idx}/{len(stmts)} submitted", query_execution_id=qid, database=database, workgroup=workgroup, sql_sha256=sha256_bytes(stmt.encode("utf-8")))
            state, reason, stats = "QUEUED", None, {}
            while time.monotonic() - started < timeout:
                q = svc.aws("athena", "get-query-execution", "--query-execution-id", qid).get("QueryExecution", {})
                state = q.get("Status", {}).get("State"); reason = q.get("Status", {}).get("StateChangeReason"); stats = q.get("Statistics", {})
                if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
                    break
                time.sleep(min(2.0, max(0.2, timeout / 60)))
            results.append({"id": qid, "state": state, "reason": reason, "dataScannedBytes": stats.get("DataScannedInBytes"), "engineMs": stats.get("EngineExecutionTimeInMillis")})
            LOG.log("athena.result", state, "INFO" if state == "SUCCEEDED" else "ERROR", query_execution_id=qid, reason=reason)
            if state != "SUCCEEDED":
                overall = "FAILED"; break
    except ServiceUnavailable as ex:
        LOG.log("athena.unavailable", str(ex), "WARN", database=database)
        return {"status": "UNAVAILABLE", "error": str(ex), "statements": len(stmts), "evidence": {"V-004": {"status": "ERROR", "evidence": f"Athena unavailable: {ex}"}}}
    return {"status": overall, "statements": len(stmts), "queries": results, "database": database, "executedAt": now_rfc3339(), "runId": LOG.run_id,
            "error": next((q["reason"] for q in results if q["state"] != "SUCCEEDED"), None),
            "evidence": {"V-004": {"status": "PASS" if overall == "SUCCEEDED" else "FAIL", "evidence": f"Athena {len(results)} query execution(s) {overall}"}}}


# ---------------------------------------------------------------- commands
def _read(p):
    path = pathlib.Path(p)
    big = security.check_size(path)
    if big:
        raise SecurityRefusal(f"{path} is too large", big)
    return path.read_text(encoding="utf-8-sig", errors="replace")


def cmd_ddl(a):
    text = _read(a.tsql)
    design = contract.load_json(a.design) if a.design else None
    dialects = ("athena", "spark") if a.dialect == "both" else (a.dialect,)
    with LOG.span("iceberg.ddl", source=str(a.tsql), dialects=list(dialects)) as o:
        sqls, ledger, warnings, status = convert_ddl(text, design, dialects)
        o.update(status=status, warnings=len(warnings))
    stem = pathlib.Path(a.tsql).stem.replace(".sqlserver", "")
    if a.out_dir:
        od = pathlib.Path(a.out_dir); od.mkdir(parents=True, exist_ok=True)
        for d, sql in sqls.items():
            (od / f"{stem}.{d}.sql").write_text(sql, encoding="utf-8", newline="\n"); print(f"wrote {od / f'{stem}.{d}.sql'}")
        print(f"{status}: {len(ledger)} ledger row(s), {len(warnings)} warning(s)")
    else:
        for d, sql in sqls.items():
            print(sql)
    if a.ledger:
        pathlib.Path(a.ledger).write_text(contract.canonical_json({"status": status, "ruleLedger": ledger, "warnings": warnings}), encoding="utf-8")
    for w in warnings:
        print(f"WARN  {w}")
    LOG.log("iceberg.ddl.done", status, "WARN" if status != "GENERATED" else "INFO", ledger_rows=len(ledger), warnings=warnings[:50])
    return 0 if status == "GENERATED" else 1


def cmd_check(a):
    text = _read(a.file)
    src = _read(a.source) if a.source else None
    dialect = "job" if str(a.file).endswith(".py") else a.dialect
    with LOG.span("iceberg.check", file=str(a.file), dialect=dialect) as o:
        problems, warnings = check_text(text, src, str(a.file), dialect)
        o.update(problems=len(problems), warnings=len(warnings))
    if a.json:
        print(contract.canonical_json({"problems": problems, "warnings": warnings}))
    else:
        for w in warnings:
            print(f"WARN  {a.file}:{w['line']}: {w['rule']} {w['message']} — {w['excerpt']}")
        for p in problems:
            print(f"FAIL  {a.file}:{p['line']}: {p['rule']} {p['message']} — {p['excerpt']}")
        print(f"check: {len(problems)} problem(s), {len(warnings)} warning(s)")
    LOG.log("iceberg.check.done", f"{len(problems)} problem(s)", "WARN" if problems else "INFO", file=str(a.file), problems=[p["rule"] for p in problems][:50])
    return 1 if problems else 0


def cmd_ledger(a):
    rows = infer_ledger(_read(a.tsql), _read(a.converted))
    if a.json:
        print(contract.canonical_json(rows))
    else:
        led = contract.RuleLedger(); led.rows = rows; print(led.markdown())
    return 0


def cmd_job(a):
    spec = contract.load_json(a.spec)
    with LOG.span("iceberg.job", spec=str(a.spec)) as o:
        code = render_job(spec)
        out = pathlib.Path(a.out); out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(code, encoding="utf-8", newline="\n")
        try:
            py_compile.compile(str(out), doraise=True)
        except py_compile.PyCompileError as ex:
            print(f"FAIL  {out}: does not compile — {ex.msg}"); o.update(status="compile_error"); return 1
        problems, warnings = check_text(code, None, str(out), "job")
        o.update(problems=len(problems), sha256=sha256_bytes(code.encode("utf-8")))
    for p in problems:
        print(f"FAIL  {out}:{p['line']}: {p['rule']} {p['message']} — {p['excerpt']}")
    print(f"wrote {out} (compiled; {len(problems)} problem(s))")
    return 1 if problems else 0


def cmd_run(a):
    text = _read(a.file)
    with LOG.span("iceberg.run", file=str(a.file), database=a.database) as o:
        r = run_on_athena(text, a.database, a.workgroup, a.output_location, a.catalog, a.timeout, str(a.file))
        o.update(status=r["status"])
    if a.evidence:
        pathlib.Path(a.evidence).write_text(contract.canonical_json(r), encoding="utf-8")
    print(contract.canonical_json(r))
    return 0 if r["status"] == "SUCCEEDED" else 1


def cmd_package(a):
    src = _read(a.tsql)
    files = {pathlib.Path(a.tsql).name: src}
    problems, warnings, ledger = [], [], []
    for cf in a.converted:
        t = _read(cf); files[pathlib.Path(cf).name] = t
        dialect = "job" if cf.endswith(".py") else ("athena" if ".athena." in cf else "spark")
        p, w = check_text(t, src if dialect != "job" else None, cf, dialect)
        problems += [{**x, "file": pathlib.Path(cf).name} for x in p]; warnings += [{**x, "file": pathlib.Path(cf).name} for x in w]
        if dialect != "job":
            ledger += infer_ledger(src, t)
    inv = ddl.inventory(src)
    req = contract.new_request(a.request_id or pathlib.Path(a.tsql).stem, "SQLServer", inv["object_type"], pathlib.Path(a.tsql).stem, src, "Iceberg")
    out = contract.new_output(req["requestId"])
    if a.classification and pathlib.Path(a.classification).exists():
        cls = contract.load_json(a.classification)
        out["classification"] = cls.get("classification", out["classification"])
        out["analysis"]["securityFindings"] = cls.get("analysis", {}).get("securityFindings", [])
    out["artifacts"]["convertedCode"] = files[pathlib.Path(a.converted[0]).name] if a.converted else ""
    out["artifacts"]["supportingCode"] = [pathlib.Path(c).name for c in a.converted[1:]]
    seen, dedup = set(), []
    for r in ledger:
        k = (r["rule"], r["sourceFeature"], r["targetTreatment"])
        if k not in seen:
            seen.add(k); r["seq"] = len(dedup) + 1; dedup.append(r)
    out["analysis"]["ruleLedger"] = dedup
    out["analysis"]["constructInventory"] = [{"construct": k, "count": v} for k, v in sorted(inv["constructs"].items())]
    out["analysis"]["warnings"] = [f"{w['file']} {w['rule']} line {w['line']}: {w['message']}" for w in warnings]
    out["analysis"]["manualReviewItems"] = [f"{p['file']} {p['rule']} line {p['line']}: {p['message']}" for p in problems] + \
        [f"{name} line {i + 1}: {l.strip()[:120]}" for name, text in files.items() for i, l in enumerate(text.splitlines()) if "MANUAL REVIEW REQUIRED" in l]
    executed = {"V-001": {"status": "PASS", "evidence": "contract validated"}, "V-002": {"status": "PASS", "evidence": f"sha256 {sha256_bytes(src.encode('utf-8'))}"}}
    if problems:
        contract.set_status(out, "PARTIAL", "STATIC_VALIDATION_FAILED"); executed["V-004"] = {"status": "FAIL", "evidence": f"{len(problems)} static problem(s)"}
    if out["analysis"]["manualReviewItems"]:
        contract.set_status(out, "PARTIAL", "UNSUPPORTED_CONSTRUCT")
    if a.evidence and pathlib.Path(a.evidence).exists():
        executed.update(contract.load_json(a.evidence).get("evidence", {}))
        if executed.get("V-004", {}).get("status") == "PASS" and out["status"] == "GENERATED":
            out["status"] = "VALIDATED"
    applicable = ["V-001", "V-002", "V-004", "V-006", "V-009", "V-012", "V-014", "V-032", "V-033", "V-035", "V-036"]
    out["validation"] = contract.validation_manifest(applicable, executed)
    m = contract.write_package(a.out, req, out, files=files)
    print(f"package → {a.out} ({out['status']}, {len(dedup)} ledger rows, {len(problems)} problems)")
    LOG.log("iceberg.package", out["status"], package=str(a.out), files=len(m["files"]), status=out["status"])
    return 0 if out["status"] in ("GENERATED", "VALIDATED") else 1


def main():
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ddl"); p.add_argument("tsql"); p.add_argument("--design"); p.add_argument("--dialect", choices=["athena", "spark", "both"], default="both")
    p.add_argument("--out-dir"); p.add_argument("--ledger"); p.set_defaults(fn=cmd_ddl)
    p = sub.add_parser("check"); p.add_argument("file"); p.add_argument("--source"); p.add_argument("--dialect", choices=["spark", "athena"], default="spark"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_check)
    p = sub.add_parser("ledger"); p.add_argument("tsql"); p.add_argument("converted"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_ledger)
    p = sub.add_parser("job"); p.add_argument("spec"); p.add_argument("--out", required=True); p.set_defaults(fn=cmd_job)
    p = sub.add_parser("run"); p.add_argument("file"); p.add_argument("--database", required=True); p.add_argument("--workgroup"); p.add_argument("--output-location")
    p.add_argument("--catalog", default="AwsDataCatalog"); p.add_argument("--timeout", type=int, default=120); p.add_argument("--evidence"); p.set_defaults(fn=cmd_run)
    p = sub.add_parser("package"); p.add_argument("tsql"); p.add_argument("converted", nargs="+"); p.add_argument("--out", required=True); p.add_argument("--classification")
    p.add_argument("--evidence"); p.add_argument("--request-id"); p.set_defaults(fn=cmd_package)
    a = ap.parse_args()
    with LOG.span(f"iceberg.{a.cmd}", argv=[str(x) for x in sys.argv[1:]], tool_version=TOOL_VERSION) as o:
        rc = a.fn(a)
        o.update(status="ok" if rc == 0 else "failed", exit_code=rc)
        return rc


if __name__ == "__main__":
    sys.exit(main())
