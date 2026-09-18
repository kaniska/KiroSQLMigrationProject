#!/usr/bin/env python3
"""
change_tool.py — governed table/column change propagation (rename, cast, add, drop) through a converted target flow.

  ingest <changes.csv|.xlsx> --out changes.json
  validate <changes.json> --snapshot target.snapshot.json --layers layers.json --policy policy.json [--json]
  plan <changes.json> --snapshot … --layers … --policy … [--profile profile.json] --flow DIR --out plan.json
  patch <plan.json> --flow DIR --out DIR                      dry-run patches + unified diff + residual scan (never applied)
  scan <plan.json> --flow DIR [--patched DIR] [--json]        residual old identifiers (editable scope) / protected diff
  package <plan.json> --patches DIR --out DIR [--classification FILE]

Exit codes: 0 ok · 1 gaps or blocked · 2 usage · 3 refused (security or production write).
"""
import argparse
import csv
import difflib
import fnmatch
import io
import json
import os
import pathlib
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

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
LOG = AuditLogger("change_tool")
EXIT_REFUSED = 3
CHANGE_TYPES = {"RENAME_TABLE": ("Current_Schema", "Current_Table", "New_Table"), "RENAME_COLUMN": ("Current_Schema", "Current_Table", "Current_Column", "New_Column"),
                "CAST_COLUMN": ("Current_Schema", "Current_Table", "Current_Column", "New_Datatype"), "ADD_COLUMN": ("Current_Schema", "Current_Table", "New_Column", "New_Datatype"),
                "DROP_COLUMN": ("Current_Schema", "Current_Table", "Current_Column")}
HEADERS = ["Change_Type", "Current_Schema", "Current_Table", "Current_Column", "Current_Datatype", "New_Schema", "New_Table", "New_Column", "New_Datatype", "Layer", "Justification"]


class Refusal(SystemExit):
    def __init__(self, message, code="PRODUCTION_WRITE_DENIED"):
        LOG.log("change.refused", message, "ERROR", stop_code=code)
        sys.stderr.write(f"REFUSED ({code}): {message}\n")
        super().__init__(EXIT_REFUSED)


# ---------------------------------------------------------------- ingest
def _norm_header(h: str) -> str:
    key = re.sub(r"[^a-z0-9]+", "", (h or "").lower())
    for want in HEADERS:
        if re.sub(r"[^a-z0-9]+", "", want.lower()) == key:
            return want
    return (h or "").strip()


def _read_xlsx(path: pathlib.Path) -> list:
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            shared = ["".join(t.text or "" for t in si.iter("{%s}t" % ns["m"])) for si in root.findall("m:si", ns)]
        sheet = next(n for n in sorted(z.namelist()) if n.startswith("xl/worksheets/sheet"))
        root = ET.fromstring(z.read(sheet))
        rows = []
        for row in root.iter("{%s}row" % ns["m"]):
            cells = {}
            for c in row.findall("m:c", ns):
                ref = re.match(r"([A-Z]+)", c.get("r", "A")).group(1)
                v = c.find("m:v", ns); t = c.get("t")
                val = "" if v is None else (shared[int(v.text)] if t == "s" else v.text)
                if t == "inlineStr":
                    val = "".join(x.text or "" for x in c.iter("{%s}t" % ns["m"]))
                cells[ref] = val
            rows.append(cells)
    if not rows:
        return []
    cols = sorted({k for r in rows for k in r}, key=lambda s: (len(s), s))
    return [[r.get(c, "") for c in cols] for r in rows]


def ingest(path) -> dict:
    p = pathlib.Path(path)
    raw = p.read_bytes()
    big = security.check_size(p)
    if big:
        raise Refusal(f"{p} is too large", "INVALID_INPUT")
    if p.suffix.lower() == ".xlsx":
        matrix = _read_xlsx(p)
    else:
        text = raw.decode("utf-8-sig", errors="replace")
        findings = [x for x in security.scan_text(text, "text", str(p)) if x["rule"] in ("SEC-01", "SEC-02", "SEC-03")]
        if findings:
            raise Refusal(f"{p} failed the input scan: {findings[0]['name']}", "INVALID_INPUT")
        matrix = list(csv.reader(io.StringIO(text)))
    matrix = [r for r in matrix if any((c or "").strip() for c in r)]
    if not matrix:
        raise SystemExit("empty change template")
    headers = [_norm_header(h) for h in matrix[0]]
    rows = []
    for i, r in enumerate(matrix[1:], 2):
        row = {h: (r[j].strip() if j < len(r) and r[j] is not None else "") for j, h in enumerate(headers)}
        for h in HEADERS:
            row.setdefault(h, "")
        row["Change_Type"] = row["Change_Type"].upper().replace(" ", "_"); row["Layer"] = row["Layer"].lower()
        row["row"] = i; row["rowId"] = f"R{i - 1:03d}"
        rows.append(row)
    doc = {"source": str(p), "sha256": sha256_bytes(raw), "headers": headers, "rows": rows, "ingestedAt": now_rfc3339(), "runId": LOG.run_id}
    LOG.log("change.ingest", f"{len(rows)} row(s)", source=str(p), sha256=doc["sha256"])
    return doc


# ---------------------------------------------------------------- validation
def _match(name: str, patterns: list) -> bool:
    return any(fnmatch.fnmatchcase(name.lower(), pat.lower()) for pat in patterns or [])


def validate(changes: dict, snapshot: dict | None, layers: dict | None, policy: dict | None) -> dict:
    layers, policy = layers or {}, policy or {}
    diags, stop = [], []
    rows = json.loads(json.dumps(changes["rows"]))  # never mutate the ingested template
    seen, targets = {}, {}
    for r in rows:
        ct = r["Change_Type"]
        if ct not in CHANGE_TYPES:
            diags.append({"row": r["rowId"], "code": "INVALID_INPUT", "message": f"unknown Change_Type {ct!r}"}); continue
        for f in CHANGE_TYPES[ct]:
            if not r.get(f):
                diags.append({"row": r["rowId"], "code": "INVALID_INPUT", "message": f"{ct} needs {f}"})
        r["Current_Schema"] = r["Current_Schema"].lower(); r["Current_Table"] = r["Current_Table"].lower()
        tbl = f"{r['Current_Schema']}.{r['Current_Table']}"
        r["table"] = tbl
        # layers
        if _match(tbl, layers.get("protected", [])):
            diags.append({"row": r["rowId"], "code": "INVALID_INPUT", "message": f"{tbl} is in a protected layer: changes there are refused"}); r["refused"] = True
        elif layers.get("editable") and not _match(tbl, layers["editable"]):
            diags.append({"row": r["rowId"], "code": "TARGET_DECISION_REQUIRED", "message": f"{tbl} is outside the editable allowlist"}); r["refused"] = True
        # new schema policy
        if not r["New_Schema"]:
            if policy.get("retain_current_schema"):
                r["New_Schema"] = r["Current_Schema"]; r["schemaResolvedBy"] = "policy:retain_current_schema"
            else:
                diags.append({"row": r["rowId"], "code": "TARGET_SCHEMA_DECISION_REQUIRED", "message": "blank New_Schema and no approved policy"})
        # duplicates / conflicts / collisions
        key = (ct, tbl, r["Current_Column"].lower())
        sig = json.dumps({k: r[k] for k in ("New_Schema", "New_Table", "New_Column", "New_Datatype")}, sort_keys=True)
        if key in seen:
            diags.append({"row": r["rowId"], "code": "INVALID_INPUT", "message": ("duplicate of " if seen[key][1] == sig else "conflicts with ") + seen[key][0]}); r["refused"] = True
        else:
            seen[key] = (r["rowId"], sig)
        if ct == "RENAME_COLUMN":
            tk = (tbl, r["New_Column"].lower())
            if tk in targets and targets[tk] != r["Current_Column"].lower():
                diags.append({"row": r["rowId"], "code": "RENAME_COLLISION", "message": f"{r['New_Column']} is also the new name of {targets[tk]}"}); r["refused"] = True
            targets[tk] = r["Current_Column"].lower()
        # metadata grounding
        if ct in ("CAST_COLUMN", "RENAME_COLUMN", "DROP_COLUMN"):
            col = None
            if snapshot:
                t = snapshot["tables"].get(tbl)
                col = next((c for c in t["columns"] if c["name"].lower() == r["Current_Column"].lower()), None) if t else None
            if col:
                if r["Current_Datatype"] and r["Current_Datatype"].upper().replace(" ", "") != col["type"]["raw"].upper().replace(" ", ""):
                    diags.append({"row": r["rowId"], "code": "METADATA_AMBIGUOUS", "message": f"template says {r['Current_Datatype']}, catalog says {col['type']['raw']}"})
                r["currentType"] = col["type"]; r["currentNullable"] = col["nullable"]; r["metadataProvenance"] = f"{snapshot['provenance']['method']}:{snapshot['hash'][:12]}"
            elif r["Current_Datatype"] and snapshot is None:
                r["currentType"] = norm_raw(r["Current_Datatype"]); r["metadataProvenance"] = "template (unverified)"
                diags.append({"row": r["rowId"], "code": "METADATA_NOT_FOUND", "message": "no authoritative snapshot: datatype taken from the template is unverified"})
            else:
                diags.append({"row": r["rowId"], "code": "METADATA_NOT_FOUND", "message": f"column {tbl}.{r['Current_Column']} not found in the authoritative snapshot"})
        if ct == "RENAME_TABLE" and snapshot and tbl not in snapshot["tables"]:
            diags.append({"row": r["rowId"], "code": "METADATA_NOT_FOUND", "message": f"table {tbl} not found in the authoritative snapshot"})
    codes = {d["code"] for d in diags}
    if codes & {"RENAME_COLLISION", "METADATA_NOT_FOUND", "TARGET_SCHEMA_DECISION_REQUIRED"}:
        status = "BLOCKED"
    elif codes:
        status = "PARTIAL"
    else:
        status = "GENERATED"
    for c in ("RENAME_COLLISION", "METADATA_NOT_FOUND", "TARGET_SCHEMA_DECISION_REQUIRED", "METADATA_AMBIGUOUS", "INVALID_INPUT", "TARGET_DECISION_REQUIRED"):
        if c in codes:
            stop.append(c)
    return {"status": status, "stopCodes": stop, "diagnostics": diags, "rows": rows}


def norm_raw(raw: str) -> dict:
    toks = list(ddl.tokenize(raw)); dt, _ = ddl.parse_datatype(toks, 0)
    return {"base": dt["base"], "length": dt["length"], "precision": dt["precision"], "scale": dt["scale"], "raw": raw}


# ---------------------------------------------------------------- cast safety
FAMILY = {"smallint": ("int", 1), "integer": ("int", 2), "int": ("int", 2), "bigint": ("int", 3), "decimal": ("num", 4), "numeric": ("num", 4), "money": ("num", 4),
          "real": ("float", 1), "double": ("float", 2), "double precision": ("float", 2), "float": ("float", 2),
          "varchar": ("text", 1), "nvarchar": ("text", 1), "char": ("text", 1), "text": ("text", 2), "string": ("text", 2),
          "date": ("time", 1), "timestamp": ("time", 2), "timestamptz": ("time", 3), "datetime": ("time", 2), "datetime2": ("time", 2),
          "boolean": ("bool", 1), "bit": ("bool", 1), "uuid": ("uuid", 1)}
DESCRIPTIVE = re.compile(r"(desc|description|name|label|title|comment|note|text|addr|address|email|remark)", re.I)
DATELIKE = re.compile(r"(date|_at$|_ts$|time|created|updated|modified)", re.I)


def cast_safety(column: str, cur: dict, new: dict) -> dict:
    cb = cur["base"].lower(); nb = new["base"].lower()
    cf, cr = FAMILY.get(cb, (cb, 0)); nf, nr = FAMILY.get(nb, (nb, 0))
    risk, reasons = "SAFE", []
    if cf == nf:
        if nf == "text":
            cl, nl = cur.get("length"), new.get("length")
            if nl not in (None, "MAX") and (cl == "MAX" or (isinstance(cl, int) and nl < cl)):
                risk, reasons = "LOSSY", [f"length {cl} → {nl} truncates"]
        elif nf == "num":
            cp, cs = cur.get("precision") or 18, cur.get("scale") or 0; np_, ns = new.get("precision") or 18, new.get("scale") if new.get("scale") is not None else 0
            if ns < cs or np_ - ns < cp - cs:
                risk, reasons = "LOSSY", [f"precision/scale ({cp},{cs}) → ({np_},{ns})"]
        elif nr < cr:
            risk, reasons = "LOSSY", [f"narrowing {cb} → {nb}: overflow possible"]
    elif cf == "int" and nf == "num":
        risk = "SAFE"
    elif cf in ("int", "num", "float", "time", "bool", "uuid") and nf == "text":
        risk = "SAFE"; reasons = ["formatting is engine-specific"]
    elif cf == "num" and nf == "int":
        risk, reasons = "LOSSY", ["fractional part is truncated/rounded"]
    elif cf == "text" and nf in ("int", "num", "float"):
        risk, reasons = ("HIGH_RISK" if DESCRIPTIVE.search(column) or DATELIKE.search(column) else "LOSSY"), ["non-numeric values fail or become NULL"]
    elif cf == "text" and nf == "time":
        risk, reasons = ("HIGH_RISK" if not DATELIKE.search(column) else "LOSSY"), ["date parsing depends on the format"]
    elif cf in ("int", "num") and nf == "bool":
        risk, reasons = "HIGH_RISK", ["numeric → boolean semantics must be approved"]
    elif cf == "time" and nf == "time":
        risk = "SAFE"
    elif cf == "float" and nf in ("int", "num"):
        risk, reasons = "LOSSY", ["rounding"]
    else:
        risk, reasons = "UNSUPPORTED", [f"no cast rule {cb} → {nb}"]
    return {"risk": risk, "reasons": reasons, "from": cur.get("raw", cb), "to": new.get("raw", nb)}


# ---------------------------------------------------------------- planning
def plan(changes: dict, snapshot: dict | None, layers: dict | None, policy: dict | None, profile: dict | None, flow_files: dict | None) -> dict:
    v = validate(changes, snapshot, layers, policy)
    policy, profile = policy or {}, profile or {}
    ops, ledger, risks, stop = [], contract.RuleLedger(), [], list(v["stopCodes"])
    status = v["status"]
    if status == "BLOCKED":
        return {"status": status, "stopCodes": stop, "validation": v, "operations": [], "ruleLedger": [], "risks": [], "propagation": [], "rollback": []}
    seq = 0
    active = [r for r in v["rows"] if not r.get("refused") and r["Change_Type"] in CHANGE_TYPES]
    # 1. casts (reference the current column name)
    for r in active:
        if r["Change_Type"] != "CAST_COLUMN":
            continue
        new = norm_raw(r["New_Datatype"]); cur = r.get("currentType") or {"base": "", "raw": r["Current_Datatype"]}
        cs = cast_safety(r["Current_Column"], cur, new)
        key = f"{r['table']}.{r['Current_Column'].lower()}"
        prof = profile.get(key); disp = (policy.get("cast_dispositions") or {}).get(key)
        risk = dict(cs, row=r["rowId"], column=key, profile=prof, disposition=disp)
        if prof:
            risk["originalNulls"] = prof.get("nulls", 0); risk["castInducedNulls"] = prof.get("non_numeric", 0) + prof.get("overflow", 0)
            if risk["castInducedNulls"] and not policy.get("on_failure"):
                risk["risk"] = "HIGH_RISK" if risk["risk"] != "UNSUPPORTED" else risk["risk"]; risk["reasons"].append(f"{risk['castInducedNulls']} value(s) would fail without an approved on_failure rule")
        if cs["risk"] in ("HIGH_RISK", "UNSUPPORTED") or risk.get("castInducedNulls"):
            if disp and disp.get("decision") == "REJECTED":
                risk["outcome"] = "REJECTED by " + disp.get("by", "reviewer"); risks.append(risk)
                ledger.add("CP-11", f"{r['rowId']} CAST {key} → {new['raw']}", "not generated", f"rejected: {disp.get('reason', '')}", manual=True); continue
            if disp and disp.get("decision") == "APPROVED" and (prof is not None or cs["risk"] not in ("HIGH_RISK", "UNSUPPORTED")):
                risk["outcome"] = "APPROVED by " + disp.get("by", "reviewer")
            elif cs["risk"] == "UNSUPPORTED":
                risk["outcome"] = "BLOCKED"; status = "BLOCKED"; stop.append("UNSUPPORTED_CONSTRUCT") if "UNSUPPORTED_CONSTRUCT" not in stop else None
                risks.append(risk); ledger.add("CP-10", f"{r['rowId']} CAST {key}", "not generated", "; ".join(cs["reasons"]), manual=True); continue
            else:
                risk["outcome"] = "REVIEW_REQUIRED" + ("" if prof is not None else " (no data profile)")
                status = "PARTIAL" if status != "BLOCKED" else status
                if "UNSAFE_CAST_REVIEW_REQUIRED" not in stop:
                    stop.append("UNSAFE_CAST_REVIEW_REQUIRED")
                risks.append(risk); ledger.add("CP-11", f"{r['rowId']} CAST {key} → {new['raw']}", "pending disposition", "; ".join(cs["reasons"]), manual=True); continue
        risks.append(risk) if risk["risk"] != "SAFE" or prof else None
        seq += 1
        ops.append({"seq": seq, "row": r["rowId"], "op": "CAST_COLUMN", "table": r["table"], "column": r["Current_Column"].lower(), "from": cur.get("raw", ""), "to": new["raw"],
                    "risk": risk["risk"], "onFailure": policy.get("on_failure") if risk.get("castInducedNulls") else None,
                    "sql": f"ALTER TABLE {r['table']} ALTER COLUMN {r['Current_Column'].lower()} TYPE {new['raw']} USING ({r['Current_Column'].lower()})::{new['raw']};"})
        ledger.add("CP-14", f"{r['rowId']} CAST {key} → {new['raw']}", "ALTER COLUMN TYPE (before rename)", f"cast safety {risk['risk']}" + (": " + "; ".join(risk["reasons"]) if risk["reasons"] else ""))
    # 2. adds / drops
    for r in active:
        if r["Change_Type"] == "ADD_COLUMN":
            seq += 1; ops.append({"seq": seq, "row": r["rowId"], "op": "ADD_COLUMN", "table": r["table"], "column": r["New_Column"].lower(), "to": r["New_Datatype"], "sql": f"ALTER TABLE {r['table']} ADD COLUMN {r['New_Column'].lower()} {r['New_Datatype']};"})
            ledger.add("CP-14", f"{r['rowId']} ADD {r['table']}.{r['New_Column']}", "ADD COLUMN", r.get("Justification", ""))
        elif r["Change_Type"] == "DROP_COLUMN":
            seq += 1; ops.append({"seq": seq, "row": r["rowId"], "op": "DROP_COLUMN", "table": r["table"], "column": r["Current_Column"].lower(), "sql": f"ALTER TABLE {r['table']} DROP COLUMN {r['Current_Column'].lower()};"})
            ledger.add("CP-14", f"{r['rowId']} DROP {r['table']}.{r['Current_Column']}", "DROP COLUMN", r.get("Justification", ""), manual=True)
    # 3. column renames, 4. table renames (last)
    renames = {}
    for r in active:
        if r["Change_Type"] == "RENAME_COLUMN":
            old, new = r["Current_Column"].lower(), r["New_Column"].lower()
            if policy.get("naming", "snake_case") == "snake_case" and new != re.sub(r"[^a-z0-9_]", "_", new):
                status = "PARTIAL"; ledger.add("CP-14", f"{r['rowId']} RENAME {old}", "not generated", f"{new} violates the snake_case naming policy", manual=True); continue
            seq += 1; ops.append({"seq": seq, "row": r["rowId"], "op": "RENAME_COLUMN", "table": r["table"], "column": old, "to": new, "sql": f"ALTER TABLE {r['table']} RENAME COLUMN {old} TO {new};"})
            renames[(r["table"], old)] = new
            ledger.add("CP-14", f"{r['rowId']} RENAME {r['table']}.{old}", f"→ {new} (after casts)", "naming policy " + policy.get("naming", "snake_case"))
    table_renames = {}
    for r in active:
        if r["Change_Type"] == "RENAME_TABLE":
            new = f"{r['New_Schema'] or r['Current_Schema']}.{r['New_Table'].lower()}"
            seq += 1; ops.append({"seq": seq, "row": r["rowId"], "op": "RENAME_TABLE", "table": r["table"], "to": new, "sql": f"ALTER TABLE {r['table']} RENAME TO {r['New_Table'].lower()};" + (f"  -- schema stays {r['New_Schema']} ({r.get('schemaResolvedBy', 'template')})")})
            table_renames[r["table"]] = new
            ledger.add("CP-14", f"{r['rowId']} RENAME TABLE {r['table']}", f"→ {new} (last)", f"schema resolved by {r.get('schemaResolvedBy', 'template')}")
    # propagation through the flow
    propagation = []
    for fname, text in sorted((flow_files or {}).items()):
        for (tbl, old), new in renames.items():
            for ln in _lines_with_identifier(text, old, tbl):
                propagation.append({"file": fname, "line": ln, "kind": "column", "table": tbl, "old": old, "new": new})
        for tbl, new in table_renames.items():
            for ln in _lines_with_identifier(text, tbl.split(".")[-1], None, schema=tbl.split(".")[0]):
                propagation.append({"file": fname, "line": ln, "kind": "table", "table": tbl, "old": tbl, "new": new})
    rollback = [{"seq": o["seq"], "sql": _rollback_sql(o), "note": "cast back is lossy when the forward cast widened data" if o["op"] == "CAST_COLUMN" else ""} for o in reversed(ops)]
    return {"status": status, "stopCodes": stop, "validation": v, "operations": ops, "ruleLedger": ledger.to_list(), "risks": risks, "propagation": propagation,
            "rollback": rollback, "policy": policy, "layers": layers or {}, "sourceSha256": changes["sha256"], "snapshotHash": (snapshot or {}).get("hash"), "generatedAt": now_rfc3339(), "runId": LOG.run_id}


def _rollback_sql(o: dict) -> str:
    if o["op"] == "CAST_COLUMN":
        return f"ALTER TABLE {o['table']} ALTER COLUMN {o['column']} TYPE {o['from']} USING ({o['column']})::{o['from']};"
    if o["op"] == "RENAME_COLUMN":
        return f"ALTER TABLE {o['table']} RENAME COLUMN {o['to']} TO {o['column']};"
    if o["op"] == "RENAME_TABLE":
        return f"ALTER TABLE {o['to']} RENAME TO {o['table'].split('.')[-1]};"
    if o["op"] == "ADD_COLUMN":
        return f"ALTER TABLE {o['table']} DROP COLUMN {o['column']};"
    if o["op"] == "DROP_COLUMN":
        return f"-- restore {o['table']}.{o['column']} from the pre-change backup (data loss otherwise)"
    return ""


# ---------------------------------------------------------------- token-aware patching
def _statements(text: str) -> list:
    """[(start, end)] character spans of top-level statements (';' outside strings/comments/$$)."""
    spans, start, i, n = [], 0, 0, len(text)
    in_str = in_line = in_block = in_dollar = False
    while i < n:
        ch, nxt = text[i], text[i + 1] if i + 1 < n else ""
        if in_line:
            in_line = ch != "\n"
        elif in_block:
            if ch == "*" and nxt == "/":
                in_block = False; i += 1
        elif in_dollar:
            if ch == "$" and nxt == "$":
                in_dollar = False; i += 1
        elif in_str:
            in_str = ch != "'"
        elif ch == "'":
            in_str = True
        elif ch == "-" and nxt == "-":
            in_line = True
        elif ch == "/" and nxt == "*":
            in_block = True
        elif ch == "$" and nxt == "$":
            in_dollar = True; i += 1
        elif ch == ";":
            spans.append((start, i + 1)); start = i + 1
        i += 1
    if text[start:].strip():
        spans.append((start, n))
    return spans


def _identifier_tokens(text: str):
    """(start, end, name) for identifier tokens outside comments and strings (bracket/dquote identifiers unwrapped)."""
    for m in re.finditer(r"--[^\n]*|/\*[\s\S]*?\*/|'(?:[^']|'')*'|\"([^\"]+)\"|\[([^\]]+)\]|\b([A-Za-z_][\w$]*)\b", text):
        if m.group(1) or m.group(2) or m.group(3):
            yield m.start(), m.end(), (m.group(1) or m.group(2) or m.group(3))


def _lines_with_identifier(text: str, name: str, table: str | None, schema: str | None = None) -> list:
    lines = set()
    for s, e, tok in _identifier_tokens(text):
        if tok.lower() != name.lower():
            continue
        stmt = next((text[a:b] for a, b in _statements(text) if a <= s < b), "")
        if table and not re.search(r"\b" + re.escape(table) + r"\b", stmt, re.I):
            continue
        if schema and not (text[max(0, s - len(schema) - 1):s].lower() == schema.lower() + "."):
            continue
        lines.add(text.count("\n", 0, s) + 1)
    return sorted(lines)


def patch_text(text: str, plan_doc: dict) -> str:
    # casts first (they reference the current column name inside CREATE TABLE statements of the target table)
    for o in plan_doc["operations"]:
        if o["op"] != "CAST_COLUMN":
            continue
        for a, e in reversed(_statements(text)):
            stmt = text[a:e]
            if re.search(r"\bCREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?" + re.escape(o["table"]) + r"\b", stmt, re.I):
                new_stmt = re.sub(r"(?im)^(\s*" + re.escape(o["column"]) + r"\s+)[A-Za-z_][\w ]*?(\s*\([^)]*\))?(?=\s*(,|NOT\b|NULL\b|DEFAULT\b|CONSTRAINT\b|PRIMARY\b|REFERENCES\b|GENERATED\b|\)|--|$))",
                                  lambda m: m.group(1) + o["to"], stmt, count=1)
                text = text[:a] + new_stmt + text[e:]
    renames = {(o["table"], o["column"]): o["to"] for o in plan_doc["operations"] if o["op"] == "RENAME_COLUMN"}
    trenames = {o["table"]: o["to"] for o in plan_doc["operations"] if o["op"] == "RENAME_TABLE"}
    spans = _statements(text)
    edits = []
    for s, e, tok in _identifier_tokens(text):
        stmt = next((text[a:b] for a, b in spans if a <= s < b), "")
        low = tok.lower()
        for (tbl, old), new in renames.items():
            if low == old and re.search(r"\b" + re.escape(tbl) + r"\b", stmt, re.I):
                # skip when the token is qualified by another object (alias of a protected table): x.asset_code where x is not the table/its alias
                q = re.match(r".*?([A-Za-z_]\w*)\.$", text[max(0, s - 64):s], re.S)
                if q:
                    qual = q.group(1).lower()
                    alias = re.search(r"\b" + re.escape(tbl) + r"\s+(?:AS\s+)?([A-Za-z_]\w*)", stmt, re.I)
                    if qual not in (tbl.split(".")[-1], (alias.group(1).lower() if alias else None), "excluded", "new", "old"):
                        continue
                edits.append((s, e, new))
        for tbl, new in trenames.items():
            sch, name = tbl.split(".")
            if low == name and text[max(0, s - len(sch) - 1):s].lower() == sch + ".":
                edits.append((s, e, new.split(".")[-1]))
    out, pos = [], 0
    for s, e, new in sorted(edits):
        out.append(text[pos:s]); out.append(new); pos = e
    out.append(text[pos:])
    return "".join(out)


def apply_patches(plan_doc: dict, flow: dict, layers: dict) -> dict:
    editable = layers.get("editable_files") or ["*"]
    patched, diffs, protected = {}, {}, []
    for fname, text in sorted(flow.items()):
        if _match(fname, editable):
            new = patch_text(text, plan_doc)
            patched[fname] = new
            if new != text:
                diffs[fname] = "".join(difflib.unified_diff(text.splitlines(True), new.splitlines(True), f"a/{fname}", f"b/{fname}"))
        else:
            patched[fname] = text; protected.append(fname)
    return {"files": patched, "diffs": diffs, "protected": protected, "changed": sorted(diffs)}


def residual_scan(plan_doc: dict, flow: dict, patched: dict, layers: dict) -> dict:
    editable = layers.get("editable_files") or ["*"]
    old_cols = {(o["table"], o["column"]) for o in plan_doc["operations"] if o["op"] == "RENAME_COLUMN"}
    old_tables = {o["table"] for o in plan_doc["operations"] if o["op"] == "RENAME_TABLE"}
    unexplained, explained = [], []
    for fname, text in sorted(patched.items()):
        if not _match(fname, editable):
            continue
        for (tbl, old) in old_cols:
            for ln in _lines_with_identifier(text, old, tbl):
                unexplained.append({"file": fname, "line": ln, "identifier": old, "table": tbl})
            for m in re.finditer(r"--[^\n]*|'(?:[^']|'')*'", text):
                if re.search(r"\b" + re.escape(old) + r"\b", m.group(0), re.I):
                    explained.append({"file": fname, "line": text.count("\n", 0, m.start()) + 1, "identifier": old, "where": "comment/literal"})
        for tbl in old_tables:
            sch, name = tbl.split(".")
            for ln in _lines_with_identifier(text, name, None, schema=sch):
                unexplained.append({"file": fname, "line": ln, "identifier": tbl, "table": tbl})
    protected_clean = all(patched.get(f) == flow.get(f) for f in flow if not _match(f, editable))
    return {"unexplained": unexplained, "explained": explained, "protectedDiffClean": protected_clean}


# ---------------------------------------------------------------- commands
def _load_flow(flow_dir) -> dict:
    root = pathlib.Path(flow_dir)
    out = {}
    for f in sorted(root.rglob("*")):
        if f.is_file() and f.suffix.lower() in (".sql", ".py", ".json", ".yaml", ".yml"):
            big = security.check_size(f)
            if big:
                raise Refusal(f"{f} is too large", "INVALID_INPUT")
            out[f"{root.name}/{f.relative_to(root).as_posix()}"] = f.read_text(encoding="utf-8-sig", errors="replace")
    return out


def cmd_ingest(a):
    doc = ingest(a.template)
    pathlib.Path(a.out).write_text(contract.canonical_json(doc), encoding="utf-8")
    print(f"ingested {len(doc['rows'])} row(s) from {a.template} (sha256 {doc['sha256'][:12]}) → {a.out}")
    return 0


def _ctx(a):
    snap = contract.load_json(a.snapshot) if a.snapshot else None
    layers = contract.load_json(a.layers) if a.layers else None
    policy = contract.load_json(a.policy) if a.policy else None
    return snap, layers, policy


def cmd_validate(a):
    snap, layers, policy = _ctx(a)
    with LOG.span("change.validate", template=str(a.changes)) as o:
        v = validate(contract.load_json(a.changes), snap, layers, policy)
        o.update(status=v["status"], diagnostics=len(v["diagnostics"]))
    if a.json:
        print(contract.canonical_json({k: v[k] for k in ("status", "stopCodes", "diagnostics")}))
    else:
        for d in v["diagnostics"]:
            print(f"{d['code']:<32} {d['row']}: {d['message']}")
        print(f"validate: {v['status']} ({len(v['diagnostics'])} diagnostic(s))")
    return 0 if v["status"] == "GENERATED" else 1


def cmd_plan(a):
    snap, layers, policy = _ctx(a)
    prof = contract.load_json(a.profile) if a.profile else None
    flow = _load_flow(a.flow) if a.flow else {}
    with LOG.span("change.plan", template=str(a.changes)) as o:
        p = plan(contract.load_json(a.changes), snap, layers, policy, prof, flow)
        o.update(status=p["status"], operations=len(p["operations"]), risks=len(p["risks"]))
    pathlib.Path(a.out).write_text(contract.canonical_json(p), encoding="utf-8")
    print(f"plan → {a.out}: {p['status']} — {len(p['operations'])} operation(s), {len(p['risks'])} risk(s), {len(p['propagation'])} propagation site(s)" + (f", stop codes {p['stopCodes']}" if p["stopCodes"] else ""))
    for d in p["validation"]["diagnostics"]:
        print(f"  {d['code']:<32} {d['row']}: {d['message']}")
    for r in p["risks"]:
        print(f"  {r['risk']:<10} {r['row']} {r['column']} {r['from']} → {r['to']}: {r.get('outcome', '')} {'; '.join(r['reasons'])}")
    return 0 if p["status"] in ("GENERATED", "VALIDATED") else 1


def cmd_patch(a):
    if a.apply:
        raise Refusal("this tool never applies patches to a live target; deploy the reviewed package through the normal path")
    p = contract.load_json(a.plan)
    if p["status"] == "BLOCKED":
        print("plan is BLOCKED: no patches generated"); return 1
    flow = _load_flow(a.flow)
    with LOG.span("change.patch", plan=str(a.plan)) as o:
        res = apply_patches(p, flow, p.get("layers", {}))
        scan = residual_scan(p, flow, res["files"], p.get("layers", {}))
        o.update(changed=len(res["changed"]), unexplained=len(scan["unexplained"]), protected_clean=scan["protectedDiffClean"])
    od = pathlib.Path(a.out); (od / "after").mkdir(parents=True, exist_ok=True)
    for fname, text in res["files"].items():
        if fname in res["changed"]:
            dest = od / "after" / fname; dest.parent.mkdir(parents=True, exist_ok=True); dest.write_text(text, encoding="utf-8", newline="\n")
    (od / "changes.diff").write_text("".join(res["diffs"][f] for f in res["changed"]), encoding="utf-8", newline="\n")
    (od / "migration.sql").write_text("-- DRY RUN: ordered cast-before-rename migration (review before deployment)\n" + "\n".join(o["sql"] for o in p["operations"]) + "\n", encoding="utf-8", newline="\n")
    (od / "rollback.sql").write_text("-- Rollback (reverse order)\n" + "\n".join(f"{r['sql']}{'  -- ' + r['note'] if r['note'] else ''}" for r in p["rollback"]) + "\n", encoding="utf-8", newline="\n")
    (od / "residual-scan.json").write_text(contract.canonical_json(scan), encoding="utf-8")
    print(f"patch → {od}: {len(res['changed'])} file(s) changed, {len(scan['unexplained'])} unexplained residual(s), protected diff {'clean' if scan['protectedDiffClean'] else 'DIRTY'}")
    for u in scan["unexplained"]:
        print(f"  RESIDUAL {u['file']}:{u['line']} {u['identifier']}")
    return 0 if not scan["unexplained"] and scan["protectedDiffClean"] else 1


def cmd_scan(a):
    p = contract.load_json(a.plan); flow = _load_flow(a.flow)
    patched = dict(flow)
    if a.patched:
        after = pathlib.Path(a.patched) / "after"
        for f in after.rglob("*"):
            if f.is_file():
                patched[f.relative_to(after).as_posix()] = f.read_text(encoding="utf-8")
    scan = residual_scan(p, flow, patched, p.get("layers", {}))
    print(contract.canonical_json(scan) if a.json else f"scan: {len(scan['unexplained'])} unexplained residual(s), {len(scan['explained'])} explained, protected diff {'clean' if scan['protectedDiffClean'] else 'DIRTY'}")
    return 0 if not scan["unexplained"] else 1


def cmd_package(a):
    p = contract.load_json(a.plan)
    pd = pathlib.Path(a.patches)
    files = {}
    for f in sorted(pd.rglob("*")):
        if f.is_file():
            files[f.relative_to(pd).as_posix()] = f.read_text(encoding="utf-8")
    scan = json.loads(files.get("residual-scan.json", "{}") or "{}")
    req = contract.new_request(a.request_id or "schema-change", "SQLServer", "schema", "change-template", "", "AuroraPostgreSQL")
    out = contract.new_output(req["requestId"])
    if a.classification and pathlib.Path(a.classification).exists():
        out["classification"] = contract.load_json(a.classification).get("classification", out["classification"])
    out["analysis"]["ruleLedger"] = p["ruleLedger"]
    out["analysis"]["manualReviewItems"] = [f"{r['row']} {r['column']}: {r['risk']} {r.get('outcome', '')}" for r in p["risks"] if r.get("outcome") not in (None, "") and not str(r.get("outcome", "")).startswith("APPROVED")]
    out["analysis"]["warnings"] = [f"{d['code']} {d['row']}: {d['message']}" for d in p["validation"]["diagnostics"]]
    out["artifacts"]["convertedCode"] = files.get("migration.sql", ""); out["artifacts"]["rollbackNotes"] = [files.get("rollback.sql", "")]
    out["artifacts"]["supportingCode"] = [k for k in files if k.startswith("after/")]
    if p["status"] == "BLOCKED":
        contract.set_status(out, "BLOCKED", *p["stopCodes"])
    elif p["status"] == "PARTIAL" or scan.get("unexplained"):
        contract.set_status(out, "PARTIAL", *(p["stopCodes"] or (["STATIC_VALIDATION_FAILED"] if scan.get("unexplained") else [])))
    executed = {"V-001": {"status": "PASS", "evidence": f"template sha256 {p['sourceSha256'][:12]}"}, "V-002": {"status": "PASS" if p.get("snapshotHash") else "FAIL", "evidence": f"snapshot {p.get('snapshotHash')}"},
                "V-004": {"status": "PASS" if not scan.get("unexplained") else "FAIL", "evidence": f"{len(scan.get('unexplained', []))} unexplained residual(s)"},
                "V-039": {"status": "PASS", "evidence": "rollback.sql generated"}}
    out["validation"] = contract.validation_manifest(["V-001", "V-002", "V-004", "V-006", "V-012", "V-013", "V-033", "V-035", "V-039"], executed)
    m = contract.write_package(a.out, req, out, files={**files, "plan.json": contract.canonical_json(p)})
    print(f"package → {a.out} ({out['status']}, {len(m['files'])} files, {len(p['ruleLedger'])} ledger rows)")
    LOG.log("change.package", out["status"], package=str(a.out), status=out["status"])
    return 0 if out["status"] in ("GENERATED", "VALIDATED") else 1


def main():
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ingest"); p.add_argument("template"); p.add_argument("--out", required=True); p.set_defaults(fn=cmd_ingest)
    for name, fn in (("validate", cmd_validate), ("plan", cmd_plan)):
        p = sub.add_parser(name); p.add_argument("changes"); p.add_argument("--snapshot"); p.add_argument("--layers"); p.add_argument("--policy")
        if name == "plan":
            p.add_argument("--profile"); p.add_argument("--flow"); p.add_argument("--out", required=True)
        else:
            p.add_argument("--json", action="store_true")
        p.set_defaults(fn=fn)
    p = sub.add_parser("patch"); p.add_argument("plan"); p.add_argument("--flow", required=True); p.add_argument("--out", required=True); p.add_argument("--apply", action="store_true"); p.set_defaults(fn=cmd_patch)
    p = sub.add_parser("scan"); p.add_argument("plan"); p.add_argument("--flow", required=True); p.add_argument("--patched"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_scan)
    p = sub.add_parser("package"); p.add_argument("plan"); p.add_argument("--patches", required=True); p.add_argument("--out", required=True); p.add_argument("--classification"); p.add_argument("--request-id"); p.set_defaults(fn=cmd_package)
    a = ap.parse_args()
    with LOG.span(f"change.{a.cmd}", argv=[str(x) for x in sys.argv[1:]], tool_version=TOOL_VERSION) as o:
        rc = a.fn(a)
        o.update(status="ok" if rc == 0 else "failed", exit_code=rc)
        return rc


if __name__ == "__main__":
    sys.exit(main())
