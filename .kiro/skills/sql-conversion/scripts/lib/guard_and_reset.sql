-- ============================================================
-- sql-conversion skill — test engine: safety guard + reset
-- Include FIRST from a test manifest (\ir path/to/lib/guard_and_reset.sql).
--
-- Optional psql variables (set before the \ir):
--   min_pg   minimum server_version_num, e.g. \set min_pg 170000 (default 150000)
--
-- DESTRUCTIVE: drops every table, view, sequence, type, function and
-- procedure in schema public that is OWNED BY THE CONNECTED ROLE
-- (extension objects excluded). Runs only in a database whose name contains
-- test / dev / sandbox / local.
-- ============================================================
\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = warning;

SELECT current_database() ~* '(test|dev|sandbox|local)' AS is_test_db \gset
\if :is_test_db
\else
    \echo 'REFUSING TO RUN: the test engine drops and recreates objects in schema public.'
    \echo 'Connect to a database whose name contains test, dev, sandbox or local.'
    DO $$ BEGIN RAISE EXCEPTION 'not a test database: %', current_database(); END $$;
\endif

-- Least privilege: the engine drops objects, so refuse superuser / rds_superuser sessions
SELECT (SELECT r.rolsuper FROM pg_roles r WHERE r.rolname = current_user)
       OR EXISTS (SELECT 1 FROM pg_roles r WHERE r.rolname = 'rds_superuser' AND pg_has_role(current_user, r.oid, 'MEMBER'))
       AS is_superuser \gset
\if :is_superuser
    \if :{?allow_superuser}
        \echo 'WARNING: connected as a superuser (allowed by PGTEST_ALLOW_SUPERUSER=1)'
    \else
        \echo 'REFUSING TO RUN: connected role is a superuser or member of rds_superuser.'
        \echo 'Use a least-privilege test role (see metadata/create_agent_user.sql) or set PGTEST_ALLOW_SUPERUSER=1 for a throw-away local cluster.'
        DO $$ BEGIN RAISE EXCEPTION 'superuser connection refused: %', current_user; END $$;
    \endif
\endif

-- Correlation: the run id arrives as the psql variable run_id and as the setting migration.run_id
\if :{?run_id}
    SELECT set_config('migration.run_id', :'run_id', false) AS _run \gset
\endif
SELECT current_setting('migration.run_id', true) AS run_id_seen, current_setting('application_name') AS app_seen \gset
\echo 'run_id' :run_id_seen 'application_name' :app_seen

\if :{?min_pg}
\else
    \set min_pg 150000
\endif
SELECT current_setting('server_version_num')::INT >= :min_pg AS version_ok \gset
\if :version_ok
\else
    SELECT set_config('pgtest.min_pg', :'min_pg', false) \gset
    DO $$ BEGIN RAISE EXCEPTION 'server % is older than required server_version_num %',
                      current_setting('server_version'), current_setting('pgtest.min_pg'); END $$;
\endif

\echo '=== Resetting objects owned by' :USER 'in' :DBNAME '(schema public) ==='
DO $$
DECLARE
    v_owner OID := (SELECT oid FROM pg_roles WHERE rolname = current_user);
    r RECORD;
BEGIN
    -- Relations (tables CASCADE also removes their triggers, indexes, identity sequences)
    FOR r IN
        SELECT c.oid::regclass AS obj, c.relkind
        FROM   pg_class c
        WHERE  c.relnamespace = 'public'::regnamespace
          AND  c.relowner = v_owner
          AND  c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
          AND  NOT EXISTS (SELECT 1 FROM pg_depend d
                           WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('e', 'a', 'i'))
    LOOP
        BEGIN
            EXECUTE format('DROP %s IF EXISTS %s CASCADE',
                           CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                                          WHEN 'f' THEN 'FOREIGN TABLE' WHEN 'S' THEN 'SEQUENCE'
                                          ELSE 'TABLE' END, r.obj);
        EXCEPTION WHEN undefined_table OR undefined_object THEN NULL;   -- already gone via CASCADE
        END;
    END LOOP;

    -- Functions and procedures
    FOR r IN
        SELECT p.oid::regprocedure AS sig, p.prokind
        FROM   pg_proc p
        WHERE  p.pronamespace = 'public'::regnamespace
          AND  p.proowner = v_owner
          AND  p.prokind IN ('f', 'p')
          AND  NOT EXISTS (SELECT 1 FROM pg_depend d
                           WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
    LOOP
        EXECUTE format('DROP %s IF EXISTS %s CASCADE',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, r.sig);
    END LOOP;

    -- Stand-alone types (enums, domains, composite types from converted TVPs)
    FOR r IN
        SELECT t.oid::regtype AS typ, t.typtype
        FROM   pg_type t
        LEFT   JOIN pg_class c ON c.oid = t.typrelid
        WHERE  t.typnamespace = 'public'::regnamespace
          AND  t.typowner = v_owner
          AND  (t.typtype IN ('e', 'd') OR (t.typtype = 'c' AND c.relkind = 'c'))
    LOOP
        EXECUTE format('DROP %s IF EXISTS %s CASCADE',
                       CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, r.typ);
    END LOOP;
END;
$$;
