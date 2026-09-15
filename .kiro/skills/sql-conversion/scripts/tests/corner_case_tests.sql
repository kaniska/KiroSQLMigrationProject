-- ============================================================
-- sql-conversion skill — corner-case tests
-- Catalog: references/corner-cases.md (one row per CC-nn, with the SQL Server
-- result each test expects and the rule it enforces).
--
-- Each test proves that the RECOMMENDED PostgreSQL mapping (steering file
-- .kiro/steering/migration.md) returns what SQL Server returns. Where useful,
-- a second test shows that the NAIVE mapping returns something else — that
-- is the reason the rule exists.
--
-- The mappings under test are written as pg_temp helper functions so each
-- formula is exercised with several inputs. pg_temp objects vanish at the
-- end of the session and never touch schema public.
-- Expected SQL Server values assume the defaults: SQL_Latin1_General_CP1_CI_AS,
-- SET DATEFIRST 7, SET LANGUAGE us_english, ANSI settings ON.
-- ============================================================

-- ------------------------------------------------------------
-- Mapping helpers = the steering-file formulas
-- ------------------------------------------------------------
-- LEN(s)
CREATE FUNCTION pg_temp.ss_len(s TEXT) RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$ SELECT char_length(rtrim(s)) $$;

-- CHARINDEX(needle, hay [, start]) under a case-insensitive collation
CREATE FUNCTION pg_temp.ss_charindex(n TEXT, h TEXT, st INTEGER DEFAULT 1) RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN n IS NULL OR h IS NULL THEN NULL
        WHEN n = '' THEN 0
        ELSE (SELECT CASE WHEN p = 0 THEN 0 ELSE p + GREATEST(st, 1) - 1 END
              FROM (SELECT strpos(lower(substring(h FROM GREATEST(st, 1))), lower(n)) AS p) x)
    END
$$;

-- REPLICATE(s, n)
CREATE FUNCTION pg_temp.ss_replicate(s TEXT, n INTEGER) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN n >= 0 THEN repeat(s, n) END $$;

-- LEFT(s, n): SQL Server raises for n < 0
CREATE FUNCTION pg_temp.ss_left(s TEXT, n INTEGER) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF n < 0 THEN
        RAISE EXCEPTION 'Invalid length parameter passed to the left function.' USING ERRCODE = '22023';
    END IF;
    RETURN left(s, n);
END $$;

-- TRY_CAST(s AS INT)
CREATE FUNCTION pg_temp.ss_try_int(s TEXT) RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN pg_input_is_valid(s, 'integer') THEN s::INTEGER END $$;

-- DATEDIFF(unit, s, e) — boundary counting
CREATE FUNCTION pg_temp.ss_datediff(u TEXT, s TIMESTAMP, e TIMESTAMP) RETURNS BIGINT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE lower(u)
        WHEN 'year'   THEN (EXTRACT(YEAR FROM e) - EXTRACT(YEAR FROM s))::BIGINT
        WHEN 'month'  THEN ((EXTRACT(YEAR FROM e) - EXTRACT(YEAR FROM s)) * 12
                            + EXTRACT(MONTH FROM e) - EXTRACT(MONTH FROM s))::BIGINT
        WHEN 'week'   THEN (((e::DATE - EXTRACT(DOW FROM e)::INT) - (s::DATE - EXTRACT(DOW FROM s)::INT)) / 7)::BIGINT
        WHEN 'day'    THEN (e::DATE - s::DATE)::BIGINT
        WHEN 'hour'   THEN (EXTRACT(EPOCH FROM date_trunc('hour',   e) - date_trunc('hour',   s)) / 3600)::BIGINT
        WHEN 'minute' THEN (EXTRACT(EPOCH FROM date_trunc('minute', e) - date_trunc('minute', s)) / 60)::BIGINT
        WHEN 'second' THEN  EXTRACT(EPOCH FROM date_trunc('second', e) - date_trunc('second', s))::BIGINT
    END
$$;

-- DATEPART(weekday, d) for a given @@DATEFIRST (default 7 = Sunday first)
CREATE FUNCTION pg_temp.ss_weekday(d DATE, datefirst INTEGER DEFAULT 7) RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$ SELECT ((EXTRACT(DOW FROM d)::INT + 7 - datefirst % 7) % 7) + 1 $$;

-- DATEPART(week, d) under DATEFIRST 7
CREATE FUNCTION pg_temp.ss_week(d DATE) RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
    SELECT (EXTRACT(DOY FROM d)::INT + EXTRACT(DOW FROM date_trunc('year', d))::INT - 1) / 7 + 1
$$;

-- DATEADD(week, DATEDIFF(week, 0, d), 0)
CREATE FUNCTION pg_temp.ss_week_bucket(d TIMESTAMP) RETURNS DATE
LANGUAGE sql IMMUTABLE AS $$ SELECT date_trunc('week', d + INTERVAL '1 day')::DATE $$;

-- CAST(x AS SMALLDATETIME): ≤ 29.998 s rounds down, ≥ 29.999 s rounds up
CREATE FUNCTION pg_temp.ss_smalldatetime(t TIMESTAMP) RETURNS TIMESTAMP
LANGUAGE sql IMMUTABLE AS $$ SELECT date_trunc('minute', t + INTERVAL '30.001 seconds') $$;

-- CAST(x AS DATETIME): rounds to 1/300 second
CREATE FUNCTION pg_temp.ss_datetime(t TIMESTAMP) RETURNS TIMESTAMP
LANGUAGE sql IMMUTABLE AS $$
    SELECT to_timestamp(round(EXTRACT(EPOCH FROM t) * 300) / 300.0) AT TIME ZONE 'UTC'
$$;


-- ============================================================
-- STRINGS AND NULLS
-- ============================================================
\echo '--- corner cases: strings and NULLs'
DO $$
DECLARE s TEXT := 'cc_strings';
BEGIN
    -- CC-01  'a' + NULL
    PERFORM test_assert_equal(s, 'CC-01 ''a'' + NULL → NULL: map + to || [CC-01] [H15] [P7]', 'a' || NULL::TEXT, NULL::TEXT);
    PERFORM test_assert_equal(s, 'CC-01 naive CONCAT(''a'', NULL) = ''a'' — changes results [CC-01]', concat('a', NULL), 'a');
    PERFORM test_assert_equal(s, 'CC-01 CONCAT itself maps 1:1 (both ignore NULL) [CC-01]', concat('a', NULL, 'b'), 'ab');

    -- CC-02 / CC-03  LEN
    PERFORM test_assert_equal(s, 'CC-02 LEN(''abc  '') = 3 [CC-02] [P6]', pg_temp.ss_len('abc  '), 3);
    PERFORM test_assert_equal(s, 'CC-02 naive LENGTH(''abc  '') = 5 [CC-02]', length('abc  '), 5);
    PERFORM test_assert_equal(s, 'CC-03 LEN(''  abc'') = 5 — leading spaces count [CC-03]', pg_temp.ss_len('  abc'), 5);
    PERFORM test_assert_equal(s, 'CC-03 LEN('''') = 0 [CC-03]', pg_temp.ss_len(''), 0);
    PERFORM test_assert_equal(s, 'CC-03 LEN(NULL) = NULL [CC-03]', pg_temp.ss_len(NULL), NULL::INTEGER);

    -- CC-04..CC-07  CHARINDEX
    PERFORM test_assert_equal(s, 'CC-04 CHARINDEX('''', ''abc'') = 0 [CC-04] [P6]', pg_temp.ss_charindex('', 'abc'), 0);
    PERFORM test_assert_equal(s, 'CC-04 naive STRPOS(''abc'', '''') = 1 [CC-04]', strpos('abc', ''), 1);
    PERFORM test_assert_equal(s, 'CC-05 CHARINDEX(''B'', ''abc'') = 2 (CI collation) [CC-05] [P2]', pg_temp.ss_charindex('B', 'abc'), 2);
    PERFORM test_assert_equal(s, 'CC-05 naive STRPOS is case-sensitive → 0 [CC-05]', strpos('abc', 'B'), 0);
    PERFORM test_assert_equal(s, 'CC-06 CHARINDEX(''a'', ''banana'', 3) = 4 [CC-06]', pg_temp.ss_charindex('a', 'banana', 3), 4);
    PERFORM test_assert_equal(s, 'CC-06 CHARINDEX(''x'', ''banana'', 3) = 0 [CC-06]', pg_temp.ss_charindex('x', 'banana', 3), 0);
    PERFORM test_assert_equal(s, 'CC-07 CHARINDEX start ≤ 0 searches from 1 [CC-07]', pg_temp.ss_charindex('a', 'banana', 0), 2);
    PERFORM test_assert_equal(s, 'CC-07 CHARINDEX(NULL, ''abc'') = NULL [CC-07]', pg_temp.ss_charindex(NULL, 'abc'), NULL::INTEGER);

    -- CC-08 REPLICATE
    PERFORM test_assert_equal(s, 'CC-08 REPLICATE(''x'', -1) = NULL [CC-08] [P6]', pg_temp.ss_replicate('x', -1), NULL::TEXT);
    PERFORM test_assert_equal(s, 'CC-08 naive REPEAT(''x'', -1) = '''' [CC-08]', repeat('x', -1), '');
    PERFORM test_assert_equal(s, 'CC-08 REPLICATE(''x'', 0) = '''' [CC-08]', pg_temp.ss_replicate('x', 0), '');

    -- CC-09 LEFT with a negative length
    PERFORM test_assert_equal(s, 'CC-09 naive LEFT(''abc'', -1) = ''ab'' in PG [CC-09]', left('abc', -1), 'ab');
    PERFORM test_assert_raises(s, 'CC-09 SQL Server raises for LEFT(s, -1): guard it [CC-09]',
        'SELECT pg_temp.ss_left(''abc'', -1)', 'Invalid length parameter%');

    -- CC-10 SUBSTRING edge positions (same in both engines)
    PERFORM test_assert_equal(s, 'CC-10 SUBSTRING(''abc'', 0, 2) = ''a'' in both [CC-10]', substring('abc' FROM 0 FOR 2), 'a');
    PERFORM test_assert_equal(s, 'CC-10 SUBSTRING(''abc'', 5, 2) = '''' in both [CC-10]', substring('abc' FROM 5 FOR 2), '');

    -- CC-11 / CC-12 comparison semantics
    PERFORM test_assert_equal(s, 'CC-11 naive ''abc'' = ''abc   '' is FALSE in PG [CC-11]', 'abc'::VARCHAR = 'abc   '::VARCHAR, FALSE);
    PERFORM test_assert_equal(s, 'CC-11 rtrim both sides → TRUE like SQL Server [CC-11] [P2]', rtrim('abc') = rtrim('abc   '), TRUE);
    PERFORM test_assert_equal(s, 'CC-12 naive ''ABC'' = ''abc'' is FALSE in PG [CC-12]', 'ABC'::VARCHAR = 'abc'::VARCHAR, FALSE);
    PERFORM test_assert_equal(s, 'CC-12 lower() = lower() → TRUE like CI collation [CC-12] [P2]', lower('ABC') = lower('abc'), TRUE);

    -- CC-13..CC-15 LIKE
    PERFORM test_assert_equal(s, 'CC-13 naive ''ABC'' LIKE ''a%'' is FALSE [CC-13]', 'ABC' LIKE 'a%', FALSE);
    PERFORM test_assert_equal(s, 'CC-13 ILIKE → TRUE like CI LIKE [CC-13] [P2]', 'ABC' ILIKE 'a%', TRUE);
    PERFORM test_assert_equal(s, 'CC-14 naive LIKE ''[a-c]%'' is literal in PG → FALSE [CC-14]', 'b1' LIKE '[a-c]%', FALSE);
    PERFORM test_assert_equal(s, 'CC-14 LIKE ''[a-c]%'' → ~* ''^[a-c]'' [CC-14]', 'b1' ~* '^[a-c]', TRUE);
    PERFORM test_assert_equal(s, 'CC-14 LIKE ''[^a]%'' → ~* ''^[^a]'' [CC-14]', 'b1' ~* '^[^a]', TRUE);
    PERFORM test_assert_equal(s, 'CC-15 LIKE ''a[_]b'' → LIKE ''a\_b'' matches a_b [CC-15]', 'a_b' LIKE 'a\_b', TRUE);
    PERFORM test_assert_equal(s, 'CC-15 … and not axb [CC-15]', 'axb' LIKE 'a\_b', FALSE);

    -- CC-16 / CC-17 ISNULL typing
    PERFORM test_assert_equal(s, 'CC-16 naive COALESCE keeps ''abcdef'' [CC-16]',
        COALESCE(NULL::VARCHAR(3), 'abcdef')::TEXT, 'abcdef');
    PERFORM test_assert_equal(s, 'CC-16 ISNULL(varchar(3), ''abcdef'') = ''abc'': cast to first type [CC-16] [P5]',
        COALESCE(NULL::VARCHAR(3), 'abcdef')::VARCHAR(3)::TEXT, 'abc');
    PERFORM test_assert_sqlstate(s, 'CC-17 naive COALESCE(int, '''') fails in PG [CC-17]',
        'SELECT COALESCE(NULL::INTEGER, '''')', '22P02');
    PERFORM test_assert_equal(s, 'CC-17 ISNULL(int, '''') = 0 → COALESCE(x, 0) [CC-17] [P5]', COALESCE(NULL::INTEGER, 0), 0);

    -- CC-18 NEWID() as text
    PERFORM test_assert_true(s, 'CC-18 CAST(NEWID() AS VARCHAR(36)) is upper-case → UPPER(uuid::text) [CC-18]',
        upper(gen_random_uuid()::TEXT) ~ '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$');

    -- CC-19 / CC-20 truncation
    PERFORM test_assert_sqlstate(s, 'CC-19 naive VARCHAR(3) variable := ''abcdef'' raises in PG [CC-19]',
        $q$DO $x$ DECLARE v VARCHAR(3) := 'abcdef'; BEGIN NULL; END $x$ $q$, '22001');
    PERFORM test_assert_equal(s, 'CC-19 T-SQL silently truncates variables → explicit ::VARCHAR(3) [CC-19]',
        'abcdef'::VARCHAR(3)::TEXT, 'abc');

    -- CC-22 surrogate pairs
    PERFORM test_assert_equal(s, 'CC-22 char_length(emoji) = 1 in PG (LEN = 2 in SQL Server non-SC) [CC-22]',
        char_length(U&'\+01F600'), 1);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- corner cases: grouping, ordering, constraints'
CREATE TEMP TABLE cc_vals (v VARCHAR(10), n INTEGER);
INSERT INTO cc_vals VALUES ('a', 1), ('a  ', 2), ('B', NULL), ('b', 3), ('A', -2);
DO $$
DECLARE s TEXT := 'cc_grouping';
BEGIN
    -- CC-20 INSERT overflow: an error in both engines
    CREATE TEMP TABLE IF NOT EXISTS cc_short (v VARCHAR(3));
    PERFORM test_assert_sqlstate(s, 'CC-20 INSERT ''abcdef'' into VARCHAR(3) errors in both (22001) [CC-20]',
        'INSERT INTO cc_short VALUES (''abcdef'')', '22001');

    -- CC-21 trailing spaces in GROUP BY
    PERFORM test_assert_equal(s, 'CC-21 naive GROUP BY v: ''a'' and ''a  '' are 2 groups [CC-21]',
        (SELECT COUNT(DISTINCT v) FROM cc_vals WHERE lower(rtrim(v)) = 'a' AND v <> 'A'), 2::BIGINT);
    PERFORM test_assert_equal(s, 'CC-21 GROUP BY rtrim(v) → 1 group like SQL Server [CC-21] [P2]',
        (SELECT COUNT(DISTINCT rtrim(v)) FROM cc_vals WHERE lower(rtrim(v)) = 'a' AND v <> 'A'), 1::BIGINT);

    -- CC-23 case-insensitive ordering
    PERFORM test_assert_equal(s, 'CC-23 naive ORDER BY v COLLATE "C": upper-case first [CC-23]',
        (SELECT string_agg(rtrim(v), ',' ORDER BY v COLLATE "C") FROM cc_vals), 'A,B,a,a,b');
    PERFORM test_assert_equal(s, 'CC-23 ORDER BY lower(v) groups a/A before b/B like CI collation [CC-23] [P2]',
        (SELECT string_agg(lower(rtrim(v)), ',' ORDER BY lower(v), v) FROM cc_vals), 'a,a,a,b,b');

    -- CC-82 NULL ordering
    PERFORM test_assert_equal(s, 'CC-82 naive ORDER BY n: NULL last in PG [CC-82]',
        (SELECT string_agg(COALESCE(n::TEXT, 'NULL'), ',' ORDER BY n) FROM cc_vals), '-2,1,2,3,NULL');
    PERFORM test_assert_equal(s, 'CC-82 ASC NULLS FIRST = SQL Server ASC [CC-82] [P3]',
        (SELECT string_agg(COALESCE(n::TEXT, 'NULL'), ',' ORDER BY n NULLS FIRST) FROM cc_vals), 'NULL,-2,1,2,3');
    PERFORM test_assert_equal(s, 'CC-82 DESC NULLS LAST = SQL Server DESC [CC-82] [P3]',
        (SELECT string_agg(COALESCE(n::TEXT, 'NULL'), ',' ORDER BY n DESC NULLS LAST) FROM cc_vals), '3,2,1,-2,NULL');

    -- CC-40 / CC-41 TOP variants
    PERFORM test_assert_equal(s, 'CC-40 TOP (2) WITH TIES → FETCH FIRST 2 ROWS WITH TIES [CC-40]',
        (SELECT COUNT(*) FROM (SELECT x FROM (VALUES (3), (2), (2), (1)) t(x)
                                ORDER BY x DESC FETCH FIRST 2 ROWS WITH TIES) q), 3::BIGINT);
    PERFORM test_assert_equal(s, 'CC-41 TOP 10 PERCENT of 11 rows = 2 (rounds up) [CC-41]',
        (SELECT COUNT(*) FROM (SELECT g FROM generate_series(1, 11) g ORDER BY g
                                LIMIT (SELECT CEIL(11 * 10 / 100.0))) q), 2::BIGINT);
    PERFORM test_assert_equal(s, 'CC-41 naive COUNT*n/100 = 1 row [CC-41]', (11 * 10 / 100), 1);

    -- CC-81 UNIQUE on a nullable column
    CREATE TEMP TABLE cc_uq_plain (v INTEGER UNIQUE);
    INSERT INTO cc_uq_plain VALUES (NULL), (NULL);
    PERFORM test_assert_equal(s, 'CC-81 naive UNIQUE accepts two NULLs in PG [CC-81]',
        (SELECT COUNT(*) FROM cc_uq_plain), 2::BIGINT);
    CREATE TEMP TABLE cc_uq_nnd (v INTEGER UNIQUE NULLS NOT DISTINCT);
    INSERT INTO cc_uq_nnd VALUES (NULL);
    PERFORM test_assert_sqlstate(s, 'CC-81 UNIQUE NULLS NOT DISTINCT rejects a 2nd NULL like SQL Server [CC-81]',
        'INSERT INTO cc_uq_nnd VALUES (NULL)', '23505');

    -- CC-80 identity after loading explicit keys
    CREATE TEMP TABLE cc_ident (id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, v TEXT);
    INSERT INTO cc_ident (id, v) VALUES (1, 'x'), (2, 'y'), (3, 'z');       -- IDENTITY_INSERT-style load
    PERFORM test_assert_sqlstate(s, 'CC-80 after an explicit-key load the next default collides [CC-80]',
        'INSERT INTO cc_ident (v) VALUES (''new'')', '23505');
    PERFORM setval(pg_get_serial_sequence('cc_ident', 'id'), COALESCE(MAX(id), 0) + 1, false) FROM cc_ident;
    INSERT INTO cc_ident (v) VALUES ('new');
    PERFORM test_assert_equal(s, 'CC-80 setval(…, MAX+1, false) resyncs the identity [CC-80]',
        (SELECT MAX(id) FROM cc_ident), 4);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;


-- ============================================================
-- NUMBERS
-- ============================================================
\echo '--- corner cases: numbers'
DO $$
DECLARE
    s TEXT := 'cc_numbers';
    v_i INTEGER;
    v_t TEXT := '10';
BEGIN
    -- CC-24 / CC-25 / CC-26 decimal → int
    PERFORM test_assert_equal(s, 'CC-24 naive 2.7::INTEGER = 3 (PG rounds) [CC-24]', 2.7::INTEGER, 3);
    PERFORM test_assert_equal(s, 'CC-24 CAST(2.7 AS INT) = 2 → TRUNC(x)::INTEGER [CC-24] [P5]', TRUNC(2.7)::INTEGER, 2);
    PERFORM test_assert_equal(s, 'CC-24 CAST(-2.7 AS INT) = -2 [CC-24]', TRUNC(-2.7)::INTEGER, -2);
    PERFORM test_assert_equal(s, 'CC-25 CAST(2.5 AS INT) = 2, naive gives 3 [CC-25]', TRUNC(2.5)::INTEGER, 2);
    v_i := 2.7;
    PERFORM test_assert_equal(s, 'CC-26 naive INTEGER variable := 2.7 → 3 [CC-26]', v_i, 3);
    v_i := TRUNC(2.7);
    PERFORM test_assert_equal(s, 'CC-26 DECLARE @i INT = 2.7 → 2: assign TRUNC() [CC-26] [P5]', v_i, 2);

    -- CC-27 / CC-28 ROUND
    PERFORM test_assert_equal(s, 'CC-27 naive round(2.5::float8) = 2 (half-even) [CC-27]', round(2.5::FLOAT8), 2::FLOAT8);
    PERFORM test_assert_equal(s, 'CC-27 ROUND(2.5e0, 0) = 3 → round(x::numeric) [CC-27]', round(2.5::FLOAT8::NUMERIC), 3::NUMERIC);
    PERFORM test_assert_equal(s, 'CC-28 ROUND(2.5, 0) = 3 on NUMERIC in both [CC-28]', round(2.5, 0), 3::NUMERIC);
    PERFORM test_assert_equal(s, 'CC-28 ROUND(-2.5, 0) = -3 on NUMERIC in both [CC-28]', round(-2.5, 0), -3::NUMERIC);

    -- CC-29 / CC-30 integer arithmetic (same)
    PERFORM test_assert_equal(s, 'CC-29 7 / 2 = 3 in both [CC-29]', 7 / 2, 3);
    PERFORM test_assert_equal(s, 'CC-29 -7 / 2 = -3 in both (truncates toward 0) [CC-29]', -7 / 2, -3);
    PERFORM test_assert_equal(s, 'CC-30 -7 % 3 = -1 in both [CC-30]', -7 % 3, -1);

    -- CC-31 / CC-32 aggregate result types
    PERFORM test_assert_equal(s, 'CC-31 naive AVG(int) = 1.5 in PG [CC-31]',
        (SELECT AVG(x) FROM (VALUES (1), (2)) t(x)), 1.5);
    PERFORM test_assert_equal(s, 'CC-31 AVG(int) = 1 in SQL Server → TRUNC(AVG(x))::INTEGER [CC-31] [P5]',
        (SELECT TRUNC(AVG(x))::INTEGER FROM (VALUES (1), (2)) t(x)), 1);
    PERFORM test_assert_equal(s, 'CC-31 AVG(-1, -2) = -1 (toward 0) [CC-31]',
        (SELECT TRUNC(AVG(x))::INTEGER FROM (VALUES (-1), (-2)) t(x)), -1);
    PERFORM test_assert_equal(s, 'CC-32 SUM(int) returns BIGINT in PG (no overflow) [CC-32]',
        (SELECT SUM(x) FROM (VALUES (2000000000), (2000000000)) t(x)), 4000000000::BIGINT);
    PERFORM test_assert_sqlstate(s, 'CC-32 ::INTEGER reproduces SQL Server''s INT overflow when required [CC-32]',
        'SELECT SUM(x)::INTEGER FROM (VALUES (2000000000), (2000000000)) t(x)', '22003');

    -- CC-33 / CC-34 decimal scale and MONEY
    PERFORM test_assert_equal(s, 'CC-33 naive 1/3.0 has 20 decimals in PG [CC-33]', scale(1 / 3.0), 20);
    PERFORM test_assert_equal(s, 'CC-33 SQL Server 1/3.0 = 0.333333 → ROUND(…, 6) [CC-33]', round(1 / 3.0, 6), 0.333333);
    PERFORM test_assert_equal(s, 'CC-34 CAST(1.23456 AS MONEY) = 1.2346 → ::NUMERIC(19,4) [CC-34]', 1.23456::NUMERIC(19,4), 1.2346);

    -- CC-35 / CC-36 errors that match
    PERFORM test_assert_sqlstate(s, 'CC-35 divide by zero errors in both (22012) [CC-35]', 'SELECT 1 / 0', '22012');
    PERFORM test_assert_sqlstate(s, 'CC-36 INT overflow errors in both (22003) [CC-36]', 'SELECT 2147483647 + 1', '22003');

    -- CC-37 BIT
    PERFORM test_assert_equal(s, 'CC-37 CAST(5 AS BIT) = 1 → 5::BOOLEAN = TRUE [CC-37]', 5::BOOLEAN, TRUE);
    PERFORM test_assert_sqlstate(s, 'CC-37 naive "flag = 1" is an error on BOOLEAN [CC-37]',
        'SELECT TRUE = 1', '42883');

    -- CC-38 / CC-39 validation helpers
    PERFORM test_assert_equal(s, 'CC-38 ISNUMERIC(''$'') = 1 but pg_input_is_valid → false: review [CC-38]',
        pg_input_is_valid('$', 'numeric'), FALSE);
    PERFORM test_assert_equal(s, 'CC-39 TRY_CAST(''12x'' AS INT) = NULL [CC-39]', pg_temp.ss_try_int('12x'), NULL::INTEGER);
    PERFORM test_assert_equal(s, 'CC-39 TRY_CAST('' 42 '' AS INT) = 42 [CC-39]', pg_temp.ss_try_int(' 42 '), 42);

    -- CC-42 implicit string → number
    PERFORM test_assert_equal(s, 'CC-42 ''10'' + 5 = 15 with a literal in both [CC-42]', '10' + 5, 15);
    PERFORM test_assert_sqlstate(s, 'CC-42 naive text variable + 5 fails in PG [CC-42]',
        $q$DO $x$ DECLARE v TEXT := '10'; r INTEGER; BEGIN r := v + 5; END $x$ $q$, '42883');
    PERFORM test_assert_equal(s, 'CC-42 cast explicitly: v::INTEGER + 5 [CC-42]', v_t::INTEGER + 5, 15);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;


-- ============================================================
-- DATES AND TIMES
-- ============================================================
\echo '--- corner cases: dates and times'
DO $$
DECLARE
    s  TEXT := 'cc_dates';
    t1 TIMESTAMP;
    t2 TIMESTAMP;
BEGIN
    -- CC-43..CC-47 DATEDIFF counts boundaries
    PERFORM test_assert_equal(s, 'CC-43 DATEDIFF(month, Jan 31, Feb 1) = 1 [CC-43] [P4]',
        pg_temp.ss_datediff('month', '2026-01-31', '2026-02-01'), 1::BIGINT);
    PERFORM test_assert_equal(s, 'CC-43 naive AGE() months = 0 [CC-43]',
        EXTRACT(MONTH FROM AGE('2026-02-01'::TIMESTAMP, '2026-01-31'::TIMESTAMP))::BIGINT, 0::BIGINT);
    PERFORM test_assert_equal(s, 'CC-44 DATEDIFF(year, 2025-12-31, 2026-01-01) = 1 [CC-44] [P4]',
        pg_temp.ss_datediff('year', '2025-12-31', '2026-01-01'), 1::BIGINT);
    PERFORM test_assert_equal(s, 'CC-44 naive AGE() years = 0 [CC-44]',
        EXTRACT(YEAR FROM AGE('2026-01-01'::TIMESTAMP, '2025-12-31'::TIMESTAMP))::BIGINT, 0::BIGINT);
    PERFORM test_assert_equal(s, 'CC-45 DATEDIFF(day) across midnight (2 minutes) = 1 [CC-45] [P4]',
        pg_temp.ss_datediff('day', '2026-01-01 23:59', '2026-01-02 00:01'), 1::BIGINT);
    PERFORM test_assert_equal(s, 'CC-45 naive EXTRACT(DAY FROM e - s) = 0 [CC-45]',
        EXTRACT(DAY FROM ('2026-01-02 00:01'::TIMESTAMP - '2026-01-01 23:59'::TIMESTAMP))::BIGINT, 0::BIGINT);
    PERFORM test_assert_equal(s, 'CC-45 negative spans stay negative [CC-45]',
        pg_temp.ss_datediff('day', '2026-01-02', '2026-01-01'), -1::BIGINT);
    PERFORM test_assert_equal(s, 'CC-46 DATEDIFF(week, Sat, Sun) = 1 (Sunday boundary) [CC-46] [P11]',
        pg_temp.ss_datediff('week', '2025-06-07', '2025-06-08'), 1::BIGINT);
    PERFORM test_assert_equal(s, 'CC-46 DATEDIFF(week, Sun, next Sat) = 0 [CC-46]',
        pg_temp.ss_datediff('week', '2025-06-08', '2025-06-14'), 0::BIGINT);
    PERFORM test_assert_equal(s, 'CC-47 DATEDIFF(hour, 09:55, 10:05) = 1 [CC-47] [P4]',
        pg_temp.ss_datediff('hour', '2026-01-01 09:55', '2026-01-01 10:05'), 1::BIGINT);
    PERFORM test_assert_equal(s, 'CC-47 naive epoch/3600 = 0 [CC-47]',
        (EXTRACT(EPOCH FROM '2026-01-01 10:05'::TIMESTAMP - '2026-01-01 09:55'::TIMESTAMP) / 3600)::INTEGER::BIGINT, 0::BIGINT);
    PERFORM test_assert_equal(s, 'CC-47 DATEDIFF(minute, 10:00:59, 10:01:00) = 1 [CC-47]',
        pg_temp.ss_datediff('minute', '2026-01-01 10:00:59', '2026-01-01 10:01:00'), 1::BIGINT);

    -- CC-48 / CC-49 month arithmetic (same in both)
    PERFORM test_assert_equal(s, 'CC-48 DATEADD(month, 1, Jan 31) = Feb 28 in both [CC-48]',
        ('2026-01-31'::DATE + INTERVAL '1 month')::DATE, '2026-02-28'::DATE);
    PERFORM test_assert_equal(s, 'CC-48 leap year: DATEADD(month, 1, 2024-01-31) = 2024-02-29 [CC-48]',
        ('2024-01-31'::DATE + INTERVAL '1 month')::DATE, '2024-02-29'::DATE);
    PERFORM test_assert_equal(s, 'CC-48 DATEADD(year, 1, 2024-02-29) = 2025-02-28 [CC-48]',
        ('2024-02-29'::DATE + INTERVAL '1 year')::DATE, '2025-02-28'::DATE);
    PERFORM test_assert_equal(s, 'CC-49 EOMONTH(2024-02-10) = 2024-02-29 [CC-49]',
        (DATE_TRUNC('month', '2024-02-10'::TIMESTAMP) + INTERVAL '1 month - 1 day')::DATE, '2024-02-29'::DATE);
    PERFORM test_assert_equal(s, 'CC-49 EOMONTH(2026-01-15, 1) = 2026-02-28 [CC-49]',
        (DATE_TRUNC('month', '2026-01-15'::TIMESTAMP) + INTERVAL '1 month' * 2 - INTERVAL '1 day')::DATE, '2026-02-28'::DATE);

    -- CC-50 / CC-51 / CC-52 week logic depends on Sunday and DATEFIRST
    PERFORM test_assert_equal(s, 'CC-50 DATEPART(weekday, Sunday) = 1 (DATEFIRST 7) [CC-50] [P11]',
        pg_temp.ss_weekday('2026-09-13'), 1);
    PERFORM test_assert_equal(s, 'CC-50 DATEPART(weekday, Saturday) = 7 [CC-50]', pg_temp.ss_weekday('2026-09-12'), 7);
    PERFORM test_assert_equal(s, 'CC-50 naive EXTRACT(DOW, Sunday) = 0 [CC-50]', EXTRACT(DOW FROM '2026-09-13'::DATE)::INTEGER, 0);
    PERFORM test_assert_equal(s, 'CC-50 SET DATEFIRST 1: Monday = 1, Sunday = 7 [CC-50]',
        pg_temp.ss_weekday('2026-09-14', 1) * 10 + pg_temp.ss_weekday('2026-09-13', 1), 17);
    PERFORM test_assert_equal(s, 'CC-51 DATEPART(week, 2026-01-04 Sun) = 2 [CC-51] [P11]', pg_temp.ss_week('2026-01-04'), 2);
    PERFORM test_assert_equal(s, 'CC-51 DATEPART(week, 2025-12-31) = 53 [CC-51]', pg_temp.ss_week('2025-12-31'), 53);
    PERFORM test_assert_equal(s, 'CC-51 naive EXTRACT(WEEK) is ISO: 2025-12-31 → 1 [CC-51]',
        EXTRACT(WEEK FROM '2025-12-31'::DATE)::INTEGER, 1);
    PERFORM test_assert_equal(s, 'CC-52 week bucket: Sunday → FOLLOWING Monday [CC-52] [P11]',
        pg_temp.ss_week_bucket('2025-06-22 11:00'), '2025-06-23'::DATE);
    PERFORM test_assert_equal(s, 'CC-52 week bucket: Saturday → its Monday [CC-52]',
        pg_temp.ss_week_bucket('2025-06-21 11:00'), '2025-06-16'::DATE);
    PERFORM test_assert_equal(s, 'CC-52 naive date_trunc(week, Sunday) = previous Monday [CC-52]',
        date_trunc('week', '2025-06-22 11:00'::TIMESTAMP)::DATE, '2025-06-16'::DATE);

    -- CC-53 / CC-54 data-type rounding
    PERFORM test_assert_equal(s, 'CC-53 CAST(''…23:59:59.999'' AS DATETIME) rounds to next day [CC-53]',
        pg_temp.ss_datetime('2026-01-01 23:59:59.999'), '2026-01-02 00:00:00'::TIMESTAMP);
    PERFORM test_assert_equal(s, 'CC-53 naive TIMESTAMP(3) keeps 23:59:59.999 [CC-53]',
        '2026-01-01 23:59:59.999'::TIMESTAMP(3)::DATE, '2026-01-01'::DATE);
    PERFORM test_assert_equal(s, 'CC-54 SMALLDATETIME: 10:00:29.998 rounds down [CC-54]',
        pg_temp.ss_smalldatetime('2026-01-01 10:00:29.998'), '2026-01-01 10:00'::TIMESTAMP);
    PERFORM test_assert_equal(s, 'CC-54 SMALLDATETIME: 10:00:29.999 rounds up [CC-54]',
        pg_temp.ss_smalldatetime('2026-01-01 10:00:29.999'), '2026-01-01 10:01'::TIMESTAMP);
    PERFORM test_assert_equal(s, 'CC-54 naive TIMESTAMP(0) keeps 10:00:30 [CC-54]',
        '2026-01-01 10:00:30'::TIMESTAMP(0), '2026-01-01 10:00:30'::TIMESTAMP);

    -- CC-55 / CC-56 formatting
    PERFORM test_assert_equal(s, 'CC-55 CONVERT(VARCHAR(10), dt, 120) = date only → LEFT(TO_CHAR(…), 10) [CC-55] [P6]',
        left(to_char('2026-07-30 18:45:00'::TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'), 10), '2026-07-30');
    PERFORM test_assert_equal(s, 'CC-56 FORMAT(d, ''MMM d, yyyy'') → ''Mon FMDD, YYYY'' [CC-56]',
        to_char('2025-06-01'::DATE, 'Mon FMDD, YYYY'), 'Jun 1, 2025');
    PERFORM test_assert_equal(s, 'CC-56 naive ''Mon DD'' zero-pads [CC-56]',
        to_char('2025-06-01'::DATE, 'Mon DD, YYYY'), 'Jun 01, 2025');

    -- CC-57 BETWEEN with a DATE upper bound (same in both — preserve it)
    PERFORM test_assert_equal(s, 'CC-57 18:45 on the end date is outside BETWEEN … AND date [CC-57] [P10]',
        '2026-06-30 18:45'::TIMESTAMP BETWEEN '2026-06-01'::DATE AND '2026-06-30'::DATE, FALSE);

    -- CC-58 GETDATE() vs LOCALTIMESTAMP vs clock_timestamp()
    t1 := LOCALTIMESTAMP; PERFORM pg_sleep(0.02); t2 := LOCALTIMESTAMP;
    PERFORM test_assert_equal(s, 'CC-58 LOCALTIMESTAMP is frozen for the transaction [CC-58] [P8]', t2 - t1, INTERVAL '0');
    t1 := clock_timestamp(); PERFORM pg_sleep(0.02); t2 := clock_timestamp();
    PERFORM test_assert_true(s, 'CC-58 clock_timestamp() advances (SYSDATETIME) [CC-58] [P8]', t2 > t1);

    -- CC-59 invalid dates
    PERFORM test_assert_sqlstate(s, 'CC-59 DATEFROMPARTS(2026, 2, 30) errors in both [CC-59]',
        'SELECT make_date(2026, 2, 30)', '22008');
    PERFORM test_assert_equal(s, 'CC-59 ISDATE(''2026-02-30'') = 0 → pg_input_is_valid [CC-59]',
        pg_input_is_valid('2026-02-30', 'date'), FALSE);

    -- CC-60 DATETIMEOFFSET loses the original offset
    PERFORM set_config('TimeZone', 'UTC', true);
    PERFORM test_assert_equal(s, 'CC-60 TIMESTAMPTZ keeps the instant … [CC-60]',
        '2026-01-01 10:00:00+05:30'::TIMESTAMPTZ AT TIME ZONE 'UTC', '2026-01-01 04:30:00'::TIMESTAMP);
    PERFORM test_assert_equal(s, 'CC-60 … but not the +05:30 offset: store it separately [CC-60]',
        EXTRACT(TIMEZONE_HOUR FROM '2026-01-01 10:00:00+05:30'::TIMESTAMPTZ)::INTEGER, 0);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;


-- ============================================================
-- PROCEDURAL SEMANTICS
-- ============================================================
\echo '--- corner cases: procedural semantics'

-- Helpers for CC-65 / CC-70 / CC-71 / CC-72 / CC-73 / CC-74 / CC-87
CREATE TEMP TABLE cc_log (msg TEXT);
CREATE TEMP TABLE cc_target (v INTEGER PRIMARY KEY);

CREATE FUNCTION pg_temp.cc_log_then_raise() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        PERFORM 1 / 0;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO cc_log VALUES ('logged: ' || SQLERRM);   -- CATCH: log …
        RAISE;                                                -- … then THROW
    END;
END $$;

CREATE FUNCTION pg_temp.cc_two_inserts() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cc_target VALUES (1);
    INSERT INTO cc_target VALUES (1);    -- duplicate → error
END $$;

CREATE FUNCTION pg_temp.cc_temp_plain() RETURNS void LANGUAGE plpgsql AS $$
BEGIN CREATE TEMP TABLE cc_scratch_plain (x INTEGER); END $$;

CREATE FUNCTION pg_temp.cc_temp_ifne() RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS cc_scratch_ok (x INTEGER);
    TRUNCATE cc_scratch_ok;
    INSERT INTO cc_scratch_ok VALUES (1);
    RETURN (SELECT COUNT(*) FROM cc_scratch_ok);
END $$;

CREATE FUNCTION pg_temp.cc_temp_on_commit_drop() RETURNS void LANGUAGE plpgsql AS $$
BEGIN CREATE TEMP TABLE cc_scratch_ocd (x INTEGER) ON COMMIT DROP; END $$;

CREATE FUNCTION pg_temp.cc_ambiguous() RETURNS TABLE(v INTEGER) LANGUAGE plpgsql AS $$
BEGIN RETURN QUERY SELECT v FROM cc_target; END $$;

CREATE FUNCTION pg_temp.cc_qualified() RETURNS TABLE(v INTEGER) LANGUAGE plpgsql AS $$
BEGIN RETURN QUERY SELECT t.v FROM cc_target t; END $$;

CREATE FUNCTION pg_temp.cc_wrong_type() RETURNS TABLE(x VARCHAR) LANGUAGE plpgsql AS $$
BEGIN RETURN QUERY SELECT 'a'::TEXT; END $$;

CREATE FUNCTION pg_temp.cc_typmod() RETURNS TABLE(x NUMERIC(19,4)) LANGUAGE plpgsql AS $$
BEGIN RETURN QUERY SELECT 1 / 3.0; END $$;

DO $$
DECLARE
    s        TEXT := 'cc_procedural';
    v        INTEGER;
    v_tmp    INTEGER;
    v_n      INTEGER;
    v_done   INTEGER := 0;
    v_errs   INTEGER := 0;
    v_detail TEXT;
    v_state  TEXT;
    v_found  BOOLEAN;
    x        INTEGER;
BEGIN
    -- CC-61 no-row assignment
    v := 5;
    SELECT 1 INTO v FROM (SELECT 1) t WHERE FALSE;
    PERFORM test_assert_equal(s, 'CC-61 naive SELECT … INTO with no row sets NULL [CC-61]', v, NULL::INTEGER);
    v := 5;
    SELECT 1 INTO v_tmp FROM (SELECT 1) t WHERE FALSE;
    IF FOUND THEN v := v_tmp; END IF;
    PERFORM test_assert_equal(s, 'CC-61 SELECT @v = … with no row keeps @v → IF FOUND pattern [CC-61] [P1]', v, 5);

    -- CC-62 multi-row assignment keeps the LAST row
    SELECT t.x INTO v FROM (VALUES (1), (2), (3)) t(x) ORDER BY t.x;
    PERFORM test_assert_equal(s, 'CC-62 naive SELECT … INTO takes the FIRST row [CC-62]', v, 1);
    SELECT t.x INTO v FROM (VALUES (1), (2), (3)) t(x) ORDER BY t.x DESC LIMIT 1;
    PERFORM test_assert_equal(s, 'CC-62 T-SQL keeps the LAST row → reverse ORDER BY + LIMIT 1 [CC-62] [P1]', v, 3);

    -- CC-63 SET @v = (subquery) with several rows: an error in both
    PERFORM test_assert_sqlstate(s, 'CC-63 scalar subquery returning 2 rows errors in both (21000) [CC-63]',
        'SELECT (SELECT x FROM (VALUES (1), (2)) t(x))', '21000');

    -- CC-64 @@ROWCOUNT
    UPDATE cc_target t SET v = t.v WHERE t.v = -999;
    v_found := FOUND;                         -- read FOUND / ROW_COUNT immediately
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM test_assert_equal(s, 'CC-64 @@ROWCOUNT after a no-op UPDATE = 0 → GET DIAGNOSTICS [CC-64]', v_n, 0);
    PERFORM test_assert_equal(s, 'CC-64 … and FOUND is false right after the UPDATE [CC-64]', v_found, FALSE);
    PERFORM test_assert_equal(s, 'CC-64 FOUND is reset by the next PERFORM — capture it at once, like @@ROWCOUNT [CC-64]', FOUND, TRUE);

    -- CC-65 log in CATCH, then re-raise
    PERFORM test_assert_raises(s, 'CC-65 re-raise propagates the original error [CC-65]',
        'SELECT pg_temp.cc_log_then_raise()', 'division by zero');
    PERFORM test_assert_equal(s, 'CC-65 … and ROLLS BACK the log row (it survives in SQL Server) → PROCEDURE + COMMIT [CC-65] [P9]',
        (SELECT COUNT(*) FROM cc_log), 0::BIGINT);

    -- CC-66 log-and-continue loop
    FOR x IN SELECT g FROM generate_series(1, 3) g LOOP
        BEGIN
            IF x = 2 THEN PERFORM 1 / 0; END IF;
            v_done := v_done + 1;
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
        END;
    END LOOP;
    PERFORM test_assert_equal(s, 'CC-66 per-row TRY/CATCH → nested BEGIN … EXCEPTION: 2 done, 1 failed [CC-66]',
        v_done * 10 + v_errs, 21);

    -- CC-68 / CC-69 error codes
    INSERT INTO cc_target VALUES (42);
    PERFORM test_assert_sqlstate(s, 'CC-68 unique violation (SQL Server 2627/2601) → SQLSTATE 23505 [CC-68]',
        'INSERT INTO cc_target VALUES (42)', '23505');
    BEGIN
        RAISE EXCEPTION 'Insufficient stock.' USING ERRCODE = 'P0001', DETAIL = 'SQL Server error 50001';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_detail = PG_EXCEPTION_DETAIL;
    END;
    PERFORM test_assert_equal(s, 'CC-69 THROW 50001 → SQLSTATE P0001 … [CC-69]', v_state, 'P0001');
    PERFORM test_assert_equal(s, 'CC-69 … with the SQL Server number in DETAIL [CC-69]', v_detail, 'SQL Server error 50001');

    -- CC-70 / CC-71 temp tables inside routines
    PERFORM pg_temp.cc_temp_plain();
    PERFORM test_assert_sqlstate(s, 'CC-70 plain CREATE TEMP TABLE fails on the 2nd call (42P07) [CC-70] [H10]',
        'SELECT pg_temp.cc_temp_plain()', '42P07');
    PERFORM test_assert_equal(s, 'CC-70 IF NOT EXISTS + TRUNCATE: 2nd call works and starts empty [CC-70] [H10]',
        pg_temp.cc_temp_ifne() + pg_temp.cc_temp_ifne(), 2);
    PERFORM pg_temp.cc_temp_on_commit_drop();
    PERFORM test_assert_sqlstate(s, 'CC-71 ON COMMIT DROP twice in one transaction fails (42P07) [CC-71] [H10]',
        'SELECT pg_temp.cc_temp_on_commit_drop()', '42P07');

    -- CC-72 / CC-73 / CC-74 RETURNS TABLE pitfalls
    PERFORM test_assert_sqlstate(s, 'CC-72 unqualified column named like an OUT column → 42702 [CC-72] [H11]',
        'SELECT * FROM pg_temp.cc_ambiguous()', '42702');
    PERFORM test_assert_equal(s, 'CC-72 alias-qualified version works [CC-72] [H11]',
        (SELECT COUNT(*) FROM pg_temp.cc_qualified()), 1::BIGINT);
    PERFORM test_assert_sqlstate(s, 'CC-73 text returned for a VARCHAR column → 42804 [CC-73] [H12]',
        'SELECT * FROM pg_temp.cc_wrong_type()', '42804');
    PERFORM test_assert_equal(s, 'CC-74 RETURNS TABLE NUMERIC(19,4) does not round: scale 20 [CC-74] [H12]',
        (SELECT scale(t.x) FROM pg_temp.cc_typmod() t), 20);

    -- CC-75 parameter defaults
    PERFORM test_assert_sqlstate(s, 'CC-75 a required parameter after a defaulted one is rejected (42P13) [CC-75]',
        'CREATE FUNCTION pg_temp.cc_bad(a INTEGER DEFAULT 1, b INTEGER) RETURNS INTEGER LANGUAGE sql AS ''SELECT 1''',
        '42P13');

    -- CC-87 atomic function vs. SQL Server autocommit without BEGIN TRAN
    PERFORM test_assert_sqlstate(s, 'CC-87 2nd INSERT fails (23505) … [CC-87]', 'SELECT pg_temp.cc_two_inserts()', '23505');
    PERFORM test_assert_equal(s, 'CC-87 … and the 1st INSERT is rolled back too (SQL Server keeps it) [CC-87] [P9]',
        (SELECT COUNT(*) FROM cc_target t WHERE t.v = 1), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

-- CC-76 recursive CTE over cyclic data
\echo '--- corner cases: recursion'
CREATE TEMP TABLE cc_edges (parent INTEGER, child INTEGER);
INSERT INTO cc_edges VALUES (1, 2), (2, 1);                  -- a cycle
DO $$
DECLARE s TEXT := 'cc_recursion';
BEGIN
    PERFORM test_assert_equal(s, 'CC-76 depth predicate stops a cycle (SQL Server stops at MAXRECURSION 100) [CC-76]',
        (WITH RECURSIVE walk AS (
             SELECT e.child, 1 AS lvl FROM cc_edges e WHERE e.parent = 1
             UNION ALL
             SELECT e.child, w.lvl + 1 FROM cc_edges e JOIN walk w ON e.parent = w.child WHERE w.lvl < 10)
         SELECT COUNT(*) FROM walk), 10::BIGINT);
    PERFORM test_assert_equal(s, 'CC-76 or CYCLE … SET … USING (PG 14+) stops at the first repeat [CC-76]',
        (WITH RECURSIVE walk AS (
             SELECT e.child FROM cc_edges e WHERE e.parent = 1
             UNION ALL
             SELECT e.child FROM cc_edges e JOIN walk w ON e.parent = w.child)
         CYCLE child SET is_cycle USING path
         SELECT COUNT(*) FROM walk WHERE NOT is_cycle), 2::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;
