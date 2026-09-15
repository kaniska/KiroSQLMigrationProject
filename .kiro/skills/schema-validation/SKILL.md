---
name: schema-validation
description: PLANNED, not yet implemented. Future skill to validate converted PostgreSQL DDL and functions against the target schema (tables, columns, types, keys). Use only when the user asks about the schema-validation roadmap; for conversions use the sql-conversion skill.
metadata:
  version: "0.1"
  status: "planned"
---

# Skill: schema-validation (planned)

**Status:** planned. Tell the user this skill is not implemented yet. Do not attempt
the validation steps below unless the user explicitly asks you to build it.

## Intended purpose

Prove that `generated/` matches the target schema before tests run:
- every table and column referenced by a function exists in `generated/schema.sql`
- every `RETURNS TABLE` column type matches the base type of the expression returned
- keys, uniqueness and nullability survive the conversion (for example, an
  unfiltered SQL Server UNIQUE on a nullable column needs `UNIQUE NULLS NOT DISTINCT`)
- no function name is defined twice across `generated/*.sql`

## Building blocks already in the project

- `source/schema/*.sql` (T-SQL DDL) and `generated/schema.sql` (converted DDL)
- `.kiro/skills/sql-conversion/scripts/lib/static_checks.sql` — duplicate names, leftover
  T-SQL, COMMIT in functions, STABLE/IMMUTABLE misuse, money columns (reuse its approach)
- `plpgsql_check` (if available on the target) can statically verify column
  references inside function bodies
- The validation checklist in `.kiro/steering/migration.md`

## Planned steps

1. Load `generated/schema.sql` into a scratch database (or read `information_schema`).
2. Parse every `CREATE OR REPLACE FUNCTION/PROCEDURE` in `generated/`.
3. Cross-check table/column references and types; report file:line and a fix.
4. Record `"schema_validated": true|false` per object in `metadata/migration_log.json`.
