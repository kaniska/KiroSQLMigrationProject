-- ============================================================
-- sql-conversion skill — test engine: assertion helpers
-- Include AFTER guard_and_reset.sql and the schema, BEFORE the test files.
--
-- Conventions for test names (checked by scripts/check_rule_coverage.py):
--   '<ID> <description> [<rule tag> ...]'
--   rule tags: [H<n>] hard rule, [P<n>] parity rule (.kiro/steering/migration.md),
--              [CC-<nn>] corner case (references/corner-cases.md)
--
-- Suite pattern:
--   DO $$
--   DECLARE s TEXT := 'suite_name';
--   BEGIN
--       PERFORM test_assert_equal(s, 'TC-XX-01 what it proves [P4]', actual, expected);
--   EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
--   END $$;
-- ============================================================

CREATE TEMP TABLE test_results (
    test_id      SERIAL PRIMARY KEY,
    suite        TEXT NOT NULL,
    test_name    TEXT NOT NULL,
    status       TEXT NOT NULL CHECK (status IN ('PASS', 'FAIL', 'ERROR')),
    message      TEXT,
    executed_at  TIMESTAMPTZ DEFAULT clock_timestamp(),
    run_id       TEXT        DEFAULT current_setting('migration.run_id', true)
);

-- actual IS NOT DISTINCT FROM expected (both arguments must share one type)
CREATE FUNCTION public.test_assert_equal(p_suite TEXT, p_test TEXT, p_actual ANYELEMENT, p_expected ANYELEMENT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO test_results (suite, test_name, status, message)
    VALUES (p_suite, p_test,
            CASE WHEN p_actual IS NOT DISTINCT FROM p_expected THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN p_actual IS NOT DISTINCT FROM p_expected THEN NULL
                 ELSE format('expected %s, got %s',
                             COALESCE(p_expected::TEXT, 'NULL'), COALESCE(p_actual::TEXT, 'NULL')) END);
END;
$$;

CREATE FUNCTION public.test_assert_true(p_suite TEXT, p_test TEXT, p_condition BOOLEAN, p_msg TEXT DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO test_results (suite, test_name, status, message)
    VALUES (p_suite, p_test,
            CASE WHEN p_condition IS TRUE THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN p_condition IS TRUE THEN NULL
                 ELSE COALESCE(p_msg, 'condition was false or NULL') END);
END;
$$;

-- Runs p_sql in a subtransaction (side effects rolled back); passes when it
-- raises an error whose message matches the LIKE pattern p_like.
CREATE FUNCTION public.test_assert_raises(p_suite TEXT, p_test TEXT, p_sql TEXT, p_like TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO test_results (suite, test_name, status, message)
        VALUES (p_suite, p_test,
                CASE WHEN SQLERRM LIKE p_like THEN 'PASS' ELSE 'FAIL' END,
                CASE WHEN SQLERRM LIKE p_like THEN NULL
                     ELSE format('expected error like %L, got %L', p_like, SQLERRM) END);
        RETURN;
    END;
    INSERT INTO test_results (suite, test_name, status, message)
    VALUES (p_suite, p_test, 'FAIL', format('expected an error like %L, none raised', p_like));
END;
$$;

-- Same, but matches the SQLSTATE (e.g. '23505', '22001', '22012')
CREATE FUNCTION public.test_assert_sqlstate(p_suite TEXT, p_test TEXT, p_sql TEXT, p_sqlstate TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO test_results (suite, test_name, status, message)
        VALUES (p_suite, p_test,
                CASE WHEN SQLSTATE = p_sqlstate THEN 'PASS' ELSE 'FAIL' END,
                CASE WHEN SQLSTATE = p_sqlstate THEN NULL
                     ELSE format('expected SQLSTATE %s, got %s (%s)', p_sqlstate, SQLSTATE, SQLERRM) END);
        RETURN;
    END;
    INSERT INTO test_results (suite, test_name, status, message)
    VALUES (p_suite, p_test, 'FAIL', format('expected SQLSTATE %s, no error raised', p_sqlstate));
END;
$$;

-- Records an unexpected error that aborted a whole suite
CREATE FUNCTION public.test_error(p_suite TEXT, p_message TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO test_results (suite, test_name, status, message)
    VALUES (p_suite, '(suite aborted)', 'ERROR', p_message);
END;
$$;

-- Records the outcome of a top-level CALL (used after \if :ERROR in psql)
CREATE FUNCTION public.test_record(p_suite TEXT, p_test TEXT, p_status TEXT, p_message TEXT DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO test_results (suite, test_name, status, message) VALUES (p_suite, p_test, p_status, p_message);
END;
$$;
