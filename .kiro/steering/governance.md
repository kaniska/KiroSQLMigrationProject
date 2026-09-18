---
inclusion: always
---

# Migration Governance — Contracts, Statuses, Gates and Skill Routing

Rules that every skill in this workspace follows so that a conversion is reviewable, reproducible
and safe regardless of the target (Aurora PostgreSQL, Amazon Redshift, Apache Iceberg). They are
implemented in the shared engine `.kiro/skills/sql-conversion/scripts/migkit/contract.py`
(rule catalog `GOV-01…GOV-12` in `.kiro/skills/sql-conversion/references/governance.md`). Rule ids `[G-n]`.

## Skills grouped by migration type

**Group 1 — SQL Server object migration** (views, stored procedures, functions, triggers, table DDL,
ETL SQL — whether the SQL comes as standalone `.sql` files or embedded in Informatica PowerCenter
exports). The front door is always `migration-assessment` (`governance.md`); then the target decides
the skill and the steering:

| Target | Standalone SQL objects | SQL embedded in Informatica ETL | Steering |
|---|---|---|---|
| Aurora PostgreSQL | `sql-conversion` | `informatica-etl-conversion` (`check --target postgres`, `params/pg_map.json`) | `migration.md` + `informatica-etl.md` |
| Amazon Redshift | `sql-conversion-redshift` | `informatica-etl-conversion` (`check --target redshift`, `params/redshift_map.json`) | `redshift.md` + `informatica-etl.md` |
| Iceberg on S3 (Athena / Glue / Spark) | `sql-conversion-iceberg` | `informatica-etl-conversion` (`check --target iceberg`, `params/iceberg_map.json`; PowerCenter lands files on S3, the Glue MERGE job loads Iceberg) | `iceberg.md` + `informatica-etl.md` |

**Group 2 — Reporting and analytics SQL generation** on the converted data:

| Target | Skill | Steering |
|---|---|---|
| Aurora PostgreSQL | `sql-reporting` (`report_tool.py check --target postgres`; executed examples) | `reporting.md` + `migration.md` |
| Amazon Redshift | `sql-reporting` (`--target redshift`, `references/examples/redshift/`) | `reporting.md` + `redshift.md` |
| Athena over Iceberg · Spark SQL | `sql-reporting` (`--target athena` / `--target spark`, `references/examples/{athena,spark}/`) | `reporting.md` + `iceberg.md` |

**Group 3 — Schema governance** (any target): `schema-conformance` (snapshots, gap analysis,
conformance, reference checks) and `schema-change-propagation` (rename/cast templates), steering
`schema.md`.

**Agents:** `sql-migration-agent` covers groups 1 and 3 (conversion assistant);
`sql-reporting-agent` covers group 2 plus read-only schema snapshots (reporting SQL assistant).
Both have Windows twins (`*-windows`), the same guardrail hooks and the same audit trail
(`.kiro/agents/AGENTS.md`). Security and audit rules (`security.md`) apply to all of them.

## Hard rules

1. **[G-1] One request contract, one output contract.** Every unit of work is a request
   (`requestId`, `source{platform, objectName, objectType, definition}`, `target{platform, schema,
   namingProfile}`, `context{dependentObjects, sourceMetadata, consumerProfiles, businessRules,
   securityRules, openDecisions}`, `options`) and produces an output (`status`, `classification`,
   `artifacts`, `analysis{ruleLedger, constructInventory, securityFindings, warnings,
   manualReviewItems, stopCodes}`, `validation{checklist, executedChecks, unexecutedChecks}`) with
   the run id and generation time. Tools write it; the model explains it [GOV-01, GOV-02].
2. **[G-2] Four statuses, escalating only.** `GENERATED` (complete, statically checked),
   `PARTIAL` (gaps flagged with `-- TODO: MANUAL REVIEW REQUIRED`), `BLOCKED` (a decision or
   metadata is missing), `VALIDATED` (execution evidence on a test target; **not** production
   approval). A status never goes down within a run [GOV-03].
3. **[G-3] Stop codes name the missing decision**, never a guess: `INVALID_INPUT`,
   `INVALID_SOURCE_DIALECT`, `TARGET_DECISION_REQUIRED`, `METADATA_NOT_FOUND`,
   `METADATA_AMBIGUOUS`, `METADATA_SOURCE_UNAVAILABLE`, `METADATA_STALE`, `DEPENDENCY_UNRESOLVED`,
   `SECURITY_MAPPING_REQUIRED`, `UNSUPPORTED_CONSTRUCT`, `UNSAFE_CAST_REVIEW_REQUIRED`,
   `CONTRACT_COLLISION`, `RENAME_COLLISION`, `TARGET_SCHEMA_DECISION_REQUIRED`,
   `STATIC_VALIDATION_FAILED`, `SEMANTIC_VALIDATION_FAILED`, `PRODUCTION_WRITE_DENIED`. When a tool
   emits one, the agent asks the user the corresponding question [GOV-04].
4. **[G-4] Placement before translation (M2RVE).** Every object gets a role — `LEFT_EDGE` (source
   table), `MIDDLE` (transformation consumed by other objects: materialise), `RIGHT_EDGE`
   (consumer-facing view: keep as a view), `ELIMINATE` (projection-only or updatable view),
   `REVIEW` — a complexity `L1–L4` and a review tier `T1–T3` (security-bearing or `L4` is always
   `T3`). The target platform is a decision of the user, informed by the candidates and blockers
   the assessment lists [GOV-05, GOV-06].
5. **[G-5] Every non-trivial transformation has a ledger row** (`rule`, `sourceFeature`,
   `targetTreatment`, `reason`, `manualReview`) so a reviewer can accept or reject each one; "kept
   as is" is also a row when the construct looked suspicious [GOV-07].
6. **[G-6] Validation is a manifest, not a claim.** Checks `V-001…V-040` (input, provenance,
   dependency, syntax, structure, types, nullability, defaults, constraints, row counts, key
   sets, duplicates, nulls, numerics, dates, joins, filters, aggregates, windows, recursion, MERGE,
   CDC, spatial, RLS positive/negative, CLS, revocation, plan, runtime, pruning, idempotency,
   failure recovery, audit, standards, consumer, deployment, rollback, approval) are listed as
   applicable, executed with evidence, or **unexecuted** — never silently passed [GOV-08].
7. **[G-7] Seven gates.** G1 intake (contract valid) → G2 discovery (metadata grounded, schema
   snapshot) → G3 placement (role, target, tier) → G4 generation (code + ledger) → G5 static
   validation (linters clean, references resolve) → G6 execution evidence (test target only) →
   G7 review (package, approvals). A gate that cannot be passed produces a stop code, not a
   workaround [GOV-09].
8. **[G-8] Done means packaged.** `request.json`, `output.json`, `rule-ledger.md`,
   `validation-manifest.json`, every generated file and `manifest.json` with SHA-256 hashes and the
   run id, written by the tool (`contract.write_package`). Packages are deterministic apart from
   run metadata [GOV-10, GOV-11].
9. **[G-9] Metadata is authoritative or absent.** Datatypes, column lists and dependencies come
   from DDL snapshots, live catalogs (test databases only) or the Glue Data Catalog with
   provenance; they are never inferred from names or prose [GOV-12].
10. **[G-10] Production is out of reach.** No skill applies DDL, patches or loads to a
    non-test target; execution evidence comes only from databases whose name contains
    test/dev/sandbox/local; deployment goes through the normal release path with the package as
    evidence.

## Intake questions the agent asks (only the unanswered ones)

1. **Consumer:** application, API, BI/reporting, ETL, unknown?
2. **Approved target:** Aurora PostgreSQL, Amazon Redshift, Iceberg on S3 (Athena/Glue/Spark), or undecided?
3. **Consumer contract:** must column names, order and types stay identical?
4. **Metadata:** is a schema snapshot or a live test catalog available?
5. **Security:** does the object use identity functions or authorization tables; is the identity mapping approved?
6. **Load semantics:** full refresh, incremental/MERGE, CDC?
7. **Test target:** which test database / workgroup may execute the evidence run?
8. **Review tier override:** is a higher tier required by policy?
