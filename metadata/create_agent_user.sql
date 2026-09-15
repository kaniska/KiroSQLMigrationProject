-- ============================================================
-- One-time setup: test database + migration_agent role (ALREADY APPLIED
-- to database-1 on 2026-09-09; kept for rebuilding the environment).
--
-- The cluster uses IAM database authentication. Run as the master user with an
-- IAM token, from the project root:
--
--   RDSHOST=database-1.cluster-ck1imm86sh9q.us-east-1.rds.amazonaws.com
--   PGPASSWORD="$(aws rds generate-db-auth-token --hostname $RDSHOST \
--       --port 5432 --username postgres --region us-east-1)" \
--   psql "host=$RDSHOST port=5432 dbname=postgres user=postgres sslmode=require" \
--       -f metadata/create_agent_user.sql
--
-- Sections 1–2 fail harmlessly if the database/role already exist; the grants
-- in section 3 are idempotent and safe to re-run.
-- ============================================================

-- 1. Test database (name must contain "test": tests/test_runner.sql checks it)
CREATE DATABASE sql_migration_test
    ENCODING   'UTF8'
    LC_COLLATE 'en_US.UTF-8'
    LC_CTYPE   'en_US.UTF-8'
    TEMPLATE   template0;

-- 2. Non-superuser role for the agent, authenticated by IAM tokens only
CREATE ROLE migration_agent
    WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
GRANT rds_iam TO migration_agent;
GRANT CONNECT, CREATE ON DATABASE sql_migration_test TO migration_agent;

-- 3. Schema rights inside the test database
\connect sql_migration_test

-- The agent creates (and therefore owns) every test table and function, so
-- USAGE + CREATE on public is all it needs; tests/test_runner.sql drops only
-- objects owned by the connected role.
GRANT USAGE, CREATE ON SCHEMA public TO migration_agent;

\echo 'Done. Verify from the project root with:  bash supporting-files/run_tests.sh'
