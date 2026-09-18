---
inclusion: always
---

# Schema Gap Analysis and Conformance — Rules

Rules for proving that a target schema (Aurora PostgreSQL, Amazon Redshift, Apache Iceberg)
conforms to its SQL Server source before code is converted against it and before data is
loaded. They complement `governance.md` (contracts, statuses, stop codes) and the per-target
steering files (`migration.md`, `redshift.md`, `iceberg.md`). Implemented by
`.kiro/skills/schema-conformance/SKILL.md`; rule catalog `SC-nn` in that skill's
`references/conformance-rules.md`. Rule ids `[S-n]`.

## Hard rules

1. **[S-1] Schemas are compared as snapshots, not as prose.** A snapshot is a canonical JSON
   document (tables → columns with base type, length, precision, scale, nullability, default,
   identity, ordinal; keys; indexes) with provenance (source file or database, dialect, SHA-256,
   capture time, run id). Snapshots come from DDL parsing, from a live PostgreSQL
   `information_schema` (test databases only), or from the Glue Data Catalog [SC-01…SC-04].
2. **[S-2] Every column gets exactly one classification:** `EXACT`, `APPROVED_TRANSFORM` (type
   in the target profile's allowlist, name conforming to the naming profile), `MISSING_TARGET`,
   `MISSING_SOURCE`, `CONFLICT` (unapproved type, narrowing, tightened nullability, key
   differences on an enforcing target) or `UNVERIFIED` (unparsed or ambiguous metadata). Nothing
   is silently accepted [SC-10…SC-19].
3. **[S-3] Names follow the naming profile** (`snake_case` by default: `[dbo].[OrderLine]` ↔
   `public.order_line`), with explicit overrides in a mapping file; unmapped renames are
   `MISSING_TARGET` + `MISSING_SOURCE`, never guessed [SC-20].
4. **[S-4] Consumer contracts include column order.** Order differences are reported (`V-005`)
   even when every column conforms [SC-21].
5. **[S-5] Statuses and stop codes are deterministic:** any `CONFLICT` → `BLOCKED`
   (`TARGET_SCHEMA_DECISION_REQUIRED`); any `MISSING_TARGET` → `PARTIAL`
   (`STATIC_VALIDATION_FAILED`); any `UNVERIFIED` → `PARTIAL` (`METADATA_AMBIGUOUS`); otherwise
   `GENERATED`, and `VALIDATED` only when the target snapshot came from a live catalog [SC-22].
6. **[S-6] Conformance fixes are proposals.** `conform` writes dry-run DDL (`ADD COLUMN`, type
   widening, comments for decisions) in the target dialect; nothing is executed by the skill
   [SC-30].
7. **[S-7] Converted code is checked against the target snapshot:** every `schema.object` it
   reads or writes must exist, otherwise `DEPENDENCY_UNRESOLVED` [SC-31].
8. **[S-8] Live access is read-only and gated:** database names must contain
   test/dev/sandbox/local; IAM tokens are generated per run and never logged; only
   `information_schema`/catalog views are queried [SC-02, SC-40].
9. **[S-9] Done means packaged:** `compare.json`, `compare.md`, the two snapshots and the
   universal output contract with hashes and the run id [SC-32, SC-33].

## Change propagation (renames and casts after conversion)

Implemented by `.kiro/skills/schema-change-propagation/SKILL.md` (rules `CP-nn`).

10. **[S-10] Changes arrive as a template, not as prose.** CSV/XLSX rows (`Change_Type`,
    `Current_Schema/Table/Column/Datatype`, `New_Schema/Table/Column/Datatype`, `Layer`,
    `Justification`) are ingested with a checksum; blank current datatypes come from an
    authoritative snapshot or the request is `BLOCKED` (`METADATA_NOT_FOUND`); blank target
    schemas resolve only through the approved policy [CP-01…CP-06].
11. **[S-11] Layers are protected.** Source and lookup objects are never edited; the editable
    scope is an explicit allowlist of objects and files [CP-07, CP-21].
12. **[S-12] Cast before rename.** Every cast references the current column; renames follow;
    table renames come last; each operation links to its template row; high-risk casts (text →
    numeric, numeric → boolean, overflow) need data evidence and a reviewer disposition
    [CP-10…CP-15].
13. **[S-13] Edits are token-aware and dry-run.** Only identifier tokens of the target object
    change (never comments, literals, aliases of protected objects or similar names); the output is
    a diff, a migration script and a rollback script; nothing is applied (`PRODUCTION_WRITE_DENIED`)
    [CP-20…CP-25].

## Target profiles (type allowlists)

| SQL Server | Aurora PostgreSQL | Amazon Redshift | Iceberg |
|---|---|---|---|
| `INT` / `BIGINT` / `SMALLINT` | `integer` / `bigint` / `smallint` | same | `int` / `bigint` / `int` |
| `TINYINT` | `smallint`, `integer` | `smallint` | `int` |
| `BIT` | `boolean` | `boolean` | `boolean` |
| `DECIMAL(p,s)` / `MONEY` | `numeric(p,s)` / `numeric(19,4)` | `decimal(p,s)` / `decimal(19,4)` | `decimal(p,s)` / `decimal(19,4)` |
| `FLOAT` / `REAL` | `double precision` / `real` | `double precision` / `real` | `double` / `float` |
| `CHAR`/`NCHAR` | `char(n)`, `varchar` | `char(n)`, `varchar` | `string` |
| `VARCHAR`/`NVARCHAR`/`TEXT` | `varchar(≥n)`, `text` | `varchar(≥n)` (never bare `text`) | `string` |
| `DATE` / `TIME` | `date` / `time` | `date` / `time` | `date` / `string` |
| `DATETIME*` | `timestamp` | `timestamp` | `timestamp` |
| `DATETIMEOFFSET` | `timestamptz` | `timestamptz` | `timestamp` |
| `UNIQUEIDENTIFIER` | `uuid`, `varchar(36)` | `varchar(36)`, `char(36)` | `string` |
| binary / `ROWVERSION` | `bytea` | `varbyte` | `binary` |
| `XML` | `xml`, `text` | `super`, `varchar` | `string` |
| `GEOGRAPHY` | `geography`, `geometry` | `geography`, `geometry` | `binary`, `string` |

## Validation checklist

- [ ] source and target snapshots captured with provenance hashes *(auto)*
- [ ] `compare` reports no `CONFLICT`; every `MISSING_*` has a decision *(auto)*
- [ ] naming profile and mapping file recorded in the package
- [ ] converted code references resolve against the target snapshot *(auto)*
- [ ] live target snapshot used before `VALIDATED`
