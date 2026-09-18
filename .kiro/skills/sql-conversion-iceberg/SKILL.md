---
name: sql-conversion-iceberg
description: Land SQL Server tables and set-based logic in Apache Iceberg tables on Amazon S3 (AWS Glue Data Catalog, Amazon Athena, AWS Glue Spark jobs) - Iceberg spec type map with lost lengths kept in comments, partition transforms and locations from a design file, Athena and Spark SQL DDL, Athena views for BI, Glue 5.x PySpark MERGE jobs rendered from a template, static Spark/Athena review, rule ledger, and execution evidence through Athena on test databases only. Use when the approved target is Iceberg, S3 Tables, a data lake or lakehouse, Athena, Glue or Spark, or to check hand-written Spark SQL / Athena SQL / Glue jobs for residual SQL Server constructs.
license: Apache-2.0
metadata:
  version: "1.0"
  target: "Apache Iceberg (spec v2) on S3 · AWS Glue Data Catalog · Amazon Athena engine v3 · AWS Glue 5.x (Spark 3.5) / Spark 4"
  gates: "G4 generation, G5 static validation, G6 execution evidence of the seven-gate governance workflow"
---

# SQL Server → Apache Iceberg on S3 (Athena / Glue / Spark)

Iceberg is a table format, not a database engine: this skill lands **tables, loads and BI views**
and turns procedural logic into Glue jobs — or sends it back to `migration-assessment` when it
belongs on Aurora. Rules: `.kiro/steering/iceberg.md` (`[I-1]…[I-11]`) and
`.kiro/steering/governance.md`. Corner cases: `references/corner-cases.md` (`IB-01…IB-80`, every
row proven by a tagged test). Worked pairs: `references/examples/` (`*.sqlserver.sql` →
`*.athena.sql` / `*.spark.sql` / `*.glue.py`, design decisions in `*.design.json`, job spec in
`*.job.json`).

`scripts/iceberg_tool.py` is deterministic standard-library Python (shared engine: the
`sql-conversion` skill's `migkit`). The model writes the Spark/Athena SQL and explains; the tool
converts DDL, renders and compiles jobs, lints, infers the ledger, executes on Athena and packages.

## Procedure

### Step 0: Confirm placement and decisions
The request must carry `target.platform = Iceberg` (or `GluePySpark` / `SparkSQL`) from
`migration-assessment`. Collect the design decisions before generating anything: catalog and
database names, S3 location prefix, partition transforms per table, which tables are MERGE-heavy
(merge-on-read), and who serves BI (Athena views or Redshift Spectrum). Missing decisions become
`TARGET_SCHEMA_DECISION_REQUIRED` questions, not guesses.

### Step 1: Tables — DDL for both dialects
```bash
python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py ddl source/schema/tables.sql --design design.json --out-dir generated/iceberg --ledger generated/iceberg/tables.ledger.json
```
```json
{"database": "sales_lake", "catalog": "glue_catalog", "location_prefix": "s3://example-lake-bucket/sales_lake",
 "tables": {"dbo.FactSales": {"partition": ["day(SaleDate)", "bucket(16, CustomerKey)"]},
            "dbo.DimCustomer": {"partition": [], "merge_heavy": true}}}
```
Produces `<name>.athena.sql` (`LOCATION`, `TBLPROPERTIES ('table_type'='ICEBERG')`, no `NOT NULL`)
and `<name>.spark.sql` (`glue_catalog.db.table USING iceberg`, `format-version 2`). Types follow the
spec [IB-10…IB-22]; identity, constraints, defaults, computed columns and indexes become trailer
comments and ledger rows — "applied by the load job" or "validated by query" [IB-01…IB-05].
Without a location the DDL carries a placeholder and the status is `PARTIAL` [IB-31].

### Step 2: Views and set-based SQL — translate, then check
BI edge views become **Athena views** (Trino SQL) [IB-70]; load logic becomes **Spark SQL** for a
job. Follow the function map [IB-40…IB-52] (`date_add`/`datediff` argument order, `instr`
argument order, `listagg`, `div` for integer division, `try_cast` kept) and the MERGE rules
[IB-60…IB-62] (deduplicate the source, no `BY SOURCE` on Athena, schedule `OPTIMIZE`/`VACUUM`).
```bash
python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py check generated/iceberg/v_customer_summary.athena.sql --dialect athena --source source/v_CustomerSummary.sql
python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py check generated/iceberg/load_customer_summary.spark.sql --dialect spark --source source/usp_LoadCustomerSummary.sql
```
`check` must report **0 problems** (residual T-SQL, unsupported DDL items, Athena `BY SOURCE`,
implicit recursive CTEs, security findings `SEC-01…04`, constructs introduced versus the source
`SEC-09`). Warnings (`IB-42` time zone, `IB-49` division, `IB-60` duplicate source, `IB-62` delete
files, `IB-64`/`IB-65` portability) must be answered in the ledger.

### Step 3: Procedures → Glue job
Write the job spec and render the job from the template — never hand-type the Spark session,
catalog configuration or MERGE:
```bash
python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py job generated/iceberg/load_customer_summary.job.json --out generated/iceberg/load_customer_summary.glue.py
```
```json
{"catalog": "glue_catalog", "source_table": "glue_catalog.sales_lake.fact_sales", "target_table": "glue_catalog.sales_lake.customer_summary",
 "merge_keys": ["customer_key"], "update_columns": ["revenue", "last_sale"], "watermark_column": "last_sale",
 "source_sql": "SELECT customer_key, sum(line_total) AS revenue, max(sale_date) AS last_sale FROM src_raw GROUP BY customer_key"}
```
The job (Glue 5.x, `--datalake-formats iceberg`) deduplicates the source on the merge keys,
runs an idempotent `MERGE INTO`, prints row counts, the snapshot id and the run id for the audit,
and is compiled (`py_compile`) and security-scanned: no credentials, no `boto3` identity calls, no
shell [IB-71, IB-72]. Deploying the job (`aws glue create-job`) is a user decision outside this skill.

### Step 4: Ledger and package
```bash
python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py ledger source/usp_LoadCustomerSummary.sql generated/iceberg/load_customer_summary.spark.sql
python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py package source/usp_LoadCustomerSummary.sql generated/iceberg/load_customer_summary.spark.sql generated/iceberg/load_customer_summary.glue.py --out generated/iceberg/pkg/load_customer_summary --classification generated/assessment/usp_LoadCustomerSummary.classification.json
```
The package holds `request.json`, `output.json` (universal output contract: status, stop codes,
deduplicated ledger, warnings, manual-review items, validation manifest with `V-006` lengths,
`V-012` row counts at a snapshot, `V-014` uniqueness, `V-032` pruning, `V-033` idempotent rerun),
`rule-ledger.md`, every file and `manifest.json` with SHA-256 hashes and the run id.

### Step 5: Execution evidence (optional, test databases only)
```bash
python3 .kiro/skills/sql-conversion-iceberg/scripts/iceberg_tool.py run generated/iceberg/tables.athena.sql --database sales_lake_dev --workgroup primary --output-location s3://example-lake-bucket/athena-results/ --evidence generated/iceberg/pkg/tables/run.json
```
`run` submits each statement with `athena start-query-execution` (idempotent client token) through
the kit's AWS service layer and polls `get-query-execution`. Guardrails: the database name must
contain `test`, `dev`, `sandbox` or `local` (exit 3 otherwise); the SQL is security-scanned first;
when Athena is unavailable nothing runs and `V-004` stays unexecuted [IB-80]. Row-count
reconciliation uses `FOR TIMESTAMP AS OF` on the snapshot the load produced [IB-73].

## Guardrails and audit
- Inputs are scanned (`SEC-01…03`) and size-limited; refusals exit 3 and are audited without the secret.
- Generated SQL and jobs are scanned for dangerous or data-moving statements and identity calls
  (`SEC-04`, `IB-72`); converted SQL is diffed against the source (`SEC-09`).
- Every command writes correlated audit records under the run id (`iceberg.ddl`, `iceberg.check`,
  `iceberg.job`, `athena.execute`, `athena.result`, `iceberg.package`, `security.refused`); SQL
  is logged by hash, never by content.
- Statuses only escalate (`GENERATED` → `PARTIAL` → `BLOCKED`); `VALIDATED` needs execution evidence.

## Verify the skill itself
`bash .kiro/skills/sql-conversion-iceberg/scripts/run_skill_tests.sh` (Windows:
`.kiro\skills\sql-conversion-iceberg\scripts\run_skill_tests.cmd`): 10 unit tests on fixtures and
the worked examples (fresh renders must equal the committed examples), the Athena path against
the stub AWS CLI, job compilation, and coverage of all `IB-nn` rows. Set `ATHENA_DATABASE` (a test
database) and optionally `ATHENA_WORKGROUP`/`ATHENA_OUTPUT_LOCATION` to add a live `SELECT 1`;
nothing is created in AWS.
