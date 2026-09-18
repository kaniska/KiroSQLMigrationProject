"""
migkit.contract — governance contracts shared by every migration skill.

Implements the universal input/output contract, status semantics, stop codes, review tiers,
placement roles, the rule ledger and the conversion (evidence) package described in the
the kit's SQL conversion governance model:

  * statuses      GENERATED | PARTIAL | BLOCKED | VALIDATED   (VALIDATED is never production approval)
  * stop codes    INVALID_INPUT, INVALID_SOURCE_DIALECT, TARGET_DECISION_REQUIRED, METADATA_NOT_FOUND,
                  METADATA_AMBIGUOUS, METADATA_SOURCE_UNAVAILABLE, METADATA_STALE, DEPENDENCY_UNRESOLVED,
                  SECURITY_MAPPING_REQUIRED, UNSUPPORTED_CONSTRUCT, UNSAFE_CAST_REVIEW_REQUIRED,
                  CONTRACT_COLLISION, STATIC_VALIDATION_FAILED, SEMANTIC_VALIDATION_FAILED,
                  PRODUCTION_WRITE_DENIED, RENAME_COLLISION, TARGET_SCHEMA_DECISION_REQUIRED
  * roles         LEFT_EDGE | MIDDLE | RIGHT_EDGE | ELIMINATE | REVIEW      (M2RVE placement)
  * complexity    L1..L4 ; review tiers T1..T3
  * rule ledger   one row per non-trivial transformation: rule id, source feature, target treatment, reason
  * package       conversion-package/<request>/: request, source hash, snapshot hashes, plan, output, ledger,
                  validation manifest with executed/unexecuted checks, warnings, manual items, run id

Everything is JSON, deterministic (sorted keys) and hashed, so a rerun with unchanged inputs yields
identical artifacts (NFR-001 idempotency) and the audit log can reference them.
"""
import datetime as _dt
import hashlib
import json
import os
import pathlib
import re

try:
    from .audit import run_id as _run_id, now_rfc3339, sha256_bytes  # type: ignore
    from . import __version__ as KIT_VERSION  # type: ignore
except ImportError:  # executed as a script
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    from migkit.audit import run_id as _run_id, now_rfc3339, sha256_bytes  # type: ignore
    from migkit import __version__ as KIT_VERSION  # type: ignore

STATUSES = ("GENERATED", "PARTIAL", "BLOCKED", "VALIDATED")
STOP_CODES = {
    "INVALID_INPUT": "Input violates the contract or a cross-field rule",
    "INVALID_SOURCE_DIALECT": "Unsupported or missing source dialect",
    "TARGET_DECISION_REQUIRED": "Target placement is not decided or approved",
    "METADATA_NOT_FOUND": "Required authoritative metadata is absent",
    "METADATA_AMBIGUOUS": "Multiple objects match",
    "METADATA_SOURCE_UNAVAILABLE": "Catalog / MCP / database unavailable",
    "METADATA_STALE": "Snapshot exceeds the approved freshness",
    "DEPENDENCY_UNRESOLVED": "A referenced object could not be resolved",
    "SECURITY_MAPPING_REQUIRED": "Identity / access mapping is absent for security-bearing SQL",
    "UNSUPPORTED_CONSTRUCT": "No approved conversion pattern for a construct",
    "UNSAFE_CAST_REVIEW_REQUIRED": "Potential loss, overflow, NULL or semantic change in a cast",
    "CONTRACT_COLLISION": "Rename or output mapping collides",
    "RENAME_COLLISION": "Two change rows map to the same target name",
    "TARGET_SCHEMA_DECISION_REQUIRED": "Blank target schema without an approved default",
    "STATIC_VALIDATION_FAILED": "Target parse / compile / lint failed",
    "SEMANTIC_VALIDATION_FAILED": "A critical data, logic or security check failed",
    "PRODUCTION_WRITE_DENIED": "A production write was attempted and refused",
}
ROLES = ("LEFT_EDGE", "MIDDLE", "RIGHT_EDGE", "ELIMINATE", "REVIEW")
COMPLEXITY = ("L1", "L2", "L3", "L4")
REVIEW_TIERS = ("T1", "T2", "T3")
SOURCE_PLATFORMS = ("SQLServer", "Oracle")
TARGET_PLATFORMS = ("AuroraPostgreSQL", "Redshift", "Iceberg", "GluePySpark", "SparkSQL")
OBJECT_TYPES = ("TABLE", "VIEW", "DTV", "FUNCTION", "PROCEDURE", "TRIGGER", "ETL_SQL")
SKILL_FOR_TARGET = {"AuroraPostgreSQL": "sql-conversion", "Redshift": "sql-conversion-redshift",
                    "Iceberg": "sql-conversion-iceberg", "GluePySpark": "sql-conversion-iceberg", "SparkSQL": "sql-conversion-iceberg"}
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


def canonical_json(obj) -> str:
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- input contract
def validate_request(req: dict) -> dict:
    """Validate a universal input contract. Returns {"ok": bool, "stop_codes": [...], "diagnostics": [...]} with
    stable, sorted diagnostics (field, code, message)."""
    diags = []

    def bad(field, code, msg):
        diags.append({"field": field, "code": code, "message": msg})

    if not isinstance(req, dict):
        return {"ok": False, "stop_codes": ["INVALID_INPUT"], "diagnostics": [{"field": "$", "code": "INVALID_INPUT", "message": "request must be a JSON object"}]}
    rid = req.get("requestId")
    if not isinstance(rid, str) or not REQUEST_ID_RE.match(rid):
        bad("requestId", "INVALID_INPUT", "requestId must be 1-128 chars of letters, digits, . _ : -")
    src = req.get("source") or {}
    if not isinstance(src, dict):
        bad("source", "INVALID_INPUT", "source must be an object"); src = {}
    plat = src.get("platform")
    if plat not in SOURCE_PLATFORMS:
        bad("source.platform", "INVALID_SOURCE_DIALECT", f"source.platform must be one of {list(SOURCE_PLATFORMS)}")
    ot = src.get("objectType")
    if ot not in OBJECT_TYPES:
        bad("source.objectType", "INVALID_INPUT", f"source.objectType must be one of {list(OBJECT_TYPES)}")
    if not src.get("objectName"):
        bad("source.objectName", "INVALID_INPUT", "source.objectName is required")
    metadata_only = bool((req.get("options") or {}).get("metadataOnly"))
    if not metadata_only and not (isinstance(src.get("definition"), str) and src.get("definition", "").strip()):
        bad("source.definition", "INVALID_INPUT", "source.definition (SQL text) is required unless options.metadataOnly is true")
    tgt = req.get("target") or {}
    if not isinstance(tgt, dict):
        bad("target", "INVALID_INPUT", "target must be an object"); tgt = {}
    tp = tgt.get("platform")
    if tp in (None, "", "TBD", "UNDECIDED"):
        bad("target.platform", "TARGET_DECISION_REQUIRED", "target.platform is undecided — run the migration-assessment skill first")
    elif tp not in TARGET_PLATFORMS:
        bad("target.platform", "INVALID_INPUT", f"target.platform must be one of {list(TARGET_PLATFORMS)}")
    ctx = req.get("context") or {}
    if not isinstance(ctx, dict):
        bad("context", "INVALID_INPUT", "context must be an object"); ctx = {}
    if ot == "TABLE" and not ctx.get("sourceMetadata") and not metadata_only and tp:
        # a table conversion with no metadata snapshot is allowed only from DDL; record it as non-authoritative
        diags.append({"field": "context.sourceMetadata", "code": "METADATA_NOT_FOUND",
                      "message": "no metadata snapshot supplied: columns will be derived from the DDL and marked non-authoritative", "severity": "warning"})
    opts = req.get("options") or {}
    for k in ("preserveConsumerContract", "generateValidationSql", "generateRollback"):
        if k in opts and not isinstance(opts[k], bool):
            bad(f"options.{k}", "INVALID_INPUT", f"options.{k} must be boolean")
    if opts.get("reviewTierOverride") not in (None, "", *REVIEW_TIERS):
        bad("options.reviewTierOverride", "INVALID_INPUT", f"reviewTierOverride must be one of {list(REVIEW_TIERS)}")
    blocking = [d for d in diags if d.get("severity", "error") == "error"]
    codes = sorted({d["code"] for d in blocking})
    diags.sort(key=lambda d: (d["field"], d["code"]))
    return {"ok": not blocking, "stop_codes": codes, "diagnostics": diags}


def new_request(request_id, platform, object_type, object_name, definition, target_platform=None, schema=None, **context) -> dict:
    return {"requestId": request_id,
            "source": {"platform": platform, "version": "TBD", "database": "TBD", "schema": schema or "dbo", "objectName": object_name,
                       "objectType": object_type, "definition": definition},
            "target": {"platform": target_platform or "TBD", "schema": "TBD", "namingProfile": "snake_case"},
            "context": dict({"dependentObjects": [], "sourceMetadata": {}, "consumerProfiles": [], "businessRules": [],
                             "securityRules": [], "sampleDataProfile": {}, "validatedPatterns": [], "openDecisions": []}, **context),
            "options": {"preserveConsumerContract": True, "generateValidationSql": True, "generateRollback": False, "reviewTierOverride": None}}


# ---------------------------------------------------------------- output contract
def new_output(request_id: str, status: str = "GENERATED") -> dict:
    assert status in STATUSES
    return {"requestId": request_id, "status": status, "runId": _run_id(), "kitVersion": KIT_VERSION, "generatedAt": now_rfc3339(),
            "classification": {"role": "REVIEW", "complexity": "L1", "reviewTier": "T1", "targetDecision": "", "decisionRationale": ""},
            "artifacts": {"convertedCode": "", "supportingCode": [], "validationSql": [], "deploymentNotes": [], "rollbackNotes": []},
            "analysis": {"dependencies": [], "constructInventory": [], "ruleLedger": [], "datatypeMappings": [], "securityFindings": [],
                         "warnings": [], "manualReviewItems": [], "assumptions": [], "stopCodes": []},
            "validation": {"checklist": [], "evidenceRequired": [], "executedChecks": [], "unexecutedChecks": []}}


def set_status(out: dict, status: str, *stop_codes: str):
    """Statuses only escalate: GENERATED < PARTIAL < BLOCKED; VALIDATED is set explicitly after evidence."""
    order = {"GENERATED": 0, "VALIDATED": 0, "PARTIAL": 1, "BLOCKED": 2}
    if order[status] >= order.get(out["status"], 0):
        out["status"] = status
    for c in stop_codes:
        if c not in STOP_CODES:
            raise ValueError(f"unknown stop code {c}")
        if c not in out["analysis"]["stopCodes"]:
            out["analysis"]["stopCodes"].append(c)
    return out


def review_tier(complexity: str, security: bool, override=None) -> str:
    if override in REVIEW_TIERS:
        return override
    if security or complexity == "L4":
        return "T3"
    if complexity == "L3":
        return "T3"
    if complexity == "L2":
        return "T2"
    return "T1"


# ---------------------------------------------------------------- rule ledger
class RuleLedger:
    """Machine-readable record of every non-trivial transformation (FR-013)."""

    def __init__(self):
        self.rows = []

    def add(self, rule: str, source_feature: str, target_treatment: str, reason: str, line: int = 0, evidence: str = "", manual: bool = False):
        self.rows.append({"seq": len(self.rows) + 1, "rule": rule, "sourceFeature": source_feature, "targetTreatment": target_treatment,
                          "reason": reason, "line": line, "evidenceRequired": evidence, "manualReview": bool(manual)})
        return self

    def to_list(self):
        return list(self.rows)

    def markdown(self) -> str:
        lines = ["| # | Rule | Source feature | Target treatment | Reason | Evidence required |", "|---|---|---|---|---|---|"]
        for r in self.rows:
            lines.append(f"| {r['seq']} | {r['rule']} | {r['sourceFeature']} | {r['targetTreatment']} | {r['reason']}{' **(manual review)**' if r['manualReview'] else ''} | {r['evidenceRequired']} |")
        return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- validation manifest (V-001..V-040 subset)
VALIDATION_CATALOG = {
    "V-001": ("Input", "Required fields complete"), "V-002": ("Provenance", "Source definition checksum captured"),
    "V-003": ("Dependency", "Referenced objects resolved"), "V-004": ("Syntax", "Target parses or compiles"),
    "V-005": ("Structure", "Column names/order match contract"), "V-006": ("Datatype", "Type/precision/scale approved"),
    "V-007": ("Nullability", "Nullability preserved or approved"), "V-008": ("Defaults", "Default semantics preserved"),
    "V-009": ("Constraints", "PK/FK/unique/check accounted for"), "V-010": ("Indexes", "Each supplied source index has a disposition"),
    "V-011": ("Partition", "All supplied values/ranges covered"), "V-012": ("Row count", "Counts reconcile at a defined snapshot"),
    "V-013": ("Key set", "Missing/extra keys identified"), "V-014": ("Duplicate", "Duplicate key distribution reconciles"),
    "V-015": ("Null profile", "Null counts per critical column match"), "V-016": ("Numeric", "Min/max/sum/avg and rounding reconcile"),
    "V-017": ("Date/time", "Min/max, precision, timezone validated"), "V-018": ("Join", "Matched/unmatched and multiplicity reconcile"),
    "V-019": ("Filter", "Included/excluded cohorts reconcile"), "V-020": ("Aggregate", "Group-level totals reconcile"),
    "V-021": ("Window", "Rank/order/partition results reconcile"), "V-022": ("Recursive", "Roots, depth, coverage, cycles validated"),
    "V-023": ("MERGE", "Insert/update/delete and rerun behaviour validated"), "V-024": ("CDC", "Boundaries, late arrival, deletes, restart validated"),
    "V-025": ("Spatial", "Representation, SRID, round-trip, metrics validated"), "V-026": ("RLS positive", "Authorized identities see permitted rows"),
    "V-027": ("RLS negative", "Unauthorized identities cannot see rows"), "V-028": ("CLS", "Restricted columns hidden per design"),
    "V-029": ("Revocation", "Revoked identity loses access"), "V-030": ("Plan", "Representative target plan reviewed"),
    "V-031": ("Runtime", "Representative workload meets target"), "V-032": ("Pruning", "Partition predicate prunes expected data"),
    "V-033": ("Idempotency", "Rerun does not corrupt or duplicate"), "V-034": ("Failure recovery", "Injected failure leaves recoverable state"),
    "V-035": ("Audit", "Run IDs, counts, warnings and changes retained"), "V-036": ("Standards", "Naming and required artifacts conform"),
    "V-037": ("Consumer", "Application/report contract validated"), "V-038": ("Deployment", "Dry-run deployment succeeds"),
    "V-039": ("Rollback", "Rollback or containment documented"), "V-040": ("Approval", "Required reviewers sign off"),
}


def validation_manifest(applicable: list, executed: dict = None) -> dict:
    """applicable: list of V-ids; executed: {V-id: {"status": "PASS|FAIL|ERROR", "evidence": str}}.
    Checks that are applicable but not executed are listed under unexecutedChecks (never marked passed)."""
    executed = executed or {}
    checklist, done, pending, evidence = [], [], [], []
    for vid in sorted(set(applicable)):
        cat, desc = VALIDATION_CATALOG.get(vid, ("?", "?"))
        checklist.append({"id": vid, "category": cat, "check": desc})
        if vid in executed:
            e = dict(executed[vid]); e["id"] = vid; done.append(e)
        else:
            pending.append({"id": vid, "reason": "not executed in this run"})
            evidence.append({"id": vid, "evidence": desc})
    return {"checklist": checklist, "evidenceRequired": evidence, "executedChecks": done, "unexecutedChecks": pending}


# ---------------------------------------------------------------- conversion package
def write_package(pkg_dir, request: dict, output: dict, files: dict = None, extra: dict = None) -> dict:
    """Write the conversion package: request.json, output.json, rule-ledger.md, files/* copies with sha256,
    manifest.json (hashes of everything, run id, kit version). Deterministic file content (sorted keys)."""
    pkg = pathlib.Path(pkg_dir)
    pkg.mkdir(parents=True, exist_ok=True)
    files = files or {}
    written = {}

    def put(name, text):
        p = pkg / name
        p.parent.mkdir(parents=True, exist_ok=True)
        data = text if isinstance(text, bytes) else text.encode("utf-8")
        p.write_bytes(data)
        written[name] = {"sha256": sha256_bytes(data), "bytes": len(data)}

    src_def = (request.get("source") or {}).get("definition", "") or ""
    output = dict(output)
    output.setdefault("provenance", {})
    output["provenance"].update({"sourceDefinitionSha256": sha256_text(src_def), "requestSha256": sha256_text(canonical_json(request))})
    put("request.json", canonical_json(request))
    put("output.json", canonical_json(output))
    ledger = RuleLedger(); ledger.rows = list(output.get("analysis", {}).get("ruleLedger", []))
    put("rule-ledger.md", ledger.markdown())
    put("validation-manifest.json", canonical_json(output.get("validation", {})))
    for name, content in sorted(files.items()):
        put(f"files/{name}", content)
    for name, content in sorted((extra or {}).items()):
        put(name, canonical_json(content) if not isinstance(content, (str, bytes)) else content)
    manifest = {"requestId": request.get("requestId"), "status": output.get("status"), "runId": _run_id(), "kitVersion": KIT_VERSION,
                "createdAt": now_rfc3339(), "files": written}
    (pkg / "manifest.json").write_text(canonical_json(manifest), encoding="utf-8")
    return manifest


def load_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))


def stop_code_table() -> str:
    return "\n".join(f"| {k} | {v} |" for k, v in STOP_CODES.items())
