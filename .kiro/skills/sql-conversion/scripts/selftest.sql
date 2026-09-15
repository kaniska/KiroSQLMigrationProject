-- ============================================================
-- sql-conversion skill — self-test manifest
-- Proves the skill's worked examples and corner-case mappings on a real
-- PostgreSQL 17 database. Run with:  bash scripts/run_skill_tests.sh
-- (or: bash scripts/pgtest.sh scripts/selftest.sql)
-- ============================================================
\set min_pg 170000
\ir lib/guard_and_reset.sql

\echo '=== Sample schema and seed data ==='
\ir ../references/examples/00_sample_schema.postgres.sql
\ir fixtures/sample_seed.sql
\ir lib/test_framework.sql

\echo '=== Loading worked examples ==='
\ir ../references/examples/01_upsert_product.postgres.sql
\ir ../references/examples/02_recalc_order_totals.postgres.sql
\ir ../references/examples/03_generate_monthly_invoices.postgres.sql
\ir ../references/examples/04_dynamic_search.postgres.sql
\ir ../references/examples/05_apply_price_list.postgres.sql
\ir ../references/examples/06_bulk_update_prices.postgres.sql
\ir ../references/examples/07_get_org_chart.postgres.sql
\ir ../references/examples/08_format_customer_report.postgres.sql
\ir ../references/examples/09_transfer_stock.postgres.sql
\ir ../references/examples/10_business_days_between.postgres.sql
\ir ../references/examples/11_customer_dashboard.postgres.sql
\ir ../references/examples/12_sync_category_prices.postgres.sql
\ir ../references/examples/13_discounted_price.postgres.sql
\ir ../references/examples/14_import_staged_prices.postgres.sql
\ir ../references/examples/15_order_stats.postgres.sql
\ir ../references/examples/16_top_customers.postgres.sql
\ir ../references/examples/17_order_status_audit.postgres.sql

\echo '=== Running suites ==='
\ir lib/static_checks.sql
\ir tests/example_tests.sql
\ir tests/corner_case_tests.sql
\ir tests/engine_tests.sql

\ir lib/report.sql
