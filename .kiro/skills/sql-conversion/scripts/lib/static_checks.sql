-- ============================================================
-- sql-conversion skill — test engine: static checks on converted code
-- Include AFTER the converted objects are loaded. Inspects every function /
-- procedure in schema public owned by the connected role (test_* helpers
-- excluded) and every table column, and enforces the hard rules that can
-- be checked from the catalog. Comments, string literals and dollar-quoted
-- dynamic SQL are stripped before pattern checks.
-- ============================================================
\echo '--- static checks (hard rules)'
CREATE TEMP VIEW pgtest_routines AS
SELECT p.oid,
       p.proname,
       p.prokind,
       p.provolatile,
       l.lanname,
       regexp_replace(
         regexp_replace(
           regexp_replace(
             regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'),       -- block comments
             '--[^\n]*', ' ', 'g'),                                 -- line comments
           '\$([A-Za-z_]*)\$.*?\$\1\$', ' ', 'g'),                  -- nested $tag$ strings
         '''([^'']|'''')*''', ' ', 'g')                             -- 'literals'
         AS code
FROM   pg_proc p
JOIN   pg_language l ON l.oid = p.prolang
WHERE  p.pronamespace = 'public'::regnamespace
  AND  p.proowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
  AND  p.prokind IN ('f', 'p')
  AND  p.proname NOT LIKE 'test\_%'
  AND  NOT EXISTS (SELECT 1 FROM pg_depend d
                   WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e');

DO $$
DECLARE
    s TEXT := 'static_checks';
    v_bad TEXT;
    v_n   INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM pgtest_routines;
    PERFORM test_assert_true(s, 'STATIC-00 converted routines found', v_n > 0, 'no routines loaded');

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines WHERE code ~* '\mdbo\.';
    PERFORM test_assert_true(s, 'STATIC-01 no dbo. references [H3]', v_bad IS NULL, 'offenders: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines
    WHERE  code ~* '\mNOLOCK\M|\mUPDLOCK\M|\mSET\s+NOCOUNT\M|@@[A-Za-z]|(^|\n)\s*GO\s*(\n|$)';
    PERFORM test_assert_true(s, 'STATIC-02 no NOLOCK / UPDLOCK / SET NOCOUNT / GO / @@functions [H5]',
                             v_bad IS NULL, 'offenders: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines WHERE code ~ '@[A-Za-z_]';
    PERFORM test_assert_true(s, 'STATIC-03 no @variables [H6]', v_bad IS NULL, 'offenders: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines WHERE lanname NOT IN ('plpgsql', 'sql');
    PERFORM test_assert_true(s, 'STATIC-04 every routine is LANGUAGE plpgsql or sql [H7]', v_bad IS NULL, 'offenders: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad
    FROM  (SELECT proname FROM pgtest_routines GROUP BY proname HAVING COUNT(*) > 1) d;
    PERFORM test_assert_true(s, 'STATIC-05 no routine name is defined twice [H8]', v_bad IS NULL, 'overloaded: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines
    WHERE  prokind = 'f' AND code ~* '\m(COMMIT|ROLLBACK)\M';
    PERFORM test_assert_true(s, 'STATIC-06 no COMMIT/ROLLBACK inside a FUNCTION [H9]', v_bad IS NULL, 'offenders: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines
    WHERE  code ~* 'CREATE\s+TEMP(ORARY)?\s+TABLE\s+(?!IF\s+NOT\s+EXISTS)';
    PERFORM test_assert_true(s, 'STATIC-07 temp tables use IF NOT EXISTS (+ TRUNCATE) [H10]', v_bad IS NULL, 'offenders: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines
    WHERE  provolatile IN ('s', 'i')
      AND  code ~* '\m(insert\s+into|update\s+[a-z_."]+\s+(as\s+)?[a-z_]*\s*set|delete\s+from|create\s+temp|truncate|merge\s+into|gen_random_uuid|clock_timestamp)\M';
    PERFORM test_assert_true(s, 'STATIC-08 no STABLE/IMMUTABLE routine writes data or calls volatile functions [H13]',
                             v_bad IS NULL, 'offenders: ' || v_bad);

    SELECT string_agg(format('%s.%s', c.relname, a.attname), ', ') INTO v_bad
    FROM   pg_attribute a
    JOIN   pg_class c ON c.oid = a.attrelid
    WHERE  c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
      AND  a.attnum > 0 AND NOT a.attisdropped AND a.atttypid = 'money'::regtype;
    PERFORM test_assert_true(s, 'STATIC-09 no column uses the money type [H4]', v_bad IS NULL, 'columns: ' || v_bad);

    SELECT string_agg(proname, ', ') INTO v_bad FROM pgtest_routines WHERE code ~* '\mmoney\M';
    PERFORM test_assert_true(s, 'STATIC-10 no routine uses the money type [H4]', v_bad IS NULL, 'offenders: ' || v_bad);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;
