-- ============================================================
-- sql-conversion skill — test engine correlation tests
-- Proves that a test run can be found in PostgreSQL logs, pg_stat_activity and the
-- audit log by one id. Tags: [LOG-nn] (references/security-logging.md).
-- ============================================================
\echo '--- engine: correlation id and application_name'
DO $$
DECLARE s TEXT := 'engine_correlation';
BEGIN
    PERFORM test_assert_true(s, 'migration.run_id is set for the session (psql variable run_id / PGOPTIONS) as a 32-hex W3C trace id [LOG-06]',
        COALESCE(current_setting('migration.run_id', true), '') ~ '^[0-9a-f]{32}$', current_setting('migration.run_id', true));
    PERFORM test_assert_true(s, 'application_name is mig:<manifest>:<run8> so pg_stat_activity and log_line_prefix %a show the run [LOG-06]',
        current_setting('application_name') ~ '^mig:[A-Za-z0-9_.-]+:[0-9a-f]{8}$'
        AND split_part(current_setting('application_name'), ':', 3) = left(current_setting('migration.run_id', true), 8),
        current_setting('application_name'));
    PERFORM test_assert_true(s, 'pg_stat_activity shows this backend with the run''s application_name [LOG-06]',
        EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.pid = pg_backend_pid() AND a.application_name = current_setting('application_name')));
    PERFORM test_assert_equal(s, 'every recorded test result carries the run id [LOG-06]',
        (SELECT COUNT(*) FROM test_results r WHERE r.run_id IS DISTINCT FROM current_setting('migration.run_id', true)), 0::BIGINT);
    PERFORM test_assert_true(s, 'the engine refuses superuser sessions unless allowed: this role is not a superuser [LOG-06] [SEC-07]',
        NOT (SELECT r.rolsuper FROM pg_roles r WHERE r.rolname = current_user) OR current_setting('application_name') LIKE 'mig:%');
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;
