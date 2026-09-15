# Corner-case catalog: SQL Server → PostgreSQL

Each row is a behaviour where a "looks equivalent" translation returns a **different
result**, or where both engines agree and no change should be made. The
**SQL Server** column is the value the converted code must reproduce, assuming the
defaults: `SQL_Latin1_General_CP1_CI_AS`, `SET DATEFIRST 7`, `us_english`, ANSI
settings ON.

- Every `auto` row is executed by `scripts/tests/corner_case_tests.sql` or
  `scripts/tests/example_tests.sql`; the test names carry the `[CC-nn]` tag.
- `manual` rows cannot be reproduced in PostgreSQL alone. Flag them in review.
- `scripts/check_rule_coverage.py` fails the self-test if an `auto` row has no test.
- Rule column: `Hn` = hard rule, `Pn` = parity rule, in `.kiro/steering/migration.md`.

## Strings and NULLs

| ID | T-SQL | SQL Server | Naive PostgreSQL | Correct PostgreSQL | Rule | Test |
|---|---|---|---|---|---|---|
| CC-01 | `'a' + NULL` | `NULL` | `CONCAT('a', NULL)` = `'a'` | `'a' \|\| NULL` | H15 P7 | auto |
| CC-02 | `LEN('abc  ')` | `3` | `LENGTH` = 5 | `char_length(rtrim(s))` | P6 | auto |
| CC-03 | `LEN('  abc')`, `LEN('')`, `LEN(NULL)` | `5`, `0`, `NULL` | — | `char_length(rtrim(s))` | P6 | auto |
| CC-04 | `CHARINDEX('', 'abc')` | `0` | `STRPOS('abc', '')` = 1 | `CASE WHEN n = '' THEN 0 …` | P6 | auto |
| CC-05 | `CHARINDEX('B', 'abc')` | `2` (CI) | `STRPOS` = 0 | `STRPOS(lower(h), lower(n))` | P2 | auto |
| CC-06 | `CHARINDEX('a', 'banana', 3)` | `4` | — | `p + start - 1` on `STRPOS(SUBSTRING(h FROM start), n)` | P6 | auto |
| CC-07 | `CHARINDEX('a', 'banana', 0)` / `CHARINDEX(NULL, s)` | `2` / `NULL` | — | `GREATEST(start, 1)`; NULL in → NULL out | P6 | auto |
| CC-08 | `REPLICATE('x', -1)` | `NULL` | `REPEAT` = `''` | `CASE WHEN n >= 0 THEN REPEAT(s, n) END` | P6 | auto |
| CC-09 | `LEFT('abc', -1)` | error | `LEFT` = `'ab'` | guard `n < 0` → `RAISE` (22023) | P6 | auto |
| CC-10 | `SUBSTRING('abc', 0, 2)`, `SUBSTRING('abc', 5, 2)` | `'a'`, `''` | same | same — no change | — | auto |
| CC-11 | `'abc' = 'abc   '` | `TRUE` | `FALSE` | `rtrim(a) = rtrim(b)` (or `CHAR(n)`) | P2 | auto |
| CC-12 | `'ABC' = 'abc'` | `TRUE` (CI) | `FALSE` | `lower(a) = lower(b)` or `citext` | P2 | auto |
| CC-13 | `'ABC' LIKE 'a%'` | `TRUE` | `FALSE` | `ILIKE` | P2 | auto |
| CC-14 | `'b1' LIKE '[a-c]%'`, `'[^a]%'` | `TRUE` | `FALSE` (brackets literal) | `~* '^[a-c]'`, `~* '^[^a]'` | — | auto |
| CC-15 | `LIKE 'a[_]b'` | matches `a_b` only | `LIKE 'a_b'` also matches `axb` | `LIKE 'a\_b'` | — | auto |
| CC-16 | `ISNULL(CAST(NULL AS VARCHAR(3)), 'abcdef')` | `'abc'` | `COALESCE` = `'abcdef'` | `COALESCE(a, b)::VARCHAR(3)` | P5 | auto |
| CC-17 | `ISNULL(NULL_int, '')` | `0` | error 22P02 | `COALESCE(x, 0)` | P5 | auto |
| CC-18 | `CAST(NEWID() AS VARCHAR(36))` | upper-case | lower-case | `upper(gen_random_uuid()::text)` | — | auto |
| CC-19 | `DECLARE @v VARCHAR(3) = 'abcdef'` | `'abc'` (silent) | error 22001 | `LEFT(x, 3)` / `x::VARCHAR(3)` | — | auto |
| CC-20 | `INSERT 'abcdef'` into `VARCHAR(3)` | error | error 22001 | same — no change | — | auto |
| CC-21 | `GROUP BY v` with `'a'` and `'a  '` | 1 group | 2 groups | `GROUP BY rtrim(v)` | P2 | auto |
| CC-22 | `LEN(N'😀')` (non-SC collation) | `2` | `char_length` = 1 | flag if lengths drive logic | — | auto |
| CC-23 | `ORDER BY v` (CI) | `a/A` before `b/B` | collation-dependent (`C`: `A,B,a,b`) | `ORDER BY lower(v), v` | P2 | auto |

## Numbers

| ID | T-SQL | SQL Server | Naive PostgreSQL | Correct PostgreSQL | Rule | Test |
|---|---|---|---|---|---|---|
| CC-24 | `CAST(2.7 AS INT)`, `CAST(-2.7 AS INT)` | `2`, `-2` | `::INTEGER` = 3, -3 | `TRUNC(x)::INTEGER` | P5 | auto |
| CC-25 | `CAST(2.5 AS INT)` | `2` | `3` | `TRUNC(x)::INTEGER` | P5 | auto |
| CC-26 | `DECLARE @i INT = 2.7` | `2` | `v_i := 2.7` → 3 | `v_i := TRUNC(2.7)` | P5 | auto |
| CC-27 | `ROUND(CAST(2.5 AS FLOAT), 0)` | `3` | `round(float8)` = 2 (half-even) | `round(x::numeric)` | — | auto |
| CC-28 | `ROUND(2.5, 0)`, `ROUND(-2.5, 0)` (decimal) | `3`, `-3` | same | same — no change | — | auto |
| CC-29 | `7 / 2`, `-7 / 2` | `3`, `-3` | same | same — no change | — | auto |
| CC-30 | `-7 % 3` | `-1` | same | same — no change | — | auto |
| CC-31 | `AVG(int_col)` over 1, 2 | `1` (INT) | `1.5` | `TRUNC(AVG(x))::INTEGER` | P5 | auto |
| CC-32 | `SUM(int_col)` > 2³¹ | overflow error | BIGINT result | accept (flag) or `::INTEGER` to keep the error | — | auto |
| CC-33 | `1 / 3.0` | `0.333333` (scale 6) | 20 decimals | `ROUND(expr, 6)` when returned untyped | — | auto |
| CC-34 | `CAST(1.23456 AS MONEY)` | `1.2346` | — | `::NUMERIC(19,4)` | — | auto |
| CC-35 | `1 / 0` | error | error 22012 | same — no change | — | auto |
| CC-36 | `2147483647 + 1` | error | error 22003 | same — no change | — | auto |
| CC-37 | `CAST(5 AS BIT)`; `WHERE flag = 1` | `1`; valid | `flag = 1` → error 42883 | `5::BOOLEAN`; `WHERE flag` | — | auto |
| CC-38 | `ISNUMERIC('$')` | `1` | `pg_input_is_valid('$','numeric')` = false | review each use; no exact equivalent | — | auto |
| CC-39 | `TRY_CAST('12x' AS INT)` | `NULL` | error | `CASE WHEN pg_input_is_valid(s,'integer') THEN s::INTEGER END` | — | auto |
| CC-40 | `TOP (2) WITH TIES` | ties included | `LIMIT 2` drops ties | `FETCH FIRST 2 ROWS WITH TIES` | — | auto |
| CC-41 | `TOP 10 PERCENT` of 11 rows | 2 rows | `COUNT*n/100` = 1 | `LIMIT CEIL(COUNT(*) * n / 100.0)` | — | auto |
| CC-42 | `'10' + 5`; `@txt + 5` | `15`; `15` | literal ok; text variable → error | `v::INTEGER + 5` | — | auto |

## Dates and times

| ID | T-SQL | SQL Server | Naive PostgreSQL | Correct PostgreSQL | Rule | Test |
|---|---|---|---|---|---|---|
| CC-43 | `DATEDIFF(month, '2026-01-31', '2026-02-01')` | `1` | `AGE()` → 0 | year×12 + month difference | P4 | auto |
| CC-44 | `DATEDIFF(year, '2025-12-31', '2026-01-01')` | `1` | `AGE()` → 0 | year difference | P4 | auto |
| CC-45 | `DATEDIFF(day, 23:59, 00:01 next day)` | `1` | `EXTRACT(DAY FROM e - s)` = 0 | `e::DATE - s::DATE` | P4 | auto |
| CC-46 | `DATEDIFF(week, Sat, Sun)` | `1` | — | Sunday-boundary formula | P11 | auto |
| CC-47 | `DATEDIFF(hour, 09:55, 10:05)` | `1` | epoch/3600 = 0 | difference of `date_trunc('hour', …)` | P4 | auto |
| CC-48 | `DATEADD(month, 1, '2026-01-31')`, leap years | Feb 28 / Feb 29 | same | `+ INTERVAL` — no change | — | auto |
| CC-49 | `EOMONTH(d [, n])` | last day | — | `DATE_TRUNC('month', d) + INTERVAL '1 month' * (n+1) - INTERVAL '1 day'` | — | auto |
| CC-50 | `DATEPART(weekday, Sunday)` | `1` (DATEFIRST 7) | `EXTRACT(DOW)` = 0 | `((DOW + 7 - @@DATEFIRST % 7) % 7) + 1` | P11 | auto |
| CC-51 | `DATEPART(week, '2025-12-31')` | `53` | ISO `EXTRACT(WEEK)` = 1 | DOY-based formula | P11 | auto |
| CC-52 | `DATEADD(week, DATEDIFF(week, 0, Sun), 0)` | next Monday | `date_trunc('week')` = previous Monday | `date_trunc('week', d + INTERVAL '1 day')` | P11 | auto |
| CC-53 | `CAST('…23:59:59.999' AS DATETIME)` | next day 00:00:00.000 | kept as .999 | flag range predicates; half-open ranges | — | auto |
| CC-54 | `CAST('10:00:29.999' AS SMALLDATETIME)` | `10:01` | `TIMESTAMP(0)` keeps seconds | `date_trunc('minute', t + INTERVAL '30.001 seconds')` | — | auto |
| CC-55 | `CONVERT(VARCHAR(10), dt, 120)` | `'2026-07-30'` | full timestamp | `LEFT(TO_CHAR(dt, 'YYYY-MM-DD HH24:MI:SS'), 10)` | P6 | auto |
| CC-56 | `FORMAT(d, 'MMM d, yyyy')` | `'Jun 1, 2025'` | `'Mon DD'` → `'Jun 01'` | `'Mon FMDD, YYYY'` | — | auto |
| CC-57 | `ts BETWEEN @d1 AND @dateOnly` | excludes later times on the end day | same | same — preserve, flag if unintended | P10 | auto |
| CC-58 | `GETDATE()` twice in one proc | advances | `LOCALTIMESTAMP` frozen | `clock_timestamp()::TIMESTAMP` where time must advance | P8 | auto |
| CC-59 | `DATEFROMPARTS(2026, 2, 30)` / `ISDATE('2026-02-30')` | error / `0` | — | `make_date` (error 22008) / `pg_input_is_valid(s, 'date')` | — | auto |
| CC-60 | `DATETIMEOFFSET '…+05:30'` | offset kept | `TIMESTAMPTZ` keeps instant only | store the offset in its own column | — | auto |

## Procedural semantics

| ID | T-SQL | SQL Server | Naive PostgreSQL | Correct PostgreSQL | Rule | Test |
|---|---|---|---|---|---|---|
| CC-61 | `SELECT @v = col … ` (no row) | `@v` unchanged | `SELECT INTO` → NULL | scratch variable + `IF FOUND THEN v := tmp` | P1 | auto |
| CC-62 | `SELECT @v = col … ORDER BY k` (many rows) | last row | first row | `ORDER BY k DESC LIMIT 1` | P1 | auto |
| CC-63 | `SET @v = (SELECT …)` returning 2 rows | error | error 21000 | same — no change | — | auto |
| CC-64 | `@@ROWCOUNT` after a no-op UPDATE | `0` | — | `GET DIAGNOSTICS` / `FOUND`, read **immediately** (a later `PERFORM` resets `FOUND`) | — | auto |
| CC-65 | CATCH: log, then `THROW` | log row kept | re-raise rolls the log back | PROCEDURE: log, `COMMIT`, then `RAISE` (example 14) | P9 | auto |
| CC-66 | per-row TRY/CATCH, continue | other rows processed | — | nested `BEGIN … EXCEPTION … END` in the loop | — | auto |
| CC-67 | `RAISERROR(…, 16, 1)` outside TRY, no `RETURN` after it | error sent, execution **continues** | `RAISE EXCEPTION` stops | restructure; decide per call site | P9 | manual |
| CC-68 | unique violation (2627 / 2601) | error number 2627 | SQLSTATE `23505` | map error numbers → SQLSTATEs in callers | — | auto |
| CC-69 | `THROW 50001, 'msg', 1` | error 50001 | — | `RAISE EXCEPTION 'msg' USING ERRCODE = 'P0001', DETAIL = 'SQL Server error 50001'` | — | auto |
| CC-70 | `CREATE TABLE #t` in a proc called twice | fine (dropped at exit) | 2nd call: 42P07 | `CREATE TEMP TABLE IF NOT EXISTS` + `TRUNCATE` | H10 | auto |
| CC-71 | same, converted with `ON COMMIT DROP` | fine | 2nd call in one transaction: 42P07 | as CC-70 | H10 | auto |
| CC-72 | column named like an output column | fine | 42702 ambiguous | alias-qualify every column | H11 | auto |
| CC-73 | returning `text` for a `VARCHAR` column | fine | 42804 | cast to the declared base type | H12 | auto |
| CC-74 | `RETURNS TABLE(x NUMERIC(19,4))` fed `1/3.0` | — | scale 20 (typmod ignored) | cast in the SELECT | H12 | auto |
| CC-75 | `@a INT = 1, @b INT` (default before required) | valid | 42P13 | keep order, later params `DEFAULT NULL` + NULL check | — | auto |
| CC-76 | recursive CTE over cyclic data | stops at `MAXRECURSION` 100 (error) | never stops | depth predicate or `CYCLE … SET … USING` | — | auto |
| CC-77 | `MERGE … WHEN NOT MATCHED BY SOURCE THEN UPDATE … OUTPUT $action` | `'UPDATE'` | — | PG 17 `MERGE … RETURNING merge_action()` | — | auto |
| CC-78 | `UPDATE … OUTPUT DELETED.col` | old value | `RETURNING` gives new value (PG 17) | lock rows in a CTE, `UPDATE … FROM cte RETURNING cte.col` | — | auto |
| CC-79 | `sp_executesql` + `QUOTENAME` | injection-safe | string concatenation | `format('%I')` + `EXECUTE … USING` | H14 | auto |
| CC-80 | load rows with explicit IDENTITY values | next insert continues | next default collides (23505) | `setval(pg_get_serial_sequence(…), MAX+1, false)` | — | auto |
| CC-81 | `UNIQUE` on a nullable column | one NULL allowed | many NULLs | `UNIQUE NULLS NOT DISTINCT` | — | auto |
| CC-82 | `ORDER BY n` / `ORDER BY n DESC` with NULLs | NULL first / last | NULL last / first | `NULLS FIRST` / `NULLS LAST` | P3 | auto |
| CC-83 | one proc returning 2 result sets | 2 sets | impossible | 2 functions `<base>`, `<base>_<set>` (example 11) | H8 | auto |
| CC-84 | `OUTPUT` params + `RETURN n` | caller reads both | — | `PROCEDURE` with `INOUT` params + `p_return_code` (example 15) | — | auto |
| CC-85 | inline table-valued function | inlined | — | `LANGUAGE sql` function (example 16) | H7 | auto |
| CC-86 | trigger reading `inserted` / `deleted` | statement-level | row trigger rewrite | `FOR EACH STATEMENT` + `REFERENCING OLD/NEW TABLE` (example 17) | — | auto |
| CC-87 | 2 INSERTs, 2nd fails, no `BEGIN TRAN` | 1st row kept | function rolls both back | accept (safer) and flag, or PROCEDURE + COMMIT | P9 | auto |
