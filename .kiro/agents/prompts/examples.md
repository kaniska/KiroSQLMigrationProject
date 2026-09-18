# Prompts for the two agents — what to ask, what happens

Two agents ship with the kit (`.kiro/agents/AGENTS.md`):
- **`sql-migration-agent`** — the SQL conversion assistant: assessment, conversion to Aurora
  PostgreSQL / Amazon Redshift / Iceberg on S3, Informatica ETL, schema conformance and change
  propagation (`kiro-cli chat --agent sql-migration-agent`; Windows `sql-migration-agent-windows`).
- **`sql-reporting-agent`** — the reporting SQL assistant: report, dashboard, KPI and analytics SQL on
  PostgreSQL, Redshift, Athena/Iceberg or Spark (`kiro-cli chat --agent sql-reporting-agent`;
  Windows `sql-reporting-agent-windows`).

Every prompt below works in Kiro chat and in the IDE agent selector. The agent asks the intake
questions it still needs, then routes to a skill; the answer always ends with status, stop codes,
manual-review items and the audit run id. Sections marked *(migration agent)* belong to the first,
*(reporting agent)* to the second.

## Assessment and routing (`migration-assessment`) *(migration agent)*
- "Assess `source/` for a BI migration. The consumer is Power BI; the target is undecided."
  → inventory, roles (M2RVE), complexity, target candidates with blockers, a question per undecided item.
- "Which objects in `source/` can go to Redshift and which must stay on Aurora?"
- "Classify `source/v_CustomerSummary.sql` and tell me the review tier."
- "What is left to migrate?" → migration status + inventory + log audit.

## Aurora PostgreSQL (`sql-conversion`) *(migration agent)*
- "Convert `source/usp_UpsertProduct.sql` for Aurora PostgreSQL 17; the consumer is the order API and the result set must keep its column names."
- "Migrate everything pending."
- "Review `generated/usp_upsert_product.sql` against the corner-case catalog."

## Amazon Redshift (`sql-conversion-redshift`) *(migration agent)*
- "Convert `source/schema/sales_db_schema.sql` to Redshift DDL. Design decisions are in `metadata/design/redshift.json` (FactSales DISTKEY customer_key, SORTKEY sale_date; dimensions DISTSTYLE ALL)."
- "Rewrite `source/v_CustomerSummary.sql` as a Redshift late-binding view for the BI team; keep the output columns identical."
- "Turn `source/usp_LoadCustomerSummary.sql` into a Redshift procedure that returns rows through a refcursor; MERGE must respect Redshift limits."
- "Check `generated/redshift/v_customer_summary.sql` for residual T-SQL and run it on `dw_test` (workgroup `analytics-dev`)."

## Iceberg on S3 — Athena / Glue / Spark (`sql-conversion-iceberg`) *(migration agent)*
- "Land `dbo.FactSales` and `dbo.DimCustomer` as Iceberg tables in `sales_lake`, location prefix `s3://example-lake-bucket/sales_lake`, FactSales partitioned by `day(SaleDate)` and `bucket(16, CustomerKey)`."
- "Generate the Glue MERGE job for `customer_summary` keyed on `customer_key`, latest `last_sale` wins."
- "Write the Athena view for `v_CustomerSummary` over the lake tables."
- "Check `generated/iceberg/load_customer_summary.glue.py` and package it with the Spark SQL."

## Reporting and analytics (`sql-reporting`) *(reporting agent; the migration agent also routes here)*
- "Monthly revenue by category for 2025 with YoY growth, on the converted schema (PostgreSQL)." → `report_revenue_by_category(...)` function + tests.
- "Top 10 customers by lifetime value with their share of total revenue, on Redshift." → `v_report_customer_pareto` view, `report_tool.py check --target redshift`, ledger of dialect choices (RD-04, RD-05).
- "Cohort retention by signup month on Athena over the lake tables." → view with `date_diff('month', …)`, `check --target athena`.
- "Same revenue-by-month report as Spark SQL for the Glue job." → temporary view with `explode(sequence(...))`, `check --target spark`.
- "Review this dashboard query: <paste>" → findings against RQ-01…24 and the dialect rules of the stated target.
- "Which pattern and dialect rules apply to 'stock on hand at month end on Redshift'?" → RP-10 + `toolbox --target redshift`.

## Informatica (`informatica-etl-conversion`) *(migration agent)*
- "Convert `source/informatica/wf_orders.xml` for PostgreSQL; the parameter file is `source/informatica/params/orders.prm`."
- "Convert `source/informatica/wf_orders.xml` for Amazon Redshift" → fragments follow `redshift.md`, `check --target redshift`, `inject --map params/redshift_map.json`.
- "Prepare `source/informatica/wf_orders.xml` for the Iceberg lake" → fragments follow `iceberg.md`, `check --target iceberg`, targets become S3 landing files and the Glue MERGE job loads Iceberg (`params/iceberg_map.json`).

## Schema gap analysis and conformance (`schema-conformance`) *(both agents; the reporting agent uses read-only snapshots)*
- "Compare `source/schema` with `generated/schema.sql` (Aurora profile) and list every conflict and missing column."
- "Snapshot the test database and tell me whether it matches the converted DDL."
- "Do all objects referenced by `generated/*.sql` exist in the target schema?"
- "Propose the DDL to make the Redshift tables conform to the source (dry run)."

## Change propagation (`schema-change-propagation`) *(migration agent)*
- "Apply the rename/cast template `metadata/changes/q3_changes.csv` to `generated/` as a dry run; protected layers are `src.*` and `lookup.*`; editable files are `generated/etl_*.sql`."
- "Show me the cast-safety findings and what needs a reviewer decision."
- "Package the change with the diff, migration and rollback scripts."

## Evidence, audit and status
- "What did run `871771c8` do?" → `audit.py tail --run 871771c8`.
- "Where do audit and lineage go right now, AWS or local?"
- "Run all tests." / "Run the Redshift skill self-test."

## Testing the agents and skills from Kiro
- `bash supporting-files/verify_agents.sh` (Windows `supporting-files\verify_agents.cmd`) — structural tests, `kiro-cli agent validate` for all four files, workspace listing; `--smoke` adds one read-only headless prompt per agent.
- `kiro-cli agent list` → both agents as `Workspace`; `kiro-cli chat --agent sql-reporting-agent` then `/context show` → skills and steering loaded.
- `bash .kiro/skills/<skill>/scripts/run_skill_tests.sh` per skill; `bash supporting-files/run_tests.sh` for everything.

## What the agents will not do (by design)
- Create AWS resources, write to non-test databases, apply change patches, install packages, push to git.
- Guess a target, a consumer contract, a distribution key, a partition, a datatype or an identity mapping — it asks.
