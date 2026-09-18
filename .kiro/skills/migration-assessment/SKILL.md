---
name: migration-assessment
description: Assess, classify and route SQL Server objects before any conversion - construct and dependency inventory, security-bearing SQL detection, M2RVE placement (Materialize the Middle, Retain Views on the Edge), complexity L1-L4, review tier T1-T3, target platform candidates (Aurora PostgreSQL, Amazon Redshift, Apache Iceberg on S3 with Glue) and the conversion skill to use; validates the universal request contract and audits the migration log. Use when asked to assess, classify, inventory, scope, plan or choose a target for a migration, when the target platform is undecided, or when asked "which skill should convert this".
license: Apache-2.0
metadata:
  version: "1.0"
  gates: "G1 intake, G2 discovery, G3 placement of the seven-gate governance workflow"
---

# Migration assessment: classify before you translate

This skill is the front door of every migration. It decides **what an object is, who consumes it,
where it should live and which conversion skill applies**, and it turns missing decisions into
questions for the user instead of assumptions. Rules: `.kiro/steering/governance.md` (contracts,
statuses, stop codes, placement matrix). Catalog: `references/placement-matrix.md` (`MA-nn`).

The tool is deterministic (`scripts/assess_tool.py`, standard-library Python, no database needed).
The model's job is to explain the result, ask the open questions, and record the answers.

## When to use it

- The user asks to migrate something but has not said **where** (Aurora PostgreSQL, Redshift,
  Iceberg) or **for whom** (application, BI, ETL).
- Before converting a view chain, a stored procedure with data movement, or anything security-bearing.
- To produce the intake inventory of a folder (`source/`) and check the migration log.

## Procedure

### Step 1: Ask the intake questions (only the ones still unanswered)
```bash
python3 .kiro/skills/migration-assessment/scripts/assess_tool.py questions
```
Consumer, approved target, consumer contract, metadata availability, security, load semantics,
test database, review tier. Put the answers into the request (`--consumer`, `--target`,
`--security-rules`).

### Step 2: Assess the object or folder
```bash
python3 .kiro/skills/migration-assessment/scripts/assess_tool.py assess source/usp_X.sql --consumer app --target AuroraPostgreSQL --out generated/assessment
python3 .kiro/skills/migration-assessment/scripts/assess_tool.py assess source --consumer bi --out generated/assessment
```
For each object you get `classification.json` (universal output contract) and `assessment.md`:
- construct inventory (comments and literals ignored) with heavy constructs, dependencies,
  temp tables and unresolved four-part names [MA-01, MA-02];
- security findings: identity functions, authorization joins, masking, impersonation [MA-03];
- role (M2RVE): `LEFT_EDGE` source table, `MIDDLE` transformation consumed by other objects,
  `RIGHT_EDGE` consumer-facing, `ELIMINATE` projection-only or updatable view, `REVIEW` [MA-04];
- complexity L1–L4 and review tier T1–T3 [MA-05];
- target candidates with rationale and **blockers** (for example cursors block Redshift,
  triggers block everything but Aurora) and the skill for the chosen target [MA-06, MA-07];
- status: `GENERATED` when a feasible target is chosen, `PARTIAL` when the chosen target has
  blockers, `BLOCKED` with `TARGET_DECISION_REQUIRED` or `SECURITY_MAPPING_REQUIRED` [MA-08].

### Step 3: Resolve the open questions with the user
Read `analysis.manualReviewItems`. Do not guess a consumer, a target or an identity mapping.
When the user answers, rerun with the flags; the status changes from BLOCKED to GENERATED and
`assessment.recommendedSkill` names the next skill:

| Target decision | Skill |
|---|---|
| AuroraPostgreSQL | `sql-conversion` (procedures, functions, triggers, DDL) |
| Redshift | `sql-conversion-redshift` (edge views, set-based loads, DDL) |
| Iceberg / GluePySpark / SparkSQL | `sql-conversion-iceberg` (tables, Spark SQL, Glue jobs) |
| reports on any target | `sql-reporting` |
| PowerCenter XML | `informatica-etl-conversion` |

### Step 4: Ground the schema
For tables and for any object whose columns must match a consumer contract, run
`schema-conformance` (`schema_tool.py snapshot`) so the conversion works from an authoritative,
hashed snapshot rather than from prose.

### Step 5: Hand over
Attach the assessment folder to the conversion request; the conversion skill copies the
classification into its package. Keep the run id.

## Other commands
```bash
python3 …/assess_tool.py inventory source                       # every file, complexity, log status; audits metadata/migration_log.json
python3 …/assess_tool.py validate request.json                  # universal input contract → diagnostics + stop codes
```

## Guardrails and audit
Inputs are scanned (prompt injection, hidden characters, credentials) and findings are reported,
never followed. Files over the size limit are refused (exit 3). Every command writes correlated
audit records (`assess.object`, `assess.inventory`, `assess.validate`) under the run id.

## Verify the skill itself
`bash .kiro/skills/migration-assessment/scripts/run_skill_tests.sh` (Windows:
`.kiro\skills\migration-assessment\scripts\run_skill_tests.cmd`): unit tests on fixtures for every
`MA-nn` row, plus a run over this project's `source/` folder. No database needed.
