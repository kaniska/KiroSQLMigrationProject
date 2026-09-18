---
name: schema-conformance
description: Source-versus-target schema gap analysis and conformance for SQL Server migrations to Aurora PostgreSQL, Amazon Redshift or Apache Iceberg - canonical schema snapshots from DDL, a live PostgreSQL information_schema (test databases only) or the Glue Data Catalog; per-column classification EXACT / APPROVED_TRANSFORM / MISSING_SOURCE / MISSING_TARGET / CONFLICT / UNVERIFIED with per-target type allowlists, naming profiles and mapping overrides; key, nullability and column-order checks; dry-run conformance DDL; reference validation of converted code; conformance report and package. Use when asked to compare schemas, find schema gaps or drift, validate that converted DDL matches the source, check that converted code references existing objects, or before loading data into a target.
license: Apache-2.0
metadata:
  version: "1.0"
  targets: "Aurora PostgreSQL · Amazon Redshift · Apache Iceberg (Athena / Glue / Spark)"
  gates: "G2 discovery (metadata grounding) and G5 static validation of the seven-gate governance workflow"
---

# Schema gap analysis and conformance

Conversions are only as good as the schema they target. This skill turns schemas into **hashed
snapshots**, compares them column by column with the approved type allowlist of the target, and
reports every gap as a decision, never as a guess. Rules: `.kiro/steering/schema.md`
(`[S-1]…[S-9]`) and `.kiro/steering/governance.md`. Catalog: `references/conformance-rules.md`
(`SC-01…SC-40`, every row proven by a tagged test).

`scripts/schema_tool.py` is deterministic standard-library Python (shared engine: the
`sql-conversion` skill's `migkit` DDL parser). The model reads the report, asks for the decisions
and records them in the mapping file; it never edits classifications by hand.

## Procedure

### Step 1: Snapshot both sides
```bash
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot source/schema --dialect tsql --out generated/schema/source.snapshot.json
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot generated/schema.sql --dialect pgsql --out generated/schema/target.snapshot.json
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot generated/redshift/tables.sql --dialect redshift --out generated/schema/redshift.snapshot.json
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot generated/iceberg/tables.spark.sql --dialect spark --out generated/schema/iceberg.snapshot.json
```
Live targets (read-only, database name must contain test/dev/sandbox/local, IAM token per run):
```bash
PGDATABASE=sql_migration_test PG_IAM_AUTH=1 python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot --live --schema public --out generated/schema/live.snapshot.json
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot --glue --database sales_lake_dev --out generated/schema/glue.snapshot.json
```
A snapshot records provenance (file or database, dialect, SHA-256, capture time, run id) and a
content hash; unparsed items are listed under `unverified` and later classified `UNVERIFIED` [SC-01…SC-04].

### Step 2: Compare with the target profile
```bash
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py compare generated/schema/source.snapshot.json generated/schema/target.snapshot.json --profile aurora --out generated/schema/compare
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py compare … --profile redshift --mapping mapping.json --ignore-columns _run_id,_loaded_at --out generated/schema/compare-redshift
```
`mapping.json` holds explicit renames (`{"tables": {"dbo.OrderLines": "public.order_lines"},
"columns": {"dbo.Orders": {"OrderDt": "order_date"}}}`); everything else follows the naming profile
(`snake_case` default, `preserve`) [SC-20]. Read `compare.md`:

| Class | Meaning | What to do |
|---|---|---|
| `EXACT` | same name (per profile), type, size, nullability | nothing |
| `APPROVED_TRANSFORM` | type in the allowlist (`NVARCHAR`→`VARCHAR`, `BIT`→`BOOLEAN`, `MONEY`→`NUMERIC(19,4)` …), relaxed nullability, identity/default applied by the load, technical column | confirm the ledger note |
| `MISSING_TARGET` | source column/table absent | add it (`conform`) or record the decision to drop |
| `MISSING_SOURCE` | target column/table without a source | document or drop |
| `CONFLICT` | unapproved type, narrowing, tightened nullability, key difference on Aurora | decision required |
| `UNVERIFIED` | unparsed or ambiguous metadata | fetch better metadata (live snapshot) |

Keys are compared as column sets (`CONFLICT` on Aurora, informational on Redshift/Iceberg with a
`V-014` uniqueness query), and column-order differences are reported for the consumer contract
(`V-005`) [SC-10…SC-21]. Status: any `CONFLICT` → `BLOCKED` (`TARGET_SCHEMA_DECISION_REQUIRED`);
`MISSING_TARGET` → `PARTIAL` (`STATIC_VALIDATION_FAILED`); `UNVERIFIED` → `PARTIAL`
(`METADATA_AMBIGUOUS`); clean → `GENERATED`, or `VALIDATED` when the target came from a live
catalog [SC-22].

### Step 3: Propose the fixes (dry run) and resolve decisions
```bash
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py conform generated/schema/compare/compare.json --source generated/schema/source.snapshot.json --out generated/schema/compare/conform.sql
```
`conform.sql` contains `ALTER TABLE … ADD COLUMN`, type widening in the target dialect and
`-- DECISION` lines for conflicts. It is never executed by this skill: review it, then apply it
through the normal deployment path (`sql-conversion` for Aurora, the Redshift/Iceberg skills
otherwise) [SC-30]. Put every accepted rename into `mapping.json` and rerun `compare`.

### Step 4: Check converted code against the target
```bash
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py refs generated --target generated/schema/target.snapshot.json
```
Every `schema.object` read or written by the converted code must exist in the snapshot; otherwise
`DEPENDENCY_UNRESOLVED` [SC-31].

### Step 5: Package
```bash
python3 .kiro/skills/schema-conformance/scripts/schema_tool.py package generated/schema/compare/compare.json --out generated/schema/pkg
```
Universal output contract with the validation manifest (`V-005` order, `V-006` types, `V-007`
nullability, `V-009` keys, `V-010` indexes), `compare.json`, `compare.md`, hashes and run id [SC-32, SC-33].

## Guardrails and audit
- DDL inputs are scanned (`SEC-01…03`) and size-limited before parsing; refusals exit 3.
- Live snapshots are read-only (`default_transaction_read_only`), only on test databases, only
  `information_schema`/catalog views; the IAM token is generated per run and never logged; Glue
  snapshots are read-only `get-tables` calls through the kit's AWS layer.
- Every command writes correlated audit records under the run id (`schema.snapshot`,
  `schema.compare`, `schema.conform`, `schema.refs`, `schema.package`).

## Verify the skill itself
`bash .kiro/skills/schema-conformance/scripts/run_skill_tests.sh` (Windows:
`.kiro\skills\schema-conformance\scripts\run_skill_tests.cmd`): unit tests on fixtures for every
`SC-nn` row, the project regression `source/schema` vs `generated/schema.sql` (must be `GENERATED`
with 0 conflicts), the Glue path against the stub AWS CLI, and — when `PGHOST`/`PGDATABASE` point
at a test database (as `supporting-files/run_tests.sh` sets them) — a live Aurora/PostgreSQL
snapshot compared with the source.
