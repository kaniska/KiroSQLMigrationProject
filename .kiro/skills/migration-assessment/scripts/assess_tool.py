#!/usr/bin/env python3
"""
assess_tool.py — deterministic intake, discovery and placement for SQL Server objects
(the "classify before translate" gate of the migration factory).

  assess    <file.sql|dir> [--consumer app|api|bi|etl|unknown] [--target AuroraPostgreSQL|Redshift|Iceberg]
            [--security-rules FILE] [--out DIR]
            → one classification.json + report.md per object: construct inventory, dependencies,
              security findings, M2RVE role, complexity L1–L4, review tier T1–T3, target candidates
              with rationale, recommended skill, open questions, stop codes (universal output contract)
  inventory <dir> [--log metadata/migration_log.json]
            → every object in a source folder with its status in the migration log; audits the log
              (missing entries, entries without a source, unacknowledged manual-review flags)
  validate  <request.json>          → universal input contract validation (stable diagnostics)
  questions [--object-type T] [--consumer C]  → the intake questions to ask when the target is undecided

Exit codes: 0 ok · 1 findings that need a decision (BLOCKED/PARTIAL) · 2 usage · 3 security refusal.
Never invents metadata: a missing consumer profile, security mapping or target decision becomes an
open question and a stop code, not a default.
"""
import argparse
import json
import os
import pathlib
import re
import sys

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
LOG = AuditLogger("assess_tool")
CONSUMERS = ("app", "api", "bi", "etl", "unknown")

# M2RVE positioning matrix (requirements §3.2) expressed as candidate lists per role/object type
CANDIDATES = {
    ("TABLE", "raw"):     [("Iceberg", "raw source table → Iceberg RDP (lake-first entry point)"), ("AuroraPostgreSQL", "operational table when transactional / low-latency behaviour is required")],
    ("TABLE", "product"): [("AuroraPostgreSQL", "finished operational product"), ("Redshift", "finished analytical product"), ("Iceberg", "shared data product on the lake")],
    ("VIEW", "MIDDLE"):   [("Iceberg", "intermediate transformation → Iceberg DDP built by a Glue job (Materialize the Middle)"), ("AuroraPostgreSQL", "materialized view when consumers stay on Aurora"), ("Redshift", "materialized view when consumers are BI on Redshift")],
    ("VIEW", "app"):      [("AuroraPostgreSQL", "application-facing edge view over Aurora foundations")],
    ("VIEW", "api"):      [("AuroraPostgreSQL", "API-facing edge view over Aurora foundations")],
    ("VIEW", "bi"):       [("Redshift", "BI/reporting edge view (regular or late-binding) over Redshift / Spectrum foundations")],
    ("VIEW", "etl"):      [("Iceberg", "ETL-consumed transformation → Spark SQL / Glue job on Iceberg")],
    ("PROCEDURE", "app"): [("AuroraPostgreSQL", "procedural logic → PL/pgSQL function/procedure")],
    ("PROCEDURE", "api"): [("AuroraPostgreSQL", "procedural logic → PL/pgSQL function/procedure")],
    ("PROCEDURE", "bi"):  [("Redshift", "set-based load logic → Redshift stored procedure (PL/pgSQL subset)"), ("AuroraPostgreSQL", "procedural logic that Redshift cannot host")],
    ("PROCEDURE", "etl"): [("Iceberg", "data movement → Glue PySpark job writing Iceberg (read-transform-validate-write)"), ("Redshift", "set-based load into Redshift tables")],
    ("FUNCTION", "app"):  [("AuroraPostgreSQL", "scalar/table function → PL/pgSQL or SQL function")],
    ("FUNCTION", "api"):  [("AuroraPostgreSQL", "scalar/table function → PL/pgSQL or SQL function")],
    ("FUNCTION", "bi"):   [("Redshift", "scalar function → Redshift SQL/Python UDF (no table-valued functions)"), ("AuroraPostgreSQL", "table-valued functions")],
    ("FUNCTION", "etl"):  [("Iceberg", "expression logic → Spark SQL / PySpark UDF")],
    ("TRIGGER", "*"):     [("AuroraPostgreSQL", "triggers exist only on Aurora PostgreSQL; Redshift and Iceberg have none → redesign as job/application logic elsewhere")],
    ("ETL_SQL", "*"):     [("Iceberg", "embedded ETL SQL → Spark SQL / Glue job"), ("Redshift", "set-based SQL on Redshift"), ("AuroraPostgreSQL", "SQL against Aurora")],
}
SKILL_FOR_TARGET = contract.SKILL_FOR_TARGET
SEC_FUNCS = re.compile(r"\b(ORIGINAL_LOGIN|SUSER_SNAME|SUSER_NAME|SYSTEM_USER|SESSION_USER|USER_NAME|CURRENT_USER|IS_MEMBER|IS_ROLEMEMBER|HAS_PERMS_BY_NAME|SESSION_CONTEXT|CONTEXT_INFO)\s*\(", re.I)
AUTH_TABLE = re.compile(r"\b(User(Department)?Access|UserRole|Permission|Authori[sz]ation|AccessControl|RowSecurity)\w*\b", re.I)


# ---------------------------------------------------------------- classification
def complexity(inv: dict) -> str:
    heavy, cons = inv["heavy"], inv["constructs"]
    procedural = any(k in cons for k in ("cursor", "while_loop", "try_catch", "transaction", "dynamic_sql"))
    if any(k in cons for k in ("clr_or_xp", "linked_server", "spatial", "goto", "hierarchyid", "service_broker_mail")) or len(heavy) >= 3:
        return "L4"
    if heavy or procedural or cons.get("multiple_result_sets", 0) > 1 or inv["security"]:
        return "L3"
    if any(k in cons for k in ("cte", "window_function", "update_from_join", "insert_select", "cdc_watermark", "string_agg", "top")) \
            or inv.get("joins", 0) > 0 or inv.get("aggregates", 0) > 0 or inv["statements"] > 5:
        return "L2"
    return "L1"


def security_findings(sql: str) -> list:
    out = []
    code = ddl.strip_comments(sql)
    for m in SEC_FUNCS.finditer(code):
        out.append({"kind": "identity-function", "construct": m.group(1).upper(), "line": code.count("\n", 0, m.start()) + 1,
                    "message": "session identity used in logic — target identity mapping must be approved (SECURITY_MAPPING_REQUIRED)"})
    for m in AUTH_TABLE.finditer(code):
        out.append({"kind": "authorization-join", "construct": m.group(0), "line": code.count("\n", 0, m.start()) + 1,
                    "message": "join/filter against an authorization table — candidate for RLS policy, needs identity mapping"})
    if re.search(r"\bMASKED\s+WITH\b", code, re.I):
        out.append({"kind": "column-masking", "construct": "MASKED WITH", "line": 0, "message": "dynamic data masking → CLS/masking policy on the target"})
    if re.search(r"\bEXECUTE\s+AS\b", code, re.I):
        out.append({"kind": "impersonation", "construct": "EXECUTE AS", "line": 0, "message": "impersonation → SECURITY DEFINER / role design decision"})
    return out


def role_for(obj_type: str, inv: dict, refs: dict, consumer: str, referenced_by: int, updatable: bool) -> tuple:
    """(role, reason)"""
    cons = inv["constructs"]
    if obj_type == "VIEW":
        joins = len(re.findall(r"\bJOIN\b", " ".join(refs["reads_writes"])))  # placeholder, real join count below
        heavy_logic = any(k in cons for k in ("cte", "window_function", "recursive_cte", "string_agg", "pivot", "cross_apply")) or inv.get("joins", 0) >= 2 or inv.get("aggregates", 0) > 0
        if updatable:
            return "ELIMINATE", "updatable view: eliminate write-through, keep a read interface only"
        if referenced_by > 0 and heavy_logic:
            return "MIDDLE", f"consumed by {referenced_by} other object(s) and carries joins/aggregation/window logic → materialize"
        if referenced_by > 0:
            return "MIDDLE", f"consumed by {referenced_by} other object(s) in the chain"
        if not heavy_logic and inv.get("joins", 0) == 0 and not cons.get("top") and "where" not in inv:
            return "ELIMINATE", "projection-only convenience view: review consumers before creating a redundant target object"
        if consumer == "unknown":
            return "REVIEW", "edge view but the consumer (app/api/bi/etl) is unknown → placement decision required"
        return "RIGHT_EDGE", f"consumer-facing edge view for {consumer} consumers"
    if obj_type == "TABLE":
        if cons.get("identity") or consumer in ("app", "api"):
            return "LEFT_EDGE", "source table: raw entry point (Iceberg RDP) or operational table"
        return "LEFT_EDGE", "source table: raw entry point"
    if obj_type in ("PROCEDURE", "FUNCTION", "TRIGGER"):
        if any(k in cons for k in ("insert_select", "merge", "truncate", "bulk_insert", "cdc_watermark")) and not cons.get("multiple_result_sets"):
            return "MIDDLE", "data-movement routine (insert-select / MERGE / truncate-load) → transformation zone"
        return "RIGHT_EDGE", "operational routine that returns results or changes state for an application"
    return "REVIEW", "embedded SQL: placement depends on the consuming job"


def candidates_for(obj_type: str, role: str, consumer: str, inv: dict) -> list:
    cons = inv["constructs"]
    if obj_type == "TRIGGER":
        key = ("TRIGGER", "*")
    elif obj_type == "ETL_SQL":
        key = ("ETL_SQL", "*")
    elif obj_type == "TABLE":
        key = ("TABLE", "product" if consumer in ("app", "api", "bi") else "raw")
    elif obj_type == "VIEW":
        key = ("VIEW", "MIDDLE" if role == "MIDDLE" else (consumer if consumer in ("app", "api", "bi", "etl") else "app"))
    else:
        key = (obj_type, consumer if consumer in ("app", "api", "bi", "etl") else "app")
    cands = list(CANDIDATES.get(key, []))
    # feasibility filters
    out = []
    for target, why in cands:
        blockers = []
        if target == "Redshift":
            for k, why2 in (("cursor", "cursors are limited to result-set return"), ("trigger", "no triggers"), ("table_variable", "no table variables"),
                            ("global_temp_table", "no global temp tables"), ("for_xml_json", "no FOR XML/JSON"), ("openjson_xml", "no XML methods; SUPER/JSON functions instead"),
                            ("clr_or_xp", "no CLR/xp_"), ("linked_server", "no linked servers"), ("spatial", "GEOMETRY/GEOGRAPHY need a spatial redesign")):
                if cons.get(k):
                    blockers.append(why2)
            if obj_type == "FUNCTION" and cons.get("multiple_result_sets"):
                blockers.append("table-valued functions are not supported")
        if target == "Iceberg":
            for k, why2 in (("cursor", "row-by-row logic must become set-based Spark"), ("dynamic_sql", "dynamic SQL must be redesigned"), ("transaction", "no multi-statement transactions across tables"),
                            ("output_params", "no output parameters: return a data product"), ("clr_or_xp", "no CLR"), ("linked_server", "no linked servers")):
                if cons.get(k):
                    blockers.append(why2)
        if target == "AuroraPostgreSQL":
            for k, why2 in (("clr_or_xp", "CLR/xp_ must be rewritten"), ("linked_server", "linked servers → postgres_fdw/dblink design")):
                if cons.get(k):
                    blockers.append(why2)
        out.append({"target": target, "rationale": why, "skill": SKILL_FOR_TARGET[target], "blockers": blockers, "feasible": not blockers})
    return out


def open_questions(obj_type: str, consumer: str, role: str, sec: list, inv: dict, target: str | None) -> list:
    q = []
    if consumer == "unknown":
        q.append("Who consumes this object: an application or API (Aurora PostgreSQL), BI/reporting (Redshift), an ETL/data product (Iceberg on S3 with Glue), or is it unused? (--consumer app|api|bi|etl)")
    if target is None:
        q.append("Which target platform is approved for it: AuroraPostgreSQL, Redshift or Iceberg? (--target …). Without a decision the status stays TARGET_DECISION_REQUIRED.")
    if obj_type == "VIEW" and role == "MIDDLE":
        q.append("This view is consumed by other objects: materialize it (Iceberg DDP / materialized view) or keep the chain? Which refresh frequency do consumers accept?")
    if sec:
        q.append("The object embeds security (identity functions or authorization joins): which target identity maps to the SQL Server login/user, and who approves the RLS/CLS policy? (--security-rules FILE)")
    cons = inv["constructs"]
    if cons.get("multiple_result_sets", 0) > 1:
        q.append("The procedure returns more than one result set: which callers read them, and may they be split into separate functions?")
    if cons.get("dynamic_sql"):
        q.append("Dynamic SQL is present: is the set of possible statements bounded (allowlisted) so it can be rewritten safely?")
    if cons.get("cdc_watermark") or cons.get("merge"):
        q.append("Load semantics: full reload, append, or merge? What is the business key, watermark, late-arrival rule and delete handling?")
    if cons.get("spatial"):
        q.append("Spatial data: is storage-only representation (WKB binary) enough, or are spatial predicates required on the target (PostGIS / Redshift GEOMETRY / a separate engine)?")
    if cons.get("linked_server") or inv.get("cross_database"):
        q.append("Cross-database or linked-server references: will the referenced databases move together, or is a federated access design needed?")
    return q


def assess_text(sql: str, name: str, consumer: str = "unknown", target: str | None = None, referenced_by: int = 0, security_rules: dict | None = None) -> dict:
    inv = ddl.inventory(sql)
    code = ddl.strip_comments(sql)
    inv["joins"] = len(re.findall(r"\bJOIN\b", code, re.I))
    inv["aggregates"] = len(re.findall(r"\b(SUM|COUNT|AVG|MIN|MAX)\s*\(", code, re.I)) if re.search(r"\bGROUP\s+BY\b", code, re.I) else 0
    if re.search(r"\bWHERE\b", code, re.I):
        inv["where"] = True
    refs = ddl.references(sql)
    obj_type = inv["object_type"]
    updatable = obj_type == "VIEW" and bool(re.search(r"\bWITH\s+CHECK\s+OPTION\b|INSTEAD\s+OF\b", code, re.I))
    sec = security_findings(sql)
    role, role_reason = role_for(obj_type, inv, refs, consumer, referenced_by, updatable)
    cx = complexity(inv)
    tier = contract.review_tier(cx, bool(sec))
    cands = candidates_for(obj_type, role, consumer, inv)
    chosen = None
    if target:
        chosen = next((c for c in cands if c["target"] == target), None) or {"target": target, "rationale": "user-selected target", "skill": SKILL_FOR_TARGET.get(target, ""), "blockers": [], "feasible": True}
        if target not in SKILL_FOR_TARGET:
            chosen = None
    out = contract.new_output(re.sub(r"[^A-Za-z0-9._:-]", "_", name))
    out["classification"] = {"role": role, "complexity": cx, "reviewTier": tier,
                             "targetDecision": chosen["target"] if chosen else "",
                             "decisionRationale": (chosen["rationale"] if chosen else role_reason)}
    out["analysis"]["constructInventory"] = [{"construct": k, "count": v, "heavy": k in inv["heavy"]} for k, v in sorted(inv["constructs"].items())]
    out["analysis"]["dependencies"] = [{"object": r, "kind": "reads_writes"} for r in refs["reads_writes"]] + \
                                      [{"object": r, "kind": "temp"} for r in refs["temp"]] + [{"object": r, "kind": "unresolved"} for r in refs["unresolved"]]
    out["analysis"]["securityFindings"] = sec
    questions = open_questions(obj_type, consumer, role, sec, inv, chosen["target"] if chosen else None)
    out["analysis"]["manualReviewItems"] = questions
    out["analysis"]["warnings"] = [f"{c['target']}: {b}" for c in cands for b in c["blockers"]]
    out["assessment"] = {"objectType": obj_type, "objectsDefined": refs["defines"], "consumer": consumer, "referencedBy": referenced_by,
                         "updatable": updatable, "roleReason": role_reason, "complexityFactors": {"heavy": inv["heavy"], "statements": inv["statements"],
                         "lines": inv["lines"], "joins": inv["joins"], "security": inv["security"]}, "targetCandidates": cands,
                         "recommendedSkill": chosen["skill"] if chosen else None, "toolVersion": TOOL_VERSION}
    if not chosen:
        contract.set_status(out, "BLOCKED", "TARGET_DECISION_REQUIRED")
    elif chosen["blockers"]:
        contract.set_status(out, "PARTIAL", "UNSUPPORTED_CONSTRUCT")
    if sec and not security_rules:
        contract.set_status(out, "BLOCKED", "SECURITY_MAPPING_REQUIRED")
    if refs["unresolved"]:
        contract.set_status(out, "PARTIAL", "DEPENDENCY_UNRESOLVED")
    if chosen and chosen["feasible"]:
        out["validation"] = contract.validation_manifest(["V-001", "V-002", "V-003"] + (["V-026", "V-027"] if sec else []),
                                                         executed={"V-002": {"status": "PASS", "evidence": f"sha256 {sha256_bytes(sql.encode('utf-8'))[:16]}…"}})
    return out


def report_md(out: dict, name: str) -> str:
    a, c, asm = out["analysis"], out["classification"], out["assessment"]
    lines = [f"# Assessment: {name}", "", f"- Status: **{out['status']}** {', '.join(a['stopCodes']) if a['stopCodes'] else ''}",
             f"- Object type: {asm['objectType']} · defines: {', '.join(asm['objectsDefined']) or '—'}",
             f"- Role (M2RVE): **{c['role']}** — {asm['roleReason']}",
             f"- Complexity: **{c['complexity']}** · review tier: **{c['reviewTier']}** · heavy constructs: {', '.join(asm['complexityFactors']['heavy']) or 'none'}",
             f"- Target decision: **{c['targetDecision'] or 'undecided'}** → skill `{asm['recommendedSkill'] or '—'}`", "",
             "## Target candidates", "", "| Target | Skill | Feasible | Rationale / blockers |", "|---|---|---|---|"]
    for t in asm["targetCandidates"]:
        lines.append(f"| {t['target']} | `{t['skill']}` | {'yes' if t['feasible'] else 'no'} | {t['rationale']}{('; **blocked:** ' + '; '.join(t['blockers'])) if t['blockers'] else ''} |")
    lines += ["", "## Dependencies", ""] + [f"- {d['object']} ({d['kind']})" for d in a["dependencies"]] or ["- none"]
    if a["securityFindings"]:
        lines += ["", "## Security-bearing constructs", ""] + [f"- line {s['line']}: {s['construct']} — {s['message']}" for s in a["securityFindings"]]
    lines += ["", "## Construct inventory", ""] + [f"- {i['construct']}: {i['count']}{' (heavy)' if i['heavy'] else ''}" for i in a["constructInventory"]]
    if a["manualReviewItems"]:
        lines += ["", "## Open questions (answer before converting)", ""] + [f"{n}. {q}" for n, q in enumerate(a["manualReviewItems"], 1)]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- commands
def cmd_assess(a):
    src = pathlib.Path(a.path)
    files = sorted(p for p in src.rglob("*.sql")) if src.is_dir() else [src]
    files = [f for f in files if f.is_file()]
    if not files:
        print(f"no .sql files under {src}", file=sys.stderr); return 2
    rules = contract.load_json(a.security_rules) if a.security_rules else None
    texts = {}
    for f in files:
        big = security.check_size(f)
        if big:
            print(f"REFUSED (security): {f} {big[0]['message']}", file=sys.stderr); return 3
        texts[f] = f.read_text(encoding="utf-8", errors="replace")
        sec = [x for x in security.scan_text(texts[f], "sql", str(f)) if x["rule"] in ("SEC-01", "SEC-02", "SEC-03")]
        if sec:
            print(f"SECURITY NOTICE {f}: " + "; ".join(f"{x['rule']} {x['name']} line {x['line']}" for x in sec[:5]) + " — treated as data, reported in the assessment")
    # dependency graph across the set: how many other objects reference each defined object
    defined = {}
    for f, t in texts.items():
        for d in ddl.references(t)["defines"]:
            defined[d.lower()] = f
    ref_count = {}
    for f, t in texts.items():
        for r in ddl.references(t)["reads_writes"]:
            if r.lower() in defined and defined[r.lower()] != f:
                ref_count[r.lower()] = ref_count.get(r.lower(), 0) + 1
    out_dir = pathlib.Path(a.out) if a.out else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
    worst = 0
    summary = []
    with LOG.span("assess", files=len(files), consumer=a.consumer, target=a.target):
        for f, t in texts.items():
            defs = ddl.references(t)["defines"]
            referenced_by = max([ref_count.get(d.lower(), 0) for d in defs] or [0])
            out = assess_text(t, f.stem, a.consumer, a.target, referenced_by, rules)
            out["assessment"]["sourceFile"] = str(f); out["assessment"]["sourceSha256"] = sha256_bytes(t.encode("utf-8"))
            sec_scan = [x for x in security.scan_text(t, "sql", str(f)) if x["rule"] in ("SEC-01", "SEC-02", "SEC-03", "SEC-05")]
            out["analysis"]["securityFindings"] += [{"kind": "scanner", "construct": x["name"], "line": x["line"], "message": f"{x['rule']}: {x['message']}"} for x in sec_scan]
            LOG.log("assess.object", "", file=str(f), object_type=out["assessment"]["objectType"], role=out["classification"]["role"],
                    complexity=out["classification"]["complexity"], tier=out["classification"]["reviewTier"], status=out["status"],
                    target=out["classification"]["targetDecision"], stop_codes=out["analysis"]["stopCodes"], sha256=out["assessment"]["sourceSha256"])
            c = out["classification"]
            summary.append((f.name, out["assessment"]["objectType"], c["role"], c["complexity"], c["reviewTier"], c["targetDecision"] or "—", out["status"], ",".join(out["analysis"]["stopCodes"])))
            if out_dir:
                (out_dir / f"{f.stem}.classification.json").write_text(contract.canonical_json(out), encoding="utf-8")
                (out_dir / f"{f.stem}.assessment.md").write_text(report_md(out, f.name), encoding="utf-8")
            worst = max(worst, {"GENERATED": 0, "VALIDATED": 0, "PARTIAL": 1, "BLOCKED": 1}[out["status"]])
            if a.json and not out_dir:
                print(contract.canonical_json(out))
    if not a.json:
        w = [max(len(str(r[i])) for r in summary + [("file", "type", "role", "cx", "tier", "target", "status", "stop codes")]) for i in range(8)]
        hdr = ("file", "type", "role", "cx", "tier", "target", "status", "stop codes")
        print("  ".join(h.ljust(w[i]) for i, h in enumerate(hdr)))
        for r in summary:
            print("  ".join(str(x).ljust(w[i]) for i, x in enumerate(r)))
        if out_dir:
            print(f"classification.json + assessment.md per object → {out_dir}")
    return 1 if worst else 0


def cmd_inventory(a):
    src = pathlib.Path(a.path)
    log = contract.load_json(a.log) if a.log and pathlib.Path(a.log).exists() else {"files": []}
    logged_files = {f.get("source_file") for f in log.get("files", [])}
    logged_objects = {}
    for f in log.get("files", []):
        for o in f.get("procedures", []) + f.get("objects", []):
            logged_objects[str(o.get("source_name", "")).lower()] = (f.get("source_file"), o)
    rows, problems = [], []
    for f in sorted(src.rglob("*.sql")):
        rel = f.relative_to(src.parent).as_posix() if src.parent in f.parents or src.parent == f.parent else str(f)
        t = f.read_text(encoding="utf-8", errors="replace")
        inv = ddl.inventory(t); defs = ddl.references(t)["defines"]
        in_log = rel in logged_files
        rows.append((rel, inv["object_type"], len(defs), complexity(inv), "logged" if in_log else "PENDING"))
        if not in_log and inv["object_type"] != "TABLE":
            problems.append(f"{rel}: not in the migration log (pending conversion)")
        for d in defs:
            short = d.split(".")[-1].lower()
            if in_log and short not in logged_objects and inv["object_type"] != "TABLE":
                problems.append(f"{rel}: object {d} has no entry in the migration log")
    # manual-review flags vs TODO markers in generated files
    gen = src.parent / "generated"
    for f, o in logged_objects.values():
        tgt = None
        for entry in log.get("files", []):
            if entry.get("source_file") == f:
                tgt = entry.get("target_file")
        if o.get("manual_review") and tgt and (src.parent / tgt).exists():
            if "MANUAL REVIEW REQUIRED" not in (src.parent / tgt).read_text(encoding="utf-8", errors="replace"):
                problems.append(f"{tgt}: {o.get('target_name')} is flagged manual_review but the file has no 'MANUAL REVIEW REQUIRED' marker")
    w = [max(len(str(r[i])) for r in rows + [("file", "type", "objects", "cx", "log")]) for i in range(5)]
    for r in [("file", "type", "objects", "cx", "log")] + rows:
        print("  ".join(str(x).ljust(w[i]) for i, x in enumerate(r)))
    for p in problems:
        print(f"AUDIT  {p}")
    LOG.log("assess.inventory", f"{len(rows)} file(s), {len(problems)} audit finding(s)", "WARN" if problems else "INFO", files=len(rows), findings=problems[:50])
    return 1 if problems else 0


def cmd_validate(a):
    req = contract.load_json(a.request)
    v = contract.validate_request(req)
    print(contract.canonical_json(v))
    LOG.log("assess.validate", "ok" if v["ok"] else "invalid", "INFO" if v["ok"] else "WARN", request=str(a.request), stop_codes=v["stop_codes"])
    return 0 if v["ok"] else 1


QUESTIONS = [
    ("source", "Which SQL Server objects are in scope (files under source/), and which SQL Server version and database do they come from?"),
    ("consumer", "Who consumes each object today: an application/API, BI or reporting, an ETL job, or nobody (candidate for elimination)?"),
    ("target", "Which target platform is approved: Aurora PostgreSQL (operational, procedural code), Amazon Redshift (analytics, BI edge views, set-based loads) or Apache Iceberg on S3 with Glue (data products, lake-first)? If undecided, run `assess` and review the candidates."),
    ("contract", "Must output column names and order be preserved for consumers (consumer contract)? Which naming profile applies on the target (default snake_case)?"),
    ("metadata", "Is authoritative table metadata available (live catalog through MCP, catalog export, or DDL under source/schema/)? Without it, table conversions stay PARTIAL."),
    ("security", "Does any object filter rows or columns by the caller's identity? If yes, which target identity mapping and reviewer approve the RLS/CLS policy?"),
    ("load", "For data-movement routines: full reload, append or merge? Business key, watermark, late-arrival rule, delete handling and restart behaviour?"),
    ("tests", "Which test database (name containing test/dev/sandbox/local) and which sample data profile may be used to prove the conversion?"),
    ("review", "Who reviews: data engineer only (T1), plus peer (T2), or plus architect and security (T3)? Any review-tier override?"),
]


def cmd_questions(a):
    print("Intake questions — ask the user before converting; write the answers into the request context.\n")
    for key, q in QUESTIONS:
        print(f"- [{key}] {q}")
    return 0


def main():
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("assess"); p.add_argument("path"); p.add_argument("--consumer", choices=CONSUMERS, default="unknown")
    p.add_argument("--target", choices=list(SKILL_FOR_TARGET)); p.add_argument("--security-rules"); p.add_argument("--out"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_assess)
    p = sub.add_parser("inventory"); p.add_argument("path"); p.add_argument("--log", default="metadata/migration_log.json"); p.set_defaults(fn=cmd_inventory)
    p = sub.add_parser("validate"); p.add_argument("request"); p.set_defaults(fn=cmd_validate)
    p = sub.add_parser("questions"); p.set_defaults(fn=cmd_questions)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
