# Rule catalog: schema gap analysis and conformance

Each row is proven by `scripts/tests/test_schema_tool.py` (`[SC-nn]` tags);
`check_rule_coverage.py --catalog references/conformance-rules.md --prefix SC` fails the self-test
otherwise. Steering: `.kiro/steering/schema.md`.

## Snapshots

| ID | Rule | Test |
|---|---|---|
| SC-01 | canonical snapshot from DDL (T-SQL, PostgreSQL, Redshift, Spark/Athena Iceberg): tables, columns (base, length, precision, scale, nullable, default, identity, ordinal), keys, indexes; provenance (file, dialect, sha256, capturedAt, runId, method) and a content hash independent of capture time | auto |
| SC-02 | live PostgreSQL snapshot from `information_schema` (+ `pg_catalog` for identity/defaults): read-only, database name must contain test/dev/sandbox/local, IAM token generated per run and never logged | auto |
| SC-03 | Glue Data Catalog snapshot (`glue get-tables`) with Iceberg table properties | auto |
| SC-04 | unparsed table items or unknown types become `UNVERIFIED` columns/tables, never guessed | auto |

## Classification

| ID | Rule | Test |
|---|---|---|
| SC-10 | `EXACT`: same normalised name, same base type, length/precision/scale and nullability | auto |
| SC-11 | `APPROVED_TRANSFORM`: target type in the profile allowlist (`aurora`, `redshift`, `iceberg`), name conforming to the naming profile; ledger reason recorded | auto |
| SC-12 | `MISSING_TARGET`: source column absent from the target (after naming/mapping) | auto |
| SC-13 | `MISSING_SOURCE`: target column absent from the source; technical columns (`_run_id`, `_loaded_at`, ignore list) are `APPROVED_TRANSFORM` | auto |
| SC-14 | `CONFLICT` type: target type not in the allowlist (e.g. `TEXT` on Redshift, `varchar(n)` on Iceberg, `INT` for a `BIGINT`) | auto |
| SC-15 | `CONFLICT` narrowing: shorter length, lower precision, different scale; `MAX`/`TEXT` targets need `text`/`varchar(65535)`/`string` | auto |
| SC-16 | nullability: tightened (`NULL` → `NOT NULL`) is `CONFLICT`; relaxed is `APPROVED_TRANSFORM` with a warning (Athena Iceberg DDL always relaxes) | auto |
| SC-17 | keys: PK/UNIQUE column sets compared; missing/different keys are `CONFLICT` on Aurora and `APPROVED_TRANSFORM` (informational, validated by `V-014`) on Redshift/Iceberg | auto |
| SC-18 | identity, defaults and computed columns: differences recorded as `APPROVED_TRANSFORM` notes ("applied by the load job" on Iceberg) | auto |
| SC-19 | tables: missing in target → `MISSING_TARGET` table; extra in target → `MISSING_SOURCE` table | auto |
| SC-20 | naming profile `snake_case` (default) or `preserve`; explicit `mapping.json` overrides for tables and columns; unmapped renames are reported, never guessed | auto |
| SC-21 | column order differences reported against the consumer contract (`V-005`) even when all columns conform | auto |
| SC-22 | status and stop codes: `CONFLICT` → `BLOCKED` + `TARGET_SCHEMA_DECISION_REQUIRED`; `MISSING_TARGET` → `PARTIAL` + `STATIC_VALIDATION_FAILED`; `UNVERIFIED` → `PARTIAL` + `METADATA_AMBIGUOUS`; clean → `GENERATED`; live target → `VALIDATED` | auto |

## Conformance, references, reporting

| ID | Rule | Test |
|---|---|---|
| SC-30 | `conform` writes dry-run proposals in the target dialect (`ADD COLUMN`, widen `varchar`/`numeric`, `-- DECISION` comments for conflicts); never executed | auto |
| SC-31 | `refs`: every `schema.object` read or written by converted code exists in the target snapshot; otherwise `DEPENDENCY_UNRESOLVED` | auto |
| SC-32 | `compare.md` report (summary counts, per-table matrix, decisions) and `compare.json` with both snapshot hashes | auto |
| SC-33 | package: universal output contract, validation manifest (`V-005`, `V-006`, `V-007`, `V-008`, `V-009`, `V-010`), audit records under the run id | auto |
| SC-40 | project regression: `source/schema` vs `generated/schema.sql` conforms with the `aurora` profile; a live Aurora/PostgreSQL target is compared when `PGHOST`/`PGDATABASE` (test database) are configured | auto |
