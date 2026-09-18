# Governance catalog: contracts, statuses, stop codes, ledger, package (migkit)

`scripts/migkit/contract.py` and `scripts/migkit/ddl.py` implement the governance layer every
conversion skill uses. Every row is proven by `scripts/tests/test_migkit.py` (`[GOV-nn]` tags);
`check_rule_coverage.py --catalog references/governance.md --prefix GOV` fails the self-test
otherwise. The rules follow the kit's SQL conversion governance model
(universal contracts, seven gates, statuses, stop codes, rule ledger, evidence package,
validation catalog V-001…V-040) adapted to a Kiro workspace.

| ID | Rule | Implementation | Test |
|---|---|---|---|
| GOV-01 | **Universal input contract** is validated before analysis: `requestId`, `source.platform` (SQLServer/Oracle), `source.objectType`, `source.objectName`, `source.definition`, `target.platform`; violations return stable, sorted diagnostics with stop codes | `contract.validate_request` | auto |
| GOV-02 | **Undecided target blocks generation**: `target.platform` TBD/undecided → `TARGET_DECISION_REQUIRED`; the assessment skill decides placement first | `contract.validate_request` | auto |
| GOV-03 | **Statuses** are `GENERATED`, `PARTIAL`, `BLOCKED`, `VALIDATED`; they only escalate (GENERATED→PARTIAL→BLOCKED); `VALIDATED` is never production approval | `contract.set_status` | auto |
| GOV-04 | **Stop codes** are a closed catalog (INVALID_INPUT … PRODUCTION_WRITE_DENIED); unknown codes are rejected | `contract.STOP_CODES` | auto |
| GOV-05 | **Review tier** derives from complexity and security: L1→T1, L2→T2, L3/L4 or security-bearing→T3; an explicit override wins | `contract.review_tier` | auto |
| GOV-06 | **Rule ledger**: one row per non-trivial transformation (rule id, source feature, target treatment, reason, evidence required, manual flag), rendered to JSON and Markdown | `contract.RuleLedger` | auto |
| GOV-07 | **Validation manifest**: applicable checks come from the V-001…V-040 catalog; a check that was not executed is listed as unexecuted with its evidence requirement and is never marked passed | `contract.validation_manifest` | auto |
| GOV-08 | **Conversion package**: request, output, ledger, validation manifest and artifact files are written with SHA-256 hashes, run id and kit version; the same inputs produce byte-identical artifacts (idempotent regeneration) | `contract.write_package` | auto |
| GOV-09 | **DDL grounding never guesses**: CREATE TABLE parsing captures ordinal, native datatype (length/precision/scale), nullability, default, identity, computed columns, constraints, indexes, distribution and partition specs; anything unparsed goes to `unresolved` | `ddl.parse_tables` (tsql, postgres, redshift, spark) | auto |
| GOV-10 | **Construct inventory ignores comments and literals**, so a keyword in a comment is not a construct; it flags heavy constructs (recursive CTE, MERGE, dynamic SQL, cursors, spatial, linked servers …) and security-bearing functions separately | `ddl.inventory` | auto |
| GOV-11 | **Dependency discovery** lists defined and referenced objects, temp tables and unresolved four-part names; aliases, CTE names, cursors and system procedures are not dependencies | `ddl.references` | auto |
| GOV-12 | **Skill routing by target**: AuroraPostgreSQL→`sql-conversion`, Redshift→`sql-conversion-redshift`, Iceberg/Glue/Spark→`sql-conversion-iceberg` | `contract.SKILL_FOR_TARGET` | auto |
