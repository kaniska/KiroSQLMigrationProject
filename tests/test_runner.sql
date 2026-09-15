-- ============================================================
-- File: tests/test_runner.sql — PROJECT TEST MANIFEST
-- Rebuilds the test schema, loads every converted object of this project and
-- runs the project suites, using the sql-conversion skill's generic test
-- engine (.kiro/skills/sql-conversion/scripts/lib/).
--
--   * DESTRUCTIVE for objects the connected role owns in schema public; only
--     runs in a database whose name contains test/dev/sandbox/local.
--   * \ir paths are relative to this file: psql can start anywhere.
--   * psql exits 3 when any test fails or errors.
--
-- Run:  bash supporting-files/run_tests.sh --project     (handles Aurora IAM auth)
--   or: psql "<conninfo>" -f tests/test_runner.sql
-- ============================================================
\set min_pg 170000
\ir ../.kiro/skills/sql-conversion/scripts/lib/guard_and_reset.sql

\echo '=== Schema (generated/schema.sql) and seed data ==='
\ir ../generated/schema.sql
\ir seed_data.sql
\ir ../.kiro/skills/sql-conversion/scripts/lib/test_framework.sql

\echo '=== Loading converted objects ==='
\ir ../generated/manage_inventory.sql
\ir ../generated/sales_reporting.sql
\ir ../generated/customer_orders.sql
\ir ../examples/converted_example.sql

\echo '=== Running suites ==='
\ir ../.kiro/skills/sql-conversion/scripts/lib/static_checks.sql
\ir test_cases.sql

\ir ../.kiro/skills/sql-conversion/scripts/lib/report.sql
