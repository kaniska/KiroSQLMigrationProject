# Placement matrix and assessment rules

Every `auto` row is proven by `scripts/tests/test_assess_tool.py` (`[MA-nn]` tags);
`check_rule_coverage.py --catalog references/placement-matrix.md --prefix MA` fails the self-test
otherwise. The placement logic follows the positioning matrix (Materialize the Middle, Retain
Views on the Edge) and the seven-gate workflow (gates G1–G3).

## Positioning matrix (source role → default target candidates)

| Source role | Default target candidate | Skill | Decision notes |
|---|---|---|---|
| Raw source table | Iceberg (RDP) · Aurora PostgreSQL table | `sql-conversion-iceberg` · `sql-conversion` | lake-first entry point; Aurora when transactional / low-latency |
| Intermediate transformation view (MIDDLE) | Iceberg DDP built by a Glue job · materialized view | `sql-conversion-iceberg` | joins, aggregation, window logic, fan-in, consumed by other objects |
| Application / API edge view | Aurora PostgreSQL regular view | `sql-conversion` | over materialized foundations |
| BI / reporting edge view | Redshift regular or late-binding view | `sql-conversion-redshift` | over Redshift / Spectrum foundations |
| Projection-only convenience view | ELIMINATE or governed access | — | needs consumer and access review |
| Updatable view | ELIMINATE write-through | — | redirect writes to tables; keep a read interface |
| Finished operational product | Aurora table | `sql-conversion` | transactional behaviour |
| Finished analytical product | Redshift table | `sql-conversion-redshift` | curated analytical workloads |
| Procedural routine (procedure, function) | Aurora PostgreSQL PL/pgSQL · Redshift stored procedure (set-based only) | `sql-conversion` · `sql-conversion-redshift` | Redshift: no table functions, cursors only to return results, no triggers |
| Data-movement routine (insert-select, MERGE, truncate-load) | Glue PySpark job → Iceberg · Redshift stored procedure | `sql-conversion-iceberg` · `sql-conversion-redshift` | needs load semantics (full / append / merge, key, watermark) |
| Trigger | Aurora PostgreSQL only | `sql-conversion` | Redshift and Iceberg have no triggers |

## Complexity and review tiers

| Complexity | Definition | Review tier |
|---|---|---|
| L1 | single statement or DDL, no joins/CTEs, no procedural code | T1 (data engineer + automated checks) |
| L2 | joins, aggregation, CTEs, standard windows, routine CDC, ≤ 5 statements | T2 (+ peer reviewer) |
| L3 | any heavy construct (recursive CTE, MERGE, dynamic SQL, cursor, loop, pivot, APPLY, temp tables), procedural error handling or transactions, or security-bearing | T3 (+ architect and security/test review) |
| L4 | CLR / xp_, linked servers, spatial, GOTO, HIERARCHYID, Service Broker / mail, or three or more heavy constructs | T3 |

## Rules

| ID | Rule | Test |
|---|---|---|
| MA-01 | The construct inventory counts real constructs only: keywords in comments or string literals are ignored; heavy and security constructs are listed separately | auto |
| MA-02 | Dependencies list objects read or written, temp tables, and unresolved four-part / linked-server names; aliases, CTE names, cursor names and system procedures are excluded; within a folder the tool counts how many other objects reference each defined object | auto |
| MA-03 | Security-bearing SQL is detected (identity functions such as ORIGINAL_LOGIN / SUSER_SNAME / IS_MEMBER, authorization-table joins, MASKED WITH, EXECUTE AS) and blocks the object with SECURITY_MAPPING_REQUIRED until a security-rules file is supplied | auto |
| MA-04 | M2RVE role: a view consumed by other objects is MIDDLE; a projection-only view is ELIMINATE; an updatable view (WITH CHECK OPTION / INSTEAD OF) is ELIMINATE write-through; an edge view with an unknown consumer is REVIEW; data-movement routines are MIDDLE; result-returning routines are RIGHT_EDGE; tables are LEFT_EDGE | auto |
| MA-05 | Complexity L1–L4 and review tier T1–T3 follow the table above; security-bearing objects are always T3; an explicit override wins | auto |
| MA-06 | Target candidates carry blockers: cursors, triggers, table variables, FOR XML/JSON, CLR, linked servers and spatial block Redshift; cursors, dynamic SQL, transactions and output parameters block Iceberg/Glue; triggers are Aurora-only | auto |
| MA-07 | The recommended skill follows the chosen target (AuroraPostgreSQL → sql-conversion, Redshift → sql-conversion-redshift, Iceberg/Glue/Spark → sql-conversion-iceberg) | auto |
| MA-08 | Status semantics: no target → BLOCKED TARGET_DECISION_REQUIRED; target with blockers → PARTIAL UNSUPPORTED_CONSTRUCT; unresolved dependency → PARTIAL DEPENDENCY_UNRESOLVED; feasible target → GENERATED with a validation manifest whose unexecuted checks are listed | auto |
| MA-09 | Open questions are generated for every missing decision (consumer, target, materialization, identity mapping, multiple result sets, dynamic SQL, load semantics, spatial, cross-database) and never answered by default | auto |
| MA-10 | `inventory` lists every source file with type, object count and complexity, and audits the migration log: files not logged, objects without an entry, and manual-review flags whose generated file lacks the `MANUAL REVIEW REQUIRED` marker | auto |
| MA-11 | `validate` applies the universal input contract and returns stable diagnostics with stop codes; `assess` refuses oversized inputs and reports prompt-injection / hidden-character / credential findings as data | auto |
| MA-12 | Classification output follows the universal output contract (classification, artifacts, analysis, validation) and is written as deterministic JSON plus a Markdown report; the same input yields byte-identical JSON apart from run metadata | auto |
