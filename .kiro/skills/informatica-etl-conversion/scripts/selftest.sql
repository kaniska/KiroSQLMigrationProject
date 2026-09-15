-- ============================================================
-- informatica-etl-conversion skill — self-test manifest
-- Shared engine: ../../sql-conversion/scripts/lib. The .generated/*.rendered.sql files are
-- produced by run_skill_tests.sh (infa_sql_tool.py render) from the converted example
-- SQL, so the tests exercise exactly what the converted XML files contain.
-- ============================================================
\set min_pg 150000
\ir ../../sql-conversion/scripts/lib/guard_and_reset.sql

\echo '=== Sample schema, sample seed, ETL fixtures ==='
\ir ../../sql-conversion/references/examples/00_sample_schema.postgres.sql
\ir ../../sql-conversion/scripts/fixtures/sample_seed.sql
\ir fixtures/etl_targets.sql
\ir ../../sql-conversion/scripts/lib/test_framework.sql

\echo '=== Rendered SQL from the converted mappings ==='
\ir .generated/01_orders_incremental.rendered.sql
\ir .generated/02_customer_dim.rendered.sql
\ir .generated/03_shipping_procs.rendered.sql
\ir .generated/04_product_sales_session_override.rendered.sql
\ir .generated/05_customer_summary_real_export.rendered.sql

\echo '=== Running suites ==='
\ir tests/informatica_tests.sql

\ir ../../sql-conversion/scripts/lib/report.sql
