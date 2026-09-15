-- ============================================================
-- sql-conversion skill — test engine: summary + exit status
-- Include LAST from a test manifest. psql exits with code 3 when any test
-- failed or errored, so shells and Kiro hooks can gate on it.
-- ============================================================
\unset QUIET
\echo ''
\echo '========================================'
\echo '          TEST RESULTS SUMMARY          '
\echo '========================================'
SELECT suite,
       COUNT(*) FILTER (WHERE status = 'PASS')  AS passed,
       COUNT(*) FILTER (WHERE status = 'FAIL')  AS failed,
       COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
       COUNT(*)                                 AS total
FROM   test_results
GROUP  BY suite
ORDER  BY MIN(test_id);

SELECT MIN(run_id) AS run_id, current_setting('application_name') AS application_name,
       to_char(MIN(executed_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS started_utc,
       to_char(MAX(executed_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS finished_utc
FROM   test_results;

\echo '--- Failures and errors ---'
SELECT suite, test_name, status, message
FROM   test_results
WHERE  status <> 'PASS'
ORDER  BY test_id;

SELECT COUNT(*) FILTER (WHERE status = 'PASS')   AS total_pass,
       COUNT(*) FILTER (WHERE status = 'FAIL')   AS total_fail,
       COUNT(*) FILTER (WHERE status = 'ERROR')  AS total_error,
       COUNT(*)                                  AS grand_total,
       CASE WHEN COUNT(*) FILTER (WHERE status <> 'PASS') = 0 AND COUNT(*) > 0
            THEN 'ALL TESTS PASSED ✓'
            ELSE 'SOME TESTS FAILED ✗' END      AS overall_result
FROM   test_results;

-- Machine-readable list of every test name (consumed by check_rule_coverage.py)
\if :{?results_file}
    \set QUIET on
    \o :results_file
    \pset format unaligned
    \pset tuples_only on
    SELECT status || E'\t' || suite || E'\t' || test_name FROM test_results ORDER BY test_id;
    \pset tuples_only off
    \pset format aligned
    \o
\endif

SELECT COUNT(*) FILTER (WHERE status <> 'PASS') = 0 AND COUNT(*) > 0 AS all_passed FROM test_results \gset
\if :all_passed
\else
    \set QUIET on
    DO $$ BEGIN RAISE EXCEPTION 'test suite failed — see the failures table above'; END $$;
\endif
