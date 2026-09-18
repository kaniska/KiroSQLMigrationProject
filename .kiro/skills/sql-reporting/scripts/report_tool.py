#!/usr/bin/env python3
"""
report_tool.py — target-aware checks for reporting SQL (sql-reporting skill).

  check <file.sql> --target postgres|redshift|athena|spark [--json]
        reporting dialect rules (RD-nn) + the target's residual-SQL linter (redshift_tool / iceberg_tool)
        + security scan. Exit 1 on problems.
  toolbox --target <t> [--need <text>]      print the dialect rows (references/dialects.md) for a target
  examples --target <t>                     list the worked examples for a target
  targets                                   list targets and their delivery form

Exit codes: 0 ok · 1 problems · 2 usage · 3 security refusal.
"""
import argparse
import os
import pathlib
import re
import sys

SKILL = pathlib.Path(__file__).resolve().parents[1]
SKILLS = SKILL.parent
_KIT = pathlib.Path(os.environ.get("MIGKIT_PATH") or SKILLS / "sql-conversion" / "scripts")
sys.path.insert(0, str(_KIT))
try:
    from migkit import contract, ddl, security
    from migkit.audit import AuditLogger
    from migkit.platform_compat import utf8_stdio
except ImportError as _ex:
    sys.stderr.write(f"ERROR: migkit not found at {_KIT} ({_ex}); install the sql-conversion skill next to this one\n")
    sys.exit(2)

TOOL_VERSION = "1.0.0"
LOG = AuditLogger("report_tool")
TARGETS = {
    "postgres": {"delivery": "CREATE OR REPLACE FUNCTION report_<name>(…) RETURNS TABLE(…) LANGUAGE sql STABLE (or a view)", "steering": "migration.md", "examples": "references/examples/*.sql (executed by the self-test)"},
    "redshift": {"delivery": "CREATE OR REPLACE VIEW (late-binding over external tables); PREPARE/EXECUTE or a params CTE; procedure + refcursor only when needed", "steering": "redshift.md", "examples": "references/examples/redshift/"},
    "athena": {"delivery": "CREATE OR REPLACE VIEW + PREPARE … EXECUTE … USING (no user functions)", "steering": "iceberg.md", "examples": "references/examples/athena/"},
    "spark": {"delivery": "CREATE OR REPLACE TEMPORARY VIEW / job SQL with ${var} substitution", "steering": "iceberg.md", "examples": "references/examples/spark/"},
}
TSQL = [(r"\bISNULL\s*\(", "ISNULL()"), (r"\bIIF\s*\(", "IIF()"), (r"\bGETDATE\s*\(", "GETDATE()"), (r"\[[A-Za-z_][\w ]*\]", "[bracketed identifier]"),
        (r"\bWITH\s*\(\s*NOLOCK", "WITH (NOLOCK)"), (r"\bTOP\s*\(?\s*\d", "TOP n"), (r"(?<![\w'])N'", "N'' literal"), (r"\bDATEADD\s*\(", "DATEADD()"), (r"\bDATEDIFF\s*\(", "DATEDIFF()")]
# (rule, severity, regex, message) per target — on top of the target linters
DIALECT_CHECKS = {
    "postgres": [
        ("RD-14", "warning", r"\bCREATE\s+(OR\s+REPLACE\s+)?FUNCTION\b(?![\s\S]*\bSTABLE\b)", "report functions should be LANGUAGE sql STABLE"),
        ("RD-12", "problem", r"\bRETURNS\s+TABLE\s*\([^)]*\b(double\s+precision|float8|real|float4)\b", "money/ratios must be NUMERIC, never floating point (RQ-19)"),
        ("RD-01", "warning", r"\bBETWEEN\b[^\n]*\b(created_at|_at|_ts|timestamp)\b", "half-open ranges (>= start AND < end) on timestamps (RQ-05)"),
    ],
    "redshift": [
        ("RD-01", "problem", r"\bgenerate_series\s*\(", "generate_series runs on the leader node only and cannot join user tables: recursive CTE or date dimension"),
        ("RD-03", "problem", r"\bFILTER\s*\(\s*WHERE\b", "FILTER is not supported on Redshift: SUM(CASE WHEN … THEN x END)"),
        ("RD-10", "problem", r"\bDISTINCT\s+ON\b", "DISTINCT ON is PostgreSQL-only: ROW_NUMBER() … QUALIFY rn = 1 or a subquery"),
        ("RD-11", "problem", r"\bstring_agg\s*\(", "string_agg → LISTAGG(x, ', ') WITHIN GROUP (ORDER BY x)"),
        ("RD-14", "problem", r"\bLANGUAGE\s+sql\b|\bRETURNS\s+TABLE\b", "no SQL table functions on Redshift: deliver a view (PREPARE/EXECUTE for parameters) or a procedure with a refcursor"),
        ("RD-18", "problem", r"\bAT\s+TIME\s+ZONE\b", "AT TIME ZONE → CONVERT_TIMEZONE('UTC', 'Region/City', ts)"),
        ("RD-08", "warning", r"\bpercentile_(cont|disc)\s*\(", "PERCENTILE_CONT/DISC: verify the aggregate form on your engine version, or APPROXIMATE PERCENTILE_DISC; say exact vs approximate (RQ-10)"),
        ("RD-05", "problem", r"\bWINDOW\s+\w+\s+AS\s*\(", "named windows (WINDOW w AS …) are not supported on Redshift: inline the OVER (…)"),
        ("RD-13", "problem", r"\bmake_date\s*\(", "make_date does not exist on Redshift: DATE 'yyyy-mm-dd' literals or TO_DATE"),
        ("RD-15", "problem", r"\bwidth_bucket\s*\(|\bjson_agg\s*\(|\brow_to_json\s*\(", "PostgreSQL-only function: FLOOR(x / w) * w for buckets, SUPER/JSON functions for JSON"),
        ("RD-02", "warning", r"\bdate_trunc\s*\(\s*''\s*,[^)]*\)(?!\s*::\s*DATE|\s*AS\s+DATE)", "DATE_TRUNC returns a timestamp: cast to DATE for a period key"),
    ],
    "athena": [
        ("RD-01", "problem", r"\bgenerate_series\s*\(", "generate_series does not exist on Athena: CROSS JOIN UNNEST(sequence(start, end, INTERVAL '1' MONTH))"),
        ("RD-10", "problem", r"\bDISTINCT\s+ON\b", "DISTINCT ON is PostgreSQL-only: ROW_NUMBER() in a subquery"),
        ("RD-11", "problem", r"\bstring_agg\s*\(", "string_agg → listagg(x, ', ') WITHIN GROUP (ORDER BY x) or array_join(array_agg(x ORDER BY x), ', ')"),
        ("RD-08", "problem", r"\bpercentile_(cont|disc)\s*\(", "percentile_cont/disc do not exist on Athena: approx_percentile(x, 0.5) (approximate — say so, RQ-10)"),
        ("RD-14", "problem", r"\bCREATE\s+(OR\s+REPLACE\s+)?FUNCTION\b|\bLANGUAGE\s+sql\b|\bRETURNS\s+TABLE\b", "Athena has no user-defined SQL functions: CREATE OR REPLACE VIEW + PREPARE … EXECUTE … USING"),
        ("RD-12", "problem", r"::\s*[A-Za-z]", "Trino has no :: cast operator: CAST(x AS type)"),
        ("RD-12", "problem", r"\bNUMERIC\s*\(", "NUMERIC is not an Athena type name: DECIMAL(p,s)"),
        ("RD-07", "problem", r"\bQUALIFY\b", "QUALIFY is not supported on Athena: filter the window in a subquery"),
        ("RD-13", "problem", r"\bmake_date\s*\(", "make_date does not exist on Athena: DATE 'yyyy-mm-dd' or date(…)"),
        ("RD-15", "problem", r"\bjson_agg\s*\(|\brow_to_json\s*\(", "PostgreSQL-only JSON functions: cast(… AS JSON) / json_format on Athena"),
        ("RD-03", "warning", r"\bSUM\s*\(\s*CASE\s+WHEN\b", "Athena supports FILTER (WHERE …); CASE works too"),
    ],
    "spark": [
        ("RD-01", "problem", r"\bgenerate_series\s*\(", "generate_series does not exist in Spark SQL: explode(sequence(start, end, interval 1 month))"),
        ("RD-10", "problem", r"\bDISTINCT\s+ON\b", "DISTINCT ON is PostgreSQL-only: ROW_NUMBER() in a subquery"),
        ("RD-11", "warning", r"\bstring_agg\s*\(|\blistagg\s*\(", "string_agg/listagg need Spark 4: array_join(sort_array(collect_list(x)), ', ') is portable"),
        ("RD-08", "problem", r"\bpercentile_(cont|disc)\s*\(", "percentile_cont/disc do not exist in Spark SQL: percentile(x, 0.5) (exact) or percentile_approx"),
        ("RD-14", "problem", r"\bCREATE\s+(OR\s+REPLACE\s+)?FUNCTION\b|\bLANGUAGE\s+sql\b|\bRETURNS\s+TABLE\b", "no SQL table functions: CREATE OR REPLACE TEMPORARY VIEW or job SQL"),
        ("RD-12", "warning", r"::\s*[A-Za-z]", ":: cast works only on recent Spark versions: CAST(x AS type) is portable"),
        ("RD-18", "problem", r"\bAT\s+TIME\s+ZONE\b", "AT TIME ZONE → from_utc_timestamp(ts, 'Region/City')"),
        ("RD-07", "problem", r"\bQUALIFY\b", "QUALIFY is not in OSS Spark SQL: filter the window in a subquery"),
        ("RD-15", "problem", r"\bjson_agg\s*\(|\brow_to_json\s*\(", "PostgreSQL-only JSON functions: to_json(collect_list(struct(…)))"),
        ("RD-12", "warning", r"\bround\s*\(\s*\w+(\.\w+)?\s*\*\s*100(\.0)?\s*/", "cast to DECIMAL before dividing: '/' is floating-point in Spark"),
    ],
}


def _linter(target):
    if target == "redshift":
        sys.path.insert(0, str(SKILLS / "sql-conversion-redshift" / "scripts")); import redshift_tool
        return lambda text, name: redshift_tool.check_text(text, None, name)
    if target in ("athena", "spark"):
        sys.path.insert(0, str(SKILLS / "sql-conversion-iceberg" / "scripts")); import iceberg_tool
        return lambda text, name: iceberg_tool.check_text(text, None, name, target)
    return None


def check_text(text: str, target: str, name: str = "") -> tuple:
    if target not in TARGETS:
        raise SystemExit(f"unknown target {target}; one of {', '.join(TARGETS)}")
    code = ddl.strip_comments(text)
    code_nolit = re.sub(r"'(?:[^']|'')*'", "''", code)
    problems, warnings = [], []
    for rule, sev, rx, msg in DIALECT_CHECKS[target]:
        m = re.search(rx, code_nolit, re.I)
        if m:
            (problems if sev == "problem" else warnings).append({"rule": rule, "line": code.count("\n", 0, m.start()) + 1, "message": msg, "excerpt": m.group(0)[:60].replace("\n", " ")})
    for rx, label in TSQL:
        if target == "redshift" and label in ("GETDATE()", "TOP n", "DATEADD()", "DATEDIFF()"):
            continue
        m = re.search(rx, code_nolit, re.I)
        if m:
            problems.append({"rule": "RD-16", "line": code.count("\n", 0, m.start()) + 1, "message": f"residual T-SQL {label}", "excerpt": m.group(0)[:60]})
    lint = _linter(target)
    if lint:
        p2, w2 = lint(text, name)
        problems += [x for x in p2 if x["rule"] not in {p["rule"] for p in problems} or x["rule"].startswith("SEC")]
        warnings += w2
    else:
        for x in security.scan_text(text, "pgsql", name):
            if x["rule"] in ("SEC-01", "SEC-02", "SEC-03") or (x["rule"] == "SEC-04" and x["severity"] == "critical"):
                problems.append({"rule": x["rule"], "line": x["line"], "message": f"{x['name']}: {x['message']}", "excerpt": x["excerpt"]})
    return problems, warnings


def toolbox(target: str, need: str | None = None) -> list:
    col = {"postgres": 2, "redshift": 3, "athena": 4, "spark": 5}[target]
    rows = []
    for line in (SKILL / "references" / "dialects.md").read_text(encoding="utf-8").splitlines():
        if line.startswith("| RD-"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            if need is None or need.lower() in cells[1].lower():
                rows.append((cells[0], cells[1], cells[col]))
    return rows


def cmd_check(a):
    path = pathlib.Path(a.file)
    big = security.check_size(path)
    if big:
        LOG.log("security.refused", f"{path} too large", "ERROR"); sys.stderr.write(f"REFUSED (security): {path} is too large\n"); return 3
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    with LOG.span("report.check", file=str(path), target=a.target) as o:
        problems, warnings = check_text(text, a.target, str(path))
        o.update(problems=len(problems), warnings=len(warnings))
    if a.json:
        print(contract.canonical_json({"target": a.target, "problems": problems, "warnings": warnings}))
    else:
        for w in warnings:
            print(f"WARN  {path}:{w['line']}: {w['rule']} {w['message']} — {w['excerpt']}")
        for p in problems:
            print(f"FAIL  {path}:{p['line']}: {p['rule']} {p['message']} — {p['excerpt']}")
        print(f"check ({a.target}): {len(problems)} problem(s), {len(warnings)} warning(s)")
    return 1 if problems else 0


def cmd_toolbox(a):
    for rid, need, how in toolbox(a.target, a.need):
        print(f"{rid}  {need}\n      {how}")
    return 0


def cmd_examples(a):
    d = SKILL / "references" / "examples" / ("" if a.target == "postgres" else a.target)
    for f in sorted(d.glob("*.sql")):
        print(f.relative_to(SKILL))
    return 0


def cmd_targets(a):
    for t, v in TARGETS.items():
        print(f"{t:<9} delivery: {v['delivery']}\n          steering: .kiro/steering/{v['steering']} · examples: {v['examples']}")
    return 0


def main():
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check"); p.add_argument("file"); p.add_argument("--target", required=True, choices=list(TARGETS)); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_check)
    p = sub.add_parser("toolbox"); p.add_argument("--target", required=True, choices=list(TARGETS)); p.add_argument("--need"); p.set_defaults(fn=cmd_toolbox)
    p = sub.add_parser("examples"); p.add_argument("--target", required=True, choices=list(TARGETS)); p.set_defaults(fn=cmd_examples)
    p = sub.add_parser("targets"); p.set_defaults(fn=cmd_targets)
    a = ap.parse_args()
    with LOG.span(f"report.{a.cmd}", argv=[str(x) for x in sys.argv[1:]], tool_version=TOOL_VERSION) as o:
        rc = a.fn(a)
        o.update(status="ok" if rc == 0 else "failed", exit_code=rc)
        return rc


if __name__ == "__main__":
    sys.exit(main())
