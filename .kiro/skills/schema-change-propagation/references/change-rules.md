# Rule catalog: table and column change propagation

Governed handling of table/column renames and datatype changes in a converted target flow.
Each row is proven by `scripts/tests/test_change_tool.py` (`[CP-nn]` tags);
`check_rule_coverage.py --catalog references/change-rules.md --prefix CP` fails the self-test
otherwise. Steering: `.kiro/steering/schema.md` (change section) and `governance.md`.

## Intake and validation

| ID | Rule | Test |
|---|---|---|
| CP-01 | change templates (CSV or XLSX) are ingested with normalised headers (case, whitespace, blanks) and a recorded checksum; no value is altered | auto |
| CP-02 | required fields per change type are checked (`RENAME_COLUMN`, `CAST_COLUMN`, `RENAME_TABLE`, `ADD_COLUMN`, `DROP_COLUMN`); missing → `INVALID_INPUT` | auto |
| CP-03 | duplicate rows and conflicting rows (same column, different instructions) are reported | auto |
| CP-04 | two rows mapping to the same new name in one table → `RENAME_COLLISION` before any generation | auto |
| CP-05 | blank `Current_Datatype` is resolved only from an authoritative snapshot (provenance recorded); otherwise `BLOCKED` with `METADATA_NOT_FOUND` and no cast-safety claim | auto |
| CP-06 | blank `New_Schema` resolves only through the approved policy (`retain_current_schema`); otherwise `TARGET_SCHEMA_DECISION_REQUIRED` | auto |
| CP-07 | layers: objects in protected layers (source, lookup) are never edited; change rows targeting them are refused; editable scope is an explicit allowlist | auto |

## Cast safety and planning

| ID | Rule | Test |
|---|---|---|
| CP-10 | cast-safety matrix: `SAFE` (widening), `LOSSY` (narrowing, precision, time-zone loss), `UNSUPPORTED`, `HIGH_RISK` (descriptive/date-like text → numeric, numeric → boolean) | auto |
| CP-11 | `HIGH_RISK` casts need data evidence (`--profile`) and a reviewer disposition: without them the plan is `PARTIAL` with `UNSAFE_CAST_REVIEW_REQUIRED`; no silent default | auto |
| CP-12 | overflow / parse failures from the data profile are quantified with representative keys; generation blocked unless an approved rule (`on_failure`) exists | auto |
| CP-13 | original nulls and cast-induced nulls are reported separately | auto |
| CP-14 | ordered plan: every cast references the current column and happens before the rename; table renames come last; each operation links to its template row | auto |
| CP-15 | propagation: dependencies in the target flow (projections, views, jobs, tests) that reference the changed identifiers are listed with the file and line | auto |

## Patching, validation, package

| ID | Rule | Test |
|---|---|---|
| CP-20 | token-aware edits: only identifier tokens (not comments, strings or similar names) in editable files are changed; column edits only in statements that reference the table; a unified diff is produced | auto |
| CP-21 | protected-layer diff is clean: files outside the editable scope are byte-identical after patching | auto |
| CP-22 | residual scan: old identifiers left in the editable scope are listed; explained residues (comments, rollback notes) are separated from unexplained ones | auto |
| CP-23 | rollback notes: reverse operations (rename back, cast back with loss warning) generated for every operation | auto |
| CP-24 | idempotent regeneration: same inputs, snapshot and policy → identical plan and patches (hashes), apart from run metadata | auto |
| CP-25 | production-write protection: the tool never applies patches; an apply request is refused with `PRODUCTION_WRITE_DENIED` and audited | auto |
| CP-26 | package: request/output contracts, plan, ledger row per template row, patches, diff, residual scan, validation manifest (`V-004`, `V-006`, `V-012`, `V-013`, `V-033`, `V-039`) | auto |
