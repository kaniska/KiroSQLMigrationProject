# Prompts for the sql-migration-agent — what to ask, what happens

Every prompt below works in Kiro chat (`kiro-cli chat --agent sql-migration-agent`, on Windows
`--agent sql-migration-agent-windows`) and in the IDE agent selector. The agent asks the intake
questions it still needs, then routes to a skill; the answer always ends with status, stop codes,
manual-review items and the audit run id.

## Assessment and routing (`migration-assessment`)
- "Assess `source/` for a BI migration. The consumer is Power BI; the target is undecided."
  → inventory, roles (M2RVE), complexity, target candidates with blockers, a question per undecided item.
- "Which objects in `source/` can go to Redshift and which must stay on Aurora?"
- "Classify `source/v_CustomerSummary.sql` and tell me the review tier."
- "What is left to migrate?" → migration status + inventory + log audit.

## Aurora PostgreSQL (`sql-conversion`)
- "Convert `source/usp_UpsertProduct.sql` for Aurora PostgreSQL 17; the consumer is the order API and the result set must keep its column names."
- "Migrate everything pending."
- "Review `generated/usp_upsert_product.sql` against the corner-case catalog."

## Amazon Redshift (`sql-conversion-redshift`)
- "Convert `source/schema/sales_db_schema.sql` to Redshift DDL. Design decisions are in `metadata/design/redshift.json` (FactSales DISTKEY customer_key, SORTKEY sale_date; dimensions DISTSTYLE ALL)."
- "Rewrite `source/v_CustomerSummary.sql` as a Redshift late-binding view for the BI team; keep the output columns identical."
- "Turn `source/usp_LoadCustomerSummary.sql` into a Redshift procedure that returns rows through a refcursor; MERGE must respect Redshift limits."
- "Check `generated/redshift/v_customer_summary.sql` for residual T-SQL and run it on `dw_test` (workgroup `analytics-dev`)."

## Iceberg on S3 — Athena / Glue / Spark (`sql-conversion-iceberg`)
- "Land `dbo.FactSales` and `dbo.DimCustomer` as Iceberg tables in `sales_lake`, location prefix `s3://example-lake-bucket/sales_lake`, FactSales partitioned by `day(SaleDate)` and `bucket(16, CustomerKey)`."
- "Generate the Glue MERGE job for `customer_summary` keyed on `customer_key`, latest `last_sale` wins."
- "Write the Athena view for `v_CustomerSummary` over the lake tables."
- "Check `generated/iceberg/load_customer_summary.glue.py` and package it with the Spark SQL."

## Reporting and analytics (`sql-reporting`)
- "Monthly revenue by category for 2025 with YoY growth, on the converted schema."
- "Top 10 customers by lifetime value with their share of total revenue."
- "Cohort retention by signup month, 12 periods."

## Informatica (`informatica-etl-conversion`)
- "Convert `source/informatica/wf_orders.xml` for PostgreSQL; the parameter file is `source/informatica/params/orders.prm`."

## Schema gap analysis and conformance (`schema-conformance`)
- "Compare `source/schema` with `generated/schema.sql` (Aurora profile) and list every conflict and missing column."
- "Snapshot the test database and tell me whether it matches the converted DDL."
- "Do all objects referenced by `generated/*.sql` exist in the target schema?"
- "Propose the DDL to make the Redshift tables conform to the source (dry run)."

## Change propagation (`schema-change-propagation`)
- "Apply the rename/cast template `metadata/changes/q3_changes.csv` to `generated/` as a dry run; protected layers are `src.*` and `lookup.*`; editable files are `generated/etl_*.sql`."
- "Show me the cast-safety findings and what needs a reviewer decision."
- "Package the change with the diff, migration and rollback scripts."

## Evidence, audit and status
- "What did run `871771c8` do?" → `audit.py tail --run 871771c8`.
- "Where do audit and lineage go right now, AWS or local?"
- "Run all tests." / "Run the Redshift skill self-test."

## What the agent will not do (by design)
- Create AWS resources, write to non-test databases, apply change patches, install packages, push to git.
- Guess a target, a consumer contract, a distribution key, a partition, a datatype or an identity mapping — it asks.
