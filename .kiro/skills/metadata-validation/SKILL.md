---
name: metadata-validation
description: PLANNED, not yet implemented. Future skill to audit metadata/migration_log.json against source/, generated/ and tests/ (missing entries, stale test status, unacknowledged manual-review flags). Use only when the user asks about the metadata-validation roadmap.
metadata:
  version: "0.1"
  status: "planned"
---

# Skill: metadata-validation (planned)

**Status:** planned. Tell the user this skill is not implemented yet. Do not attempt
the audit below unless the user explicitly asks you to build it.

## Intended purpose

Keep `metadata/migration_log.json` truthful:
- every proc in `source/*.sql` has an entry, and every function in `generated/*.sql`
  maps back to one
- every `"manual_review": true` entry has a matching
  `-- TODO: MANUAL REVIEW REQUIRED` comment in the generated file, and vice versa
- every entry's `test_suite` exists in `tests/test_cases.sql`
- `summary` counts equal the entries, and `last_test_run` is up to date

## Planned steps

1. List procs in `source/` (`CREATE PROCEDURE|FUNCTION`) and routines in `generated/`.
2. Load `metadata/migration_log.json` and diff it against both lists.
3. Grep generated files for `TODO: MANUAL REVIEW REQUIRED` and compare with the flags.
4. Write `metadata/audit_report.md` with the findings and suggested fixes.

## Log entry shape (current)

See any entry under `files[].procedures[]` in `metadata/migration_log.json`:
`source_name`, `target_name`, `type`, `target_version`, `conversion_status`,
`manual_review`, `test_suite`, `notes[]`.
