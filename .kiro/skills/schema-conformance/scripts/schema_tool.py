#!/usr/bin/env python3
"""
schema_tool.py — schema gap analysis and conformance between a SQL Server source and a target
(Aurora PostgreSQL, Amazon Redshift, Apache Iceberg on Athena/Glue/Spark).

  snapshot <ddl.sql|dir> --dialect tsql|pgsql|redshift|spark --out snapshot.json
  snapshot --live --out snapshot.json [--schema public]          PostgreSQL information_schema (PG* env, test DB only)
  snapshot --glue --database DB --out snapshot.json               Glue Data Catalog (Iceberg tables)
  compare <source.json> <target.json> --profile aurora|redshift|iceberg [--naming snake_case|preserve]
          [--mapping mapping.json] [--ignore-columns _run_id,_loaded_at] --out DIR
  conform <compare.json> --out fixes.sql                          dry-run DDL proposals (never executed)
  refs <converted.sql|dir> --target snapshot.json [--json]        every referenced schema.object must exist
  package <compare.json> --out DIR [--classification FILE]

Exit codes: 0 conforms · 1 gaps or problems · 2 usage · 3 security refusal.
"""
import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
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
LOG = AuditLogger("schema_tool")
EXIT_SECURITY = 3
TEST_DB = re.compile(r"(test|dev|sandbox|local)", re.I)
DEFAULT_IGNORE = ["_run_id", "_loaded_at", "_source_hash", "_deleted"]
CLASSES = ("EXACT", "APPROVED_TRANSFORM", "MISSING_SOURCE", "MISSING_TARGET", "CONFLICT", "UNVERIFIED")


class SecurityRefusal(SystemExit):
    def __init__(self, message, findings=()):
        LOG.log("security.refused", message, "ERROR", findings=[{k: f.get(k) for k in ("rule", "name", "severity", "line")} for f in list(findings)[:50]])
        sys.stderr.write(f"REFUSED (security): {message}\n")
        super().__init__(EXIT_SECURITY)


def snake(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_]+", "_", name)
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", s)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", s)
    return re.sub(r"_+", "_", s).strip("_").lower()


# ---------------------------------------------------------------- type normalisation
ALIASES = {"int": "integer", "int4": "integer", "int8": "bigint", "int2": "smallint", "bool": "boolean", "character varying": "varchar",
           "character": "char", "bpchar": "char", "nvarchar": "nvarchar", "timestamp without time zone": "timestamp", "timestamp with time zone": "timestamptz",
           "time without time zone": "time", "time with time zone": "timetz", "double precision": "double", "float8": "double", "float4": "real",
           "numeric": "decimal", "dec": "decimal", "string": "string", "varbyte": "varbyte", "binary varying": "varbyte", "long": "bigint", "float": "float"}


def norm_type(dt: dict, dialect: str) -> dict:
    """{'base','length','precision','scale','raw'} normalised across dialects (base names in lower case)."""
    base = (dt.get("base") or "").lower().strip()
    base = ALIASES.get(base, base)
    ln, p, s = dt.get("length"), dt.get("precision"), dt.get("scale")
    if base == "float" and dialect in ("tsql", "pgsql", "redshift"):
        base = "real" if (p and p <= 24) else "double"; p = None
    if base == "float" and dialect == "spark":
        base = "float"
    if base == "timestamp" and dt.get("tz_suffix"):
        base = "timestamptz"
    if base in ("varchar", "nvarchar", "char", "nchar") and ln is None and dialect == "redshift" and base == "varchar":
        ln = 256
    if base in ("text", "ntext") and dialect == "tsql":
        base, ln = "varchar", "MAX"
    return {"base": base, "length": ln, "precision": p, "scale": s, "raw": dt.get("raw", "")}


def _col_from_ddl(c: dict, ordinal: int, dialect: str) -> dict:
    return {"name": c["name"], "ordinal": ordinal, "type": norm_type(c["datatype"], dialect), "nullable": bool(c["nullable"]), "default": c.get("default"),
            "identity": bool(c.get("identity")), "computed": c.get("computed"), "unverified": list(c.get("unresolved") or [])}


def snapshot_from_ddl(text: str, dialect: str, source: str = "") -> dict:
    tables = {}
    unverified = []
    for t in ddl.parse_tables(text, "postgres" if dialect == "pgsql" else dialect):
        schema = (t["schema"] or ("dbo" if dialect == "tsql" else "public")).lower()
        key = f"{schema}.{t['name'].lower()}"
        cols = [_col_from_ddl(c, i + 1, dialect) for i, c in enumerate(t["columns"])]
        pk = next((c["columns"] for c in t["constraints"] if c["type"] == "PRIMARY KEY"), [])
        uniques = [c["columns"] for c in t["constraints"] if c["type"] == "UNIQUE"] + [ix["columns"] for ix in t["indexes"] if ix.get("unique") and not ix.get("filter")]
        fks = [{"columns": c["columns"], "refTable": c["ref_table"], "refColumns": c["ref_columns"]} for c in t["constraints"] if c["type"] == "FOREIGN KEY"]
        checks = [c["expression"] for c in t["constraints"] if c["type"] == "CHECK"]
        tables[key] = {"schema": schema, "name": t["name"], "originalName": f"{t['schema'] or ''}.{t['name']}".strip("."), "columns": cols,
                       "primaryKey": list(pk), "unique": [list(u) for u in uniques], "foreignKeys": fks, "checks": checks,
                       "indexes": [{"name": ix["name"], "columns": ix["columns"], "unique": ix.get("unique", False), "filter": ix.get("filter")} for ix in t["indexes"]],
                       "partition": t.get("partition") or [], "distribution": t.get("distribution") or {}, "properties": t.get("properties") or {},
                       "unverified": list(t.get("unresolved") or [])}
        unverified += [f"{key}: {u}" for u in t.get("unresolved") or []]
    return _finish({"provenance": {"method": "ddl-parse", "source": source, "dialect": dialect, "sha256": sha256_bytes(text.encode("utf-8"))}, "tables": tables, "unverified": unverified})


def _finish(snap: dict) -> dict:
    snap["provenance"].update({"capturedAt": now_rfc3339(), "runId": LOG.run_id, "toolVersion": TOOL_VERSION})
    snap["hash"] = contract.sha256_text(contract.canonical_json(snap["tables"]))
    return snap


LIVE_SQL = r"""
SELECT json_agg(t ORDER BY t.table_schema, t.table_name) FROM (
  SELECT c.table_schema, c.table_name,
         json_agg(json_build_object('name', c.column_name, 'ordinal', c.ordinal_position, 'data_type', c.data_type,
                  'udt', c.udt_name, 'length', c.character_maximum_length, 'precision', c.numeric_precision, 'scale', c.numeric_scale,
                  'dt_precision', c.datetime_precision, 'nullable', c.is_nullable = 'YES', 'default', c.column_default,
                  'identity', c.is_identity = 'YES', 'generated', c.generation_expression) ORDER BY c.ordinal_position) AS columns,
         (SELECT json_agg(kc.column_name ORDER BY kc.ordinal_position) FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kc ON kc.constraint_name = tc.constraint_name AND kc.table_schema = tc.table_schema AND kc.table_name = tc.table_name
           WHERE tc.table_schema = c.table_schema AND tc.table_name = c.table_name AND tc.constraint_type = 'PRIMARY KEY') AS primary_key,
         (SELECT json_agg(u.cols) FROM (SELECT json_agg(kc.column_name ORDER BY kc.ordinal_position) AS cols FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kc ON kc.constraint_name = tc.constraint_name AND kc.table_schema = tc.table_schema AND kc.table_name = tc.table_name
           WHERE tc.table_schema = c.table_schema AND tc.table_name = c.table_name AND tc.constraint_type = 'UNIQUE' GROUP BY tc.constraint_name) u) AS uniques
  FROM information_schema.columns c
  JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name AND tb.table_type = 'BASE TABLE'
  WHERE c.table_schema = %s
  GROUP BY c.table_schema, c.table_name) t;
"""


def live_query(schema: str) -> str:
    if not re.fullmatch(r"[a-z_][a-z0-9_]*", schema):
        raise SystemExit("schema must be a lower-case identifier")
    return LIVE_SQL % f"'{schema}'"


def snapshot_from_live_rows(rows: list, database: str, host: str = "") -> dict:
    tables = {}
    for t in rows or []:
        key = f"{t['table_schema']}.{t['table_name']}".lower()
        cols = []
        for c in t["columns"]:
            base = ALIASES.get(c["data_type"].lower(), c["data_type"].lower())
            if base == "user-defined":
                base = ALIASES.get(c["udt"].lower(), c["udt"].lower())
            if base == "array":
                base = ALIASES.get(c["udt"].lstrip("_").lower(), c["udt"].lstrip("_").lower()) + "[]"
            ln = c["length"]; p = c["precision"] if base == "decimal" else None; s = c["scale"] if base == "decimal" else None
            if base in ("timestamp", "timestamptz", "time") and c.get("dt_precision") not in (None, 6):
                p = c["dt_precision"]
            cols.append({"name": c["name"], "ordinal": c["ordinal"], "type": {"base": base, "length": ln, "precision": p, "scale": s, "raw": c["data_type"]},
                         "nullable": bool(c["nullable"]), "default": c["default"], "identity": bool(c["identity"]), "computed": c.get("generated"), "unverified": []})
        tables[key] = {"schema": t["table_schema"], "name": t["table_name"], "originalName": key, "columns": cols, "primaryKey": list(t.get("primary_key") or []),
                       "unique": [list(u) for u in (t.get("uniques") or [])], "foreignKeys": [], "checks": [], "indexes": [], "partition": [], "distribution": {}, "properties": {}, "unverified": []}
    return _finish({"provenance": {"method": "live-information_schema", "source": f"postgresql://{host}/{database}", "dialect": "pgsql", "sha256": ""}, "tables": tables, "unverified": []})


def snapshot_live(schema: str) -> dict:
    db = os.environ.get("PGDATABASE", "")
    if not TEST_DB.search(db):
        raise SecurityRefusal(f"PGDATABASE '{db}' is not a test database (name must contain test/dev/sandbox/local)")
    if shutil.which("psql") is None:
        raise SystemExit("psql not found")
    env = dict(os.environ, PGCONNECT_TIMEOUT=os.environ.get("PGCONNECT_TIMEOUT", "15"), PGAPPNAME=f"schema_tool {LOG.run_id[:8]}")
    if os.environ.get("PG_IAM_AUTH") == "1":
        cmd = ["aws", "rds", "generate-db-auth-token", "--hostname", env["PGHOST"], "--port", env.get("PGPORT", "5432"), "--username", env["PGUSER"], "--region", env["AWS_REGION"]]
        tok = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if tok.returncode != 0:
            raise SystemExit("could not generate an IAM auth token (check AWS credentials)")
        env["PGPASSWORD"] = tok.stdout.strip(); env.setdefault("PGSSLMODE", "require")  # never logged
    r = subprocess.run(["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", "SET default_transaction_read_only = on;", "-c", live_query(schema)], capture_output=True, text=True, env=env, timeout=120)
    if r.returncode != 0:
        raise SystemExit(f"psql failed: {(r.stderr or '').strip().splitlines()[-1:] or ['unknown error']}")
    body = "\n".join(l for l in r.stdout.splitlines() if l.strip() not in ("SET", ""))  # json_agg output spans lines; drop command tags
    rows = json.loads(body or "null") or []
    LOG.log("schema.snapshot.live", f"{len(rows)} table(s)", database=db, host=env.get("PGHOST", ""), schema=schema)
    return snapshot_from_live_rows(rows, db, env.get("PGHOST", ""))


GLUE_TYPES = re.compile(r"^(\w+)(?:\((\d+)(?:,\s*(\d+))?\))?$")


def snapshot_from_glue(tables: list, database: str) -> dict:
    out = {}
    for t in tables:
        key = f"{database}.{t['Name']}".lower()
        cols = []
        for i, c in enumerate(t.get("StorageDescriptor", {}).get("Columns", []), 1):
            m = GLUE_TYPES.match(c["Type"].strip().lower())
            base = (m.group(1) if m else c["Type"].lower()); base = ALIASES.get(base, base)
            p = int(m.group(2)) if m and m.group(2) and base == "decimal" else None; s = int(m.group(3)) if m and m.group(3) else (0 if p else None)
            cols.append({"name": c["Name"], "ordinal": i, "type": {"base": base, "length": None, "precision": p, "scale": s, "raw": c["Type"]}, "nullable": True,
                         "default": None, "identity": False, "computed": None, "unverified": [] if m else [f"unknown Glue type {c['Type']}"]})
        out[key] = {"schema": database, "name": t["Name"], "originalName": key, "columns": cols, "primaryKey": [], "unique": [], "foreignKeys": [], "checks": [], "indexes": [],
                    "partition": [c["Name"] for c in t.get("PartitionKeys", [])], "distribution": {}, "properties": t.get("Parameters", {}), "unverified": []}
    return _finish({"provenance": {"method": "glue-catalog", "source": f"glue://{database}", "dialect": "spark", "sha256": ""}, "tables": out, "unverified": []})


def snapshot_glue(database: str) -> dict:
    from migkit.services import Services
    if not TEST_DB.search(database):
        raise SecurityRefusal(f"Glue database '{database}' is not a test database (name must contain test/dev/sandbox/local)")
    svc = Services(logger=LOG)
    tables, token = [], None
    while True:
        args = ["glue", "get-tables", "--database-name", database]
        if token:
            args += ["--next-token", token]
        r = svc.aws(*args)
        tables += r.get("TableList", []); token = r.get("NextToken")
        if not token:
            break
    LOG.log("schema.snapshot.glue", f"{len(tables)} table(s)", database=database)
    return snapshot_from_glue(tables, database)


# ---------------------------------------------------------------- comparison
PROFILES = {
    "aurora": {"integer": {"integer", "bigint"}, "bigint": {"bigint"}, "smallint": {"smallint", "integer"}, "tinyint": {"smallint", "integer"}, "bit": {"boolean"},
               "decimal": {"decimal"}, "money": {"decimal"}, "smallmoney": {"decimal"}, "double": {"double"}, "real": {"real", "double"},
               "char": {"char", "varchar", "text"}, "nchar": {"char", "varchar", "text"}, "varchar": {"varchar", "text", "citext"}, "nvarchar": {"varchar", "text", "citext"}, "sysname": {"varchar", "text"},
               "date": {"date"}, "time": {"time"}, "datetime": {"timestamp"}, "datetime2": {"timestamp"}, "smalldatetime": {"timestamp"}, "datetimeoffset": {"timestamptz"},
               "uniqueidentifier": {"uuid", "varchar", "char"}, "varbinary": {"bytea"}, "binary": {"bytea"}, "image": {"bytea"}, "rowversion": {"bytea", "bigint"}, "timestamp": {"bytea", "bigint"},
               "xml": {"xml", "text"}, "geography": {"geography", "geometry"}, "geometry": {"geometry"}, "hierarchyid": {"ltree", "text", "varchar"}, "sql_variant": {"jsonb", "text"}},
    "redshift": {"integer": {"integer", "bigint"}, "bigint": {"bigint"}, "smallint": {"smallint", "integer"}, "tinyint": {"smallint", "integer"}, "bit": {"boolean"},
                 "decimal": {"decimal"}, "money": {"decimal"}, "smallmoney": {"decimal"}, "double": {"double"}, "real": {"real", "double"},
                 "char": {"char", "varchar"}, "nchar": {"char", "varchar"}, "varchar": {"varchar"}, "nvarchar": {"varchar"}, "sysname": {"varchar"},
                 "date": {"date"}, "time": {"time"}, "datetime": {"timestamp"}, "datetime2": {"timestamp"}, "smalldatetime": {"timestamp"}, "datetimeoffset": {"timestamptz"},
                 "uniqueidentifier": {"varchar", "char"}, "varbinary": {"varbyte"}, "binary": {"varbyte"}, "image": {"varbyte"}, "rowversion": {"varbyte"}, "timestamp": {"varbyte"},
                 "xml": {"super", "varchar"}, "geography": {"geography", "geometry"}, "geometry": {"geometry"}, "hierarchyid": {"varchar"}, "sql_variant": {"super"}},
    "iceberg": {"integer": {"integer", "bigint"}, "bigint": {"bigint"}, "smallint": {"integer"}, "tinyint": {"integer"}, "bit": {"boolean"},
                "decimal": {"decimal"}, "money": {"decimal"}, "smallmoney": {"decimal"}, "double": {"double"}, "real": {"float", "double"},
                "char": {"string"}, "nchar": {"string"}, "varchar": {"string"}, "nvarchar": {"string"}, "sysname": {"string"},
                "date": {"date"}, "time": {"string"}, "datetime": {"timestamp"}, "datetime2": {"timestamp"}, "smalldatetime": {"timestamp"}, "datetimeoffset": {"timestamp", "timestamptz"},
                "uniqueidentifier": {"string"}, "varbinary": {"binary"}, "binary": {"binary"}, "image": {"binary"}, "rowversion": {"binary"}, "timestamp": {"binary"},
                "xml": {"string"}, "geography": {"binary", "string"}, "geometry": {"binary", "string"}, "hierarchyid": {"string"}, "sql_variant": {"string"}},
}
ENFORCING_KEYS = {"aurora": True, "redshift": False, "iceberg": False}
UNBOUNDED = {"text", "string", "citext", "super", "xml"}


def _norm_name(name: str, naming: str) -> str:
    return snake(name) if naming == "snake_case" else name.lower()


def _len_ok(src: dict, tgt: dict) -> tuple:
    """(ok, reason) for length/precision/scale."""
    sb, tb = src["base"], tgt["base"]
    if sb in ("varchar", "nvarchar", "char", "nchar", "sysname"):
        if tb in UNBOUNDED:
            return True, ""
        sl = 128 if sb == "sysname" else src["length"]
        tl = tgt["length"]
        if sl == "MAX":
            return (True, "") if (tl in (None, "MAX") or (isinstance(tl, int) and tl >= 65535)) else (False, f"source MAX, target length {tl}")
        if sl is None:
            sl = 1
        if tl is None:
            return (True, "") if tb == "varchar" and tgt.get("raw", "").lower() not in ("varchar",) else (True, "")
        if tl == "MAX":
            return True, ""
        return (tl >= sl, f"length {tl} < {sl}") if tl < sl else (True, "")
    if sb in ("decimal", "money", "smallmoney"):
        sp, ss = (19, 4) if sb == "money" else (10, 4) if sb == "smallmoney" else (src["precision"] or 18, src["scale"] or 0)
        tp, ts = tgt["precision"] or 18, tgt["scale"] if tgt["scale"] is not None else 0
        if tb != "decimal":
            return True, ""
        if ts != ss:
            return False, f"scale {ts} != {ss}"
        if tp < sp:
            return False, f"precision {tp} < {sp}"
        return True, ""
    if sb == "bigint" and tb in ("integer", "smallint"):
        return False, "narrowing bigint → " + tb
    if sb == "integer" and tb == "smallint":
        return False, "narrowing integer → smallint"
    return True, ""


def classify_column(src: dict | None, tgt: dict | None, profile: str, ignore: set, naming: str = "snake_case", mapped: bool = False) -> dict:
    """→ {classification, reason, warnings}"""
    if src is None:
        if tgt["name"].lower() in ignore:
            return {"classification": "APPROVED_TRANSFORM", "reason": "technical column added by the load", "warnings": []}
        return {"classification": "MISSING_SOURCE", "reason": "target column has no source column", "warnings": []}
    if tgt is None:
        return {"classification": "MISSING_TARGET", "reason": "source column missing from the target", "warnings": []}
    if src["unverified"] or tgt["unverified"]:
        return {"classification": "UNVERIFIED", "reason": "; ".join(src["unverified"] + tgt["unverified"]), "warnings": []}
    st, tt = src["type"], tgt["type"]
    warnings, notes = [], []
    if not src["nullable"] and tgt["nullable"]:
        warnings.append("nullability relaxed (NOT NULL → NULL)")
    if src["nullable"] and not tgt["nullable"]:
        return {"classification": "CONFLICT", "reason": "nullability tightened (NULL → NOT NULL)", "warnings": warnings}
    allowed = PROFILES[profile].get(st["base"])
    same_base = st["base"] == tt["base"]
    ints = {"smallint": 1, "integer": 2, "bigint": 3}
    if st["base"] in ints and tt["base"] in ints and ints[tt["base"]] < ints[st["base"]]:
        return {"classification": "CONFLICT", "reason": f"narrowing {st['base']} → {tt['base']}", "warnings": warnings}
    if src["computed"] and st["base"] in ("", "computed"):  # computed column without a declared type: the expression defines it
        note = "computed column kept" if tgt["computed"] else "computed column materialised by the load"
        return {"classification": "APPROVED_TRANSFORM", "reason": note + (f" ({tt['raw']})" if tt["raw"] else ""), "warnings": warnings}
    if allowed is None and not same_base:
        return {"classification": "UNVERIFIED", "reason": f"no allowlist entry for source type {st['raw']}", "warnings": warnings}
    if not same_base and tt["base"] not in allowed:
        return {"classification": "CONFLICT", "reason": f"type {tt['raw']} not approved for {st['raw']} on {profile} (allowed: {', '.join(sorted(allowed))})", "warnings": warnings}
    ok, why = _len_ok(st, tt)
    if not ok:
        return {"classification": "CONFLICT", "reason": f"narrowing: {why}", "warnings": warnings}
    if src["identity"] != tgt["identity"]:
        notes.append("identity " + ("dropped: key generated by the load" if src["identity"] else "added"))
    if (src["default"] is None) != (tgt["default"] is None):
        notes.append("default " + ("dropped: applied by the load" if src["default"] is not None else "added"))
    if bool(src["computed"]) != bool(tgt["computed"]):
        notes.append("computed column " + ("materialised by the load" if src["computed"] else "added"))
    exact = same_base and (st["length"] == tt["length"] or (st["length"] in (None, 1) and tt["length"] in (None, 1))) and (st["precision"] or None) == (tt["precision"] or None) \
        and (st["scale"] or 0) == (tt["scale"] or 0) and src["nullable"] == tgt["nullable"] and not notes and (_norm_name(src["name"], naming) == tgt["name"].lower() and not mapped)
    if exact:
        return {"classification": "EXACT", "reason": "", "warnings": warnings}
    reason = []
    if mapped or _norm_name(src["name"], naming) != tgt["name"].lower():
        reason.append(f"renamed {src['name']} → {tgt['name']} (explicit mapping)")
    if not same_base or st["length"] != tt["length"] or (st["precision"] or None) != (tt["precision"] or None):
        reason.append(f"type {st['raw']} → {tt['raw']}")
    reason += notes + warnings
    return {"classification": "APPROVED_TRANSFORM", "reason": "; ".join(reason) or "approved", "warnings": warnings}


def compare(source: dict, target: dict, profile: str = "aurora", naming: str = "snake_case", mapping: dict | None = None, ignore=None) -> dict:
    mapping = mapping or {}
    tmap = {k.lower(): v.lower() for k, v in mapping.get("tables", {}).items()}
    cmap = {k.lower(): {a.lower(): b.lower() for a, b in v.items()} for k, v in mapping.get("columns", {}).items()}
    ignore = set(x.lower() for x in (ignore if ignore is not None else DEFAULT_IGNORE))
    default_schema = {"aurora": "public", "redshift": "public", "iceberg": None}[profile]
    tgt_index = {}
    for key, t in target["tables"].items():
        tgt_index[key] = t; tgt_index.setdefault(t["name"].lower(), t)
    result = {"profile": profile, "naming": naming, "mapping": mapping, "ignoreColumns": sorted(ignore), "tables": {}, "summary": {c: 0 for c in CLASSES},
              "tableSummary": {"matched": 0, "MISSING_TARGET": 0, "MISSING_SOURCE": 0}, "orderDifferences": [], "keyFindings": [], "unverified": list(source.get("unverified", [])) + list(target.get("unverified", []))}
    matched_targets = set()
    for skey, st in sorted(source["tables"].items()):
        tname = tmap.get(skey) or tmap.get(st["name"]) or _norm_name(st["name"], naming)
        tkey = tname if "." in tname else None
        tt = tgt_index.get(tkey) if tkey else None
        if tt is None:
            cands = [t for k, t in target["tables"].items() if t["name"].lower() == tname.split(".")[-1].lower()]
            tt = cands[0] if len(cands) == 1 else None
        if tt is None:
            result["tables"][skey] = {"target": None, "classification": "MISSING_TARGET", "columns": []}
            result["tableSummary"]["MISSING_TARGET"] += 1
            for c in st["columns"]:
                result["summary"]["MISSING_TARGET"] += 1
            continue
        tkey = f"{tt['schema']}.{tt['name'].lower()}"
        matched_targets.add(tkey); result["tableSummary"]["matched"] += 1
        colmap = cmap.get(skey, {}) | cmap.get(st["name"], {})
        tcols = {c["name"].lower(): c for c in tt["columns"]}
        rows, used = [], set()
        for sc in st["columns"]:
            mapped = sc["name"].lower() in colmap
            want = colmap.get(sc["name"].lower()) or _norm_name(sc["name"], naming)
            tc = tcols.get(want)
            r = classify_column(sc, tc, profile, ignore, naming, mapped)
            rows.append({"source": sc["name"], "target": tc["name"] if tc else None, "sourceType": sc["type"]["raw"], "targetType": tc["type"]["raw"] if tc else None,
                         "sourceNullable": sc["nullable"], "targetNullable": tc["nullable"] if tc else None, **r})
            if tc:
                used.add(tc["name"].lower())
            result["summary"][r["classification"]] += 1
        for tc in tt["columns"]:
            if tc["name"].lower() not in used:
                r = classify_column(None, tc, profile, ignore, naming)
                rows.append({"source": None, "target": tc["name"], "sourceType": None, "targetType": tc["type"]["raw"], "sourceNullable": None, "targetNullable": tc["nullable"], **r})
                result["summary"][r["classification"]] += 1
        # keys
        spk = [colmap.get(x.lower(), _norm_name(x, naming)) for x in st["primaryKey"]]; tpk = [x.lower() for x in tt["primaryKey"]]
        key_class = None
        if spk and spk != tpk:
            key_class = "CONFLICT" if ENFORCING_KEYS[profile] else "APPROVED_TRANSFORM"
            result["keyFindings"].append({"table": skey, "classification": key_class, "reason": f"primary key {spk} vs target {tpk or 'none'}" + ("" if ENFORCING_KEYS[profile] else " (informational on this target; uniqueness validated by V-014)")})
        sun = sorted(tuple(colmap.get(x.lower(), _norm_name(x, naming)) for x in u) for u in st["unique"]); tun = sorted(tuple(x.lower() for x in u) for u in tt["unique"])
        for u in sun:
            if u not in tun:
                kc = "CONFLICT" if ENFORCING_KEYS[profile] else "APPROVED_TRANSFORM"
                result["keyFindings"].append({"table": skey, "classification": kc, "reason": f"unique {list(u)} missing on target" + ("" if ENFORCING_KEYS[profile] else " (validated by V-014)")})
        # order (consumer contract V-005)
        s_order = [r["target"] for r in rows if r["source"] and r["target"]]
        t_order = [c["name"] for c in tt["columns"] if c["name"] in s_order]
        if s_order != t_order:
            result["orderDifferences"].append({"table": skey, "source": s_order, "target": t_order})
        classes = {r["classification"] for r in rows} | {k["classification"] for k in result["keyFindings"] if k["table"] == skey}
        tclass = "CONFLICT" if "CONFLICT" in classes else "MISSING_TARGET" if "MISSING_TARGET" in classes else "UNVERIFIED" if "UNVERIFIED" in classes else "MISSING_SOURCE" if "MISSING_SOURCE" in classes else "APPROVED_TRANSFORM" if "APPROVED_TRANSFORM" in classes else "EXACT"
        result["tables"][skey] = {"target": tkey, "classification": tclass, "columns": rows, "unverified": st.get("unverified", []) + tt.get("unverified", [])}
        if st.get("unverified") or tt.get("unverified"):
            result["summary"]["UNVERIFIED"] += 1
    for tkey, tt in sorted(target["tables"].items()):
        if tkey not in matched_targets:
            result["tables"][f"→ {tkey}"] = {"target": tkey, "classification": "MISSING_SOURCE", "columns": []}
            result["tableSummary"]["MISSING_SOURCE"] += 1
    keyc = {k["classification"] for k in result["keyFindings"]}
    if result["summary"]["CONFLICT"] or "CONFLICT" in keyc:
        status, codes = "BLOCKED", ["TARGET_SCHEMA_DECISION_REQUIRED"]
    elif result["summary"]["MISSING_TARGET"] or result["tableSummary"]["MISSING_TARGET"]:
        status, codes = "PARTIAL", ["STATIC_VALIDATION_FAILED"]
    elif result["summary"]["UNVERIFIED"]:
        status, codes = "PARTIAL", ["METADATA_AMBIGUOUS"]
    else:
        status, codes = ("VALIDATED" if target["provenance"]["method"] != "ddl-parse" else "GENERATED"), []
    result["status"] = status; result["stopCodes"] = codes
    result["sourceSnapshot"] = {"hash": source["hash"], **source["provenance"]}; result["targetSnapshot"] = {"hash": target["hash"], **target["provenance"]}
    return result


def report_md(cmp: dict) -> str:
    s = cmp["summary"]; t = cmp["tableSummary"]
    lines = [f"# Schema conformance report — profile `{cmp['profile']}`, naming `{cmp['naming']}`", "",
             f"**Status: {cmp['status']}**" + (f" (stop codes: {', '.join(cmp['stopCodes'])})" if cmp["stopCodes"] else ""), "",
             f"Source snapshot `{cmp['sourceSnapshot']['hash'][:12]}` ({cmp['sourceSnapshot']['method']}, {cmp['sourceSnapshot']['source']}) · "
             f"target snapshot `{cmp['targetSnapshot']['hash'][:12]}` ({cmp['targetSnapshot']['method']}, {cmp['targetSnapshot']['source']})", "",
             "| Columns | EXACT | APPROVED_TRANSFORM | MISSING_TARGET | MISSING_SOURCE | CONFLICT | UNVERIFIED |", "|---|---|---|---|---|---|---|",
             f"| count | {s['EXACT']} | {s['APPROVED_TRANSFORM']} | {s['MISSING_TARGET']} | {s['MISSING_SOURCE']} | {s['CONFLICT']} | {s['UNVERIFIED']} |", "",
             f"Tables: {t['matched']} matched, {t['MISSING_TARGET']} missing in target, {t['MISSING_SOURCE']} only in target.", ""]
    for skey, tb in cmp["tables"].items():
        lines.append(f"## {skey} → {tb['target'] or '—'}  ({tb['classification']})")
        if tb["columns"]:
            lines += ["", "| Source | Target | Source type | Target type | Class | Reason |", "|---|---|---|---|---|---|"]
            for r in tb["columns"]:
                if r["classification"] != "EXACT":
                    lines.append(f"| {r['source'] or '—'} | {r['target'] or '—'} | {r['sourceType'] or ''} | {r['targetType'] or ''} | {r['classification']} | {r['reason']} |")
            if all(r["classification"] == "EXACT" for r in tb["columns"]):
                lines.append("| *all columns* | | | | EXACT | |")
        lines.append("")
    if cmp["keyFindings"]:
        lines += ["## Keys", ""] + [f"- **{k['classification']}** {k['table']}: {k['reason']}" for k in cmp["keyFindings"]] + [""]
    if cmp["orderDifferences"]:
        lines += ["## Column order (consumer contract V-005)", ""] + [f"- {o['table']}: source order {o['source']} vs target {o['target']}" for o in cmp["orderDifferences"]] + [""]
    if cmp["unverified"]:
        lines += ["## Unverified", ""] + [f"- {u}" for u in cmp["unverified"]] + [""]
    return "\n".join(lines)


# ---------------------------------------------------------------- conformance proposals
def _pg_type(src_type: dict, profile: str) -> str:
    b = src_type["base"]; ln = src_type["length"]; p, s = src_type["precision"], src_type["scale"]
    if profile == "iceberg":
        return {"integer": "int", "bigint": "bigint", "smallint": "int", "tinyint": "int", "bit": "boolean", "decimal": f"decimal({p or 18},{s or 0})", "money": "decimal(19,4)", "smallmoney": "decimal(10,4)",
                "double": "double", "real": "float", "date": "date", "time": "string", "datetime": "timestamp", "datetime2": "timestamp", "smalldatetime": "timestamp", "datetimeoffset": "timestamp",
                "uniqueidentifier": "string", "varbinary": "binary", "binary": "binary", "image": "binary", "rowversion": "binary", "xml": "string", "geography": "binary"}.get(b, "string")
    text_t = "text" if profile == "aurora" else "varchar(65535)"
    m = {"integer": "integer", "bigint": "bigint", "smallint": "smallint", "tinyint": "smallint", "bit": "boolean", "decimal": f"numeric({p or 18},{s or 0})" if profile == "aurora" else f"decimal({p or 18},{s or 0})",
         "money": "numeric(19,4)" if profile == "aurora" else "decimal(19,4)", "smallmoney": "numeric(10,4)" if profile == "aurora" else "decimal(10,4)", "double": "double precision", "real": "real",
         "date": "date", "time": "time", "datetime": "timestamp", "datetime2": "timestamp", "smalldatetime": "timestamp", "datetimeoffset": "timestamptz",
         "uniqueidentifier": "uuid" if profile == "aurora" else "varchar(36)", "varbinary": "bytea" if profile == "aurora" else "varbyte", "binary": "bytea" if profile == "aurora" else "varbyte",
         "image": "bytea" if profile == "aurora" else "varbyte(16777216)", "xml": "xml" if profile == "aurora" else "super", "geography": "geography"}
    if b in ("varchar", "nvarchar", "char", "nchar", "sysname"):
        if ln == "MAX":
            return text_t
        return f"{'char' if b in ('char', 'nchar') else 'varchar'}({128 if b == 'sysname' else ln or 1})"
    return m.get(b, text_t)


def conform_sql(cmp: dict, source: dict) -> str:
    profile = cmp["profile"]
    out = [f"-- Conformance proposals (DRY RUN — review, then apply through the normal deployment path) — profile {profile}",
           f"-- Generated by schema_tool.py conform v{TOOL_VERSION} on {now_rfc3339()} (run {LOG.run_id[:8]})", ""]
    for skey, tb in cmp["tables"].items():
        if tb["classification"] == "MISSING_SOURCE" or not tb["target"]:
            if tb["classification"] == "MISSING_TARGET":
                out.append(f"-- DECISION: table {skey} has no target table — convert its DDL (sql-conversion / redshift / iceberg skill)")
            continue
        st = source["tables"].get(skey, {"columns": []}); scols = {c["name"]: c for c in st["columns"]}
        tgt = tb["target"]
        for r in tb["columns"]:
            if r["classification"] == "MISSING_TARGET" and scols[r["source"]]["computed"]:
                out.append(f"-- DECISION: {tgt}.{snake(r['source'])} — computed column {r['source']} AS {scols[r['source']]['computed']}: GENERATED ALWAYS AS (…) STORED (Aurora) or materialised by the load")
            elif r["classification"] == "MISSING_TARGET":
                sc = scols[r["source"]]; ty = _pg_type(sc["type"], profile)
                nn = "" if sc["nullable"] or profile == "iceberg" else " NOT NULL"
                if profile == "iceberg":
                    out.append(f"ALTER TABLE {tgt} ADD COLUMNS ({snake(r['source'])} {ty});  -- MISSING_TARGET {r['source']} {r['sourceType']}")
                else:
                    out.append(f"ALTER TABLE {tgt} ADD COLUMN {snake(r['source'])} {ty}{nn};  -- MISSING_TARGET {r['source']} {r['sourceType']}")
            elif r["classification"] == "CONFLICT" and r["reason"].startswith("narrowing") and profile != "iceberg":
                sc = scols[r["source"]]; ty = _pg_type(sc["type"], profile)
                out.append(f"ALTER TABLE {tgt} ALTER COLUMN {r['target']} TYPE {ty};  -- CONFLICT {r['reason']}")
            elif r["classification"] == "CONFLICT":
                out.append(f"-- DECISION: {tgt}.{r['target']} — {r['reason']}")
            elif r["classification"] == "MISSING_SOURCE":
                out.append(f"-- DECISION: {tgt}.{r['target']} has no source column ({r['targetType']}): keep (document) or drop")
            elif r["classification"] == "UNVERIFIED":
                out.append(f"-- DECISION: {tgt}.{r['target'] or r['source']} unverified — {r['reason']}")
    for k in cmp["keyFindings"]:
        out.append(f"-- {'DECISION' if k['classification'] == 'CONFLICT' else 'NOTE'}: {k['table']} {k['reason']}")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- references
SQL_VALUE_KEYWORDS = {"current_date", "current_timestamp", "localtimestamp", "localtime", "current_time", "now", "current_user", "session_user", "user", "excluded", "new", "old", "inserted", "deleted"}


def _local_names(text: str) -> set:
    """Names that look like objects to the T-SQL reference scanner but are PL/pgSQL variables, parameters, CTEs or temp tables."""
    names = set()
    for sig in re.findall(r"(?is)\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+[\w.\"]+\s*\((.*?)\)\s*(?:RETURNS|LANGUAGE|AS\b|$)", text):
        for part in sig.split(","):
            words = [w for w in re.findall(r"[A-Za-z_]\w*", part) if w.upper() not in ("IN", "OUT", "INOUT", "VARIADIC")]
            if words:
                names.add(words[0].lower())
    for block in re.findall(r"(?is)\bDECLARE\b(.*?)\bBEGIN\b", text):
        names |= {m.lower() for m in re.findall(r"(?m)^\s*([A-Za-z_]\w*)\s+(?!CURSOR\b)[A-Za-z_]", block)}
    names |= {m.lower() for m in re.findall(r"(?i)\b(?:WITH\s+(?:RECURSIVE\s+)?|,\s*)([A-Za-z_]\w*)\s*(?:\([^)]*\))?\s+AS\s*\(", text)}
    names |= {m.lower().split(".")[-1] for m in re.findall(r"(?i)\bCREATE\s+(?:GLOBAL\s+|LOCAL\s+)?TEMP(?:ORARY)?\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.]+)", text)}
    names |= {m.lower() for m in re.findall(r"(?i)\bINTO\s+(?:STRICT\s+)?([A-Za-z_]\w*)\s*[,;]", text)}
    return names


def check_refs(text: str, target: dict, default_schema: str = "public") -> list:
    refs = ddl.references(text)
    known = set(target["tables"]) | {t["name"].lower() for t in target["tables"].values()}
    schemas = {t["schema"].lower() for t in target["tables"].values()} | {"public", "dbo", default_schema.lower()}
    local = _local_names(text) | {x.lower() for x in refs.get("defines", [])} | {x.lower().lstrip("#") for x in refs.get("temp", [])} | SQL_VALUE_KEYWORDS
    missing = []
    for r in refs.get("reads_writes", []):
        n = r.lower().replace('"', "")
        parts = n.split(".")
        if len(parts) > 2 or parts[-1] in local or parts[-1].startswith(("pg_", "svv_", "stl_", "stv_")) or parts[0] in ("information_schema", "pg_catalog", "pg_temp"):
            continue
        if len(parts) == 2 and parts[0] not in schemas:
            continue  # alias.column, not schema.table
        schema = default_schema.lower() if len(parts) == 1 or parts[0] == "dbo" else parts[0]
        cand = f"{schema}.{parts[-1]}"
        if cand in known or (len(parts) == 1 and parts[0] in known):
            continue
        missing.append(cand)
    return sorted(set(missing))


# ---------------------------------------------------------------- commands
def _read(p):
    path = pathlib.Path(p)
    big = security.check_size(path)
    if big:
        raise SecurityRefusal(f"{path} is too large", big)
    return path.read_text(encoding="utf-8-sig", errors="replace")


def _collect(path) -> str:
    p = pathlib.Path(path)
    if p.is_dir():
        return "\n".join(_read(f) for f in sorted(p.rglob("*.sql")))
    return _read(p)


def cmd_snapshot(a):
    with LOG.span("schema.snapshot", source=str(a.path or ("live" if a.live else "glue")), dialect=a.dialect) as o:
        if a.live:
            snap = snapshot_live(a.schema)
        elif a.glue:
            if not a.database:
                raise SystemExit("--glue needs --database")
            snap = snapshot_glue(a.database)
        else:
            if not a.path or not a.dialect:
                raise SystemExit("snapshot <path> --dialect tsql|pgsql|redshift|spark, or --live / --glue")
            text = _collect(a.path)
            findings = [x for x in security.scan_text(text, "sql", str(a.path)) if x["rule"] in ("SEC-01", "SEC-02", "SEC-03")]
            if findings:
                raise SecurityRefusal(f"{a.path} failed the input scan", findings)
            snap = snapshot_from_ddl(text, a.dialect, str(a.path))
        o.update(tables=len(snap["tables"]), hash=snap["hash"])
    pathlib.Path(a.out).write_text(contract.canonical_json(snap), encoding="utf-8")
    print(f"snapshot → {a.out}: {len(snap['tables'])} table(s), hash {snap['hash'][:12]}, {len(snap['unverified'])} unverified item(s)")
    return 0 if not snap["unverified"] else 1


def cmd_compare(a):
    src, tgt = contract.load_json(a.source), contract.load_json(a.target)
    mapping = contract.load_json(a.mapping) if a.mapping else None
    ignore = [x for x in a.ignore_columns.split(",") if x] if a.ignore_columns is not None else None
    with LOG.span("schema.compare", profile=a.profile, naming=a.naming) as o:
        cmp = compare(src, tgt, a.profile, a.naming, mapping, ignore)
        o.update(status=cmp["status"], **{k.lower(): v for k, v in cmp["summary"].items()})
    od = pathlib.Path(a.out); od.mkdir(parents=True, exist_ok=True)
    (od / "compare.json").write_text(contract.canonical_json(cmp), encoding="utf-8")
    (od / "compare.md").write_text(report_md(cmp), encoding="utf-8")
    s = cmp["summary"]
    print(f"compare → {od}: {cmp['status']} — EXACT {s['EXACT']}, APPROVED {s['APPROVED_TRANSFORM']}, MISSING_TARGET {s['MISSING_TARGET']}, MISSING_SOURCE {s['MISSING_SOURCE']}, CONFLICT {s['CONFLICT']}, UNVERIFIED {s['UNVERIFIED']}")
    for k in cmp["keyFindings"]:
        print(f"  {k['classification']:<18} {k['table']}: {k['reason']}")
    LOG.log("schema.compare.done", cmp["status"], "WARN" if cmp["status"] != "GENERATED" else "INFO", stop_codes=cmp["stopCodes"], summary=cmp["summary"])
    return 0 if cmp["status"] in ("GENERATED", "VALIDATED") else 1


def cmd_conform(a):
    cmp = contract.load_json(a.compare)
    src = contract.load_json(a.source) if a.source else {"tables": {}}
    if not a.source:
        src_path = pathlib.Path(cmp["sourceSnapshot"].get("snapshotFile", "")) if cmp["sourceSnapshot"].get("snapshotFile") else None
        if src_path and src_path.exists():
            src = contract.load_json(src_path)
    sql = conform_sql(cmp, src)
    pathlib.Path(a.out).write_text(sql, encoding="utf-8", newline="\n")
    n = sum(1 for l in sql.splitlines() if l.startswith("ALTER"))
    print(f"conform → {a.out}: {n} proposal(s) (dry run, not executed)")
    LOG.log("schema.conform", f"{n} proposal(s)", out=str(a.out))
    return 0


def cmd_refs(a):
    tgt = contract.load_json(a.target)
    text = _collect(a.path)
    with LOG.span("schema.refs", path=str(a.path)) as o:
        missing = check_refs(text, tgt, a.default_schema)
        o.update(missing=len(missing))
    if a.json:
        print(contract.canonical_json({"missing": missing, "stopCodes": ["DEPENDENCY_UNRESOLVED"] if missing else []}))
    else:
        for m in missing:
            print(f"FAIL  unresolved reference {m}")
        print(f"refs: {len(missing)} unresolved reference(s)")
    return 1 if missing else 0


def cmd_package(a):
    cmp = contract.load_json(a.compare)
    req = contract.new_request(a.request_id or "schema-conformance", "SQLServer", "schema", cmp["sourceSnapshot"].get("source", "schema"), "", {"aurora": "AuroraPostgreSQL", "redshift": "Redshift", "iceberg": "Iceberg"}[cmp["profile"]])
    out = contract.new_output(req["requestId"])
    if a.classification and pathlib.Path(a.classification).exists():
        out["classification"] = contract.load_json(a.classification).get("classification", out["classification"])
    out["analysis"]["warnings"] = [f"{t}: order differs (V-005)" for t in (o["table"] for o in cmp["orderDifferences"])]
    out["analysis"]["manualReviewItems"] = [f"{k['table']}: {k['reason']}" for k in cmp["keyFindings"] if k["classification"] == "CONFLICT"] + \
        [f"{t}.{r['source'] or r['target']}: {r['classification']} — {r['reason']}" for t, tb in cmp["tables"].items() for r in tb["columns"] if r["classification"] in ("CONFLICT", "MISSING_TARGET", "UNVERIFIED")]
    out["analysis"]["datatypeMappings"] = [{"table": t, "source": r["sourceType"], "target": r["targetType"], "classification": r["classification"]} for t, tb in cmp["tables"].items() for r in tb["columns"] if r["source"] and r["target"] and r["sourceType"] != r["targetType"]]
    if cmp["status"] == "BLOCKED":
        contract.set_status(out, "BLOCKED", *cmp["stopCodes"])
    elif cmp["status"] == "PARTIAL":
        contract.set_status(out, "PARTIAL", *cmp["stopCodes"])
    elif cmp["status"] == "VALIDATED":
        out["status"] = "VALIDATED"
    executed = {"V-001": {"status": "PASS", "evidence": "snapshots present"}, "V-002": {"status": "PASS", "evidence": f"source {cmp['sourceSnapshot']['hash'][:12]} target {cmp['targetSnapshot']['hash'][:12]}"},
                "V-006": {"status": "FAIL" if cmp["summary"]["CONFLICT"] else "PASS", "evidence": f"{cmp['summary']['CONFLICT']} type conflict(s)"},
                "V-007": {"status": "PASS" if not any('tightened' in r["reason"] for tb in cmp["tables"].values() for r in tb["columns"]) else "FAIL", "evidence": "nullability compared"},
                "V-005": {"status": "PASS" if not cmp["orderDifferences"] else "FAIL", "evidence": f"{len(cmp['orderDifferences'])} order difference(s)"},
                "V-009": {"status": "PASS" if not any(k["classification"] == "CONFLICT" for k in cmp["keyFindings"]) else "FAIL", "evidence": f"{len(cmp['keyFindings'])} key finding(s)"}}
    out["validation"] = contract.validation_manifest(["V-001", "V-002", "V-005", "V-006", "V-007", "V-008", "V-009", "V-010", "V-035", "V-036"], executed)
    files = {"compare.json": contract.canonical_json(cmp), "compare.md": report_md(cmp)}
    m = contract.write_package(a.out, req, out, files=files)
    print(f"package → {a.out} ({out['status']}, {len(m['files'])} files)")
    LOG.log("schema.package", out["status"], package=str(a.out), status=out["status"])
    return 0 if out["status"] in ("GENERATED", "VALIDATED") else 1


def main():
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("snapshot"); p.add_argument("path", nargs="?"); p.add_argument("--dialect", choices=["tsql", "pgsql", "redshift", "spark"]); p.add_argument("--live", action="store_true")
    p.add_argument("--glue", action="store_true"); p.add_argument("--database"); p.add_argument("--schema", default="public"); p.add_argument("--out", required=True); p.set_defaults(fn=cmd_snapshot)
    p = sub.add_parser("compare"); p.add_argument("source"); p.add_argument("target"); p.add_argument("--profile", choices=list(PROFILES), default="aurora")
    p.add_argument("--naming", choices=["snake_case", "preserve"], default="snake_case"); p.add_argument("--mapping"); p.add_argument("--ignore-columns"); p.add_argument("--out", required=True); p.set_defaults(fn=cmd_compare)
    p = sub.add_parser("conform"); p.add_argument("compare"); p.add_argument("--source"); p.add_argument("--out", required=True); p.set_defaults(fn=cmd_conform)
    p = sub.add_parser("refs"); p.add_argument("path"); p.add_argument("--target", required=True); p.add_argument("--default-schema", default="public"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_refs)
    p = sub.add_parser("package"); p.add_argument("compare"); p.add_argument("--out", required=True); p.add_argument("--classification"); p.add_argument("--request-id"); p.set_defaults(fn=cmd_package)
    a = ap.parse_args()
    with LOG.span(f"schema.{a.cmd}", argv=[str(x) for x in sys.argv[1:]], tool_version=TOOL_VERSION) as o:
        rc = a.fn(a)
        o.update(status="ok" if rc == 0 else "failed", exit_code=rc)
        return rc


if __name__ == "__main__":
    sys.exit(main())
