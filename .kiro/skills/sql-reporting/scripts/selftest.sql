-- ============================================================
-- sql-reporting skill — self-test manifest
-- Uses the shared test engine of the sql-conversion skill (../../sql-conversion/scripts/lib)
-- and its sample schema; adds the reporting fixtures, loads the 15 example
-- reports and runs the pattern + rule tests. Run: bash scripts/run_skill_tests.sh
-- ============================================================
\set min_pg 150000
\ir ../../sql-conversion/scripts/lib/guard_and_reset.sql

\echo '=== Sample schema, sample seed, reporting seed ==='
\ir ../../sql-conversion/references/examples/00_sample_schema.postgres.sql
\ir ../../sql-conversion/scripts/fixtures/sample_seed.sql
\ir fixtures/reporting_seed.sql
\ir ../../sql-conversion/scripts/lib/test_framework.sql

\echo '=== Loading example reports ==='
\ir ../references/examples/01_revenue_by_month.sql
\ir ../references/examples/02_category_revenue.sql
\ir ../references/examples/03_running_revenue.sql
\ir ../references/examples/04_revenue_growth.sql
\ir ../references/examples/05_top_products_per_category.sql
\ir ../references/examples/06_customer_pareto.sql
\ir ../references/examples/07_order_value_stats.sql
\ir ../references/examples/08_orders_by_month_status.sql
\ir ../references/examples/09_cohort_retention.sql
\ir ../references/examples/10_stock_as_of.sql
\ir ../references/examples/11_funnel.sql
\ir ../references/examples/12_customer_activity_streaks.sql
\ir ../references/examples/13_revenue_rollup.sql
\ir ../references/examples/14_customer_first_last_order.sql
\ir ../references/examples/15_order_value_histogram.sql

\echo '=== Running suites ==='
\ir tests/report_tests.sql

\ir ../../sql-conversion/scripts/lib/report.sql
