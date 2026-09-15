---
inclusion: always
---

# SQL Server → PostgreSQL Migration — Conversion Rules

Generic rules for migrating Microsoft SQL Server objects (procedures, functions,
triggers, views, table DDL) to PostgreSQL / Amazon Aurora PostgreSQL. They apply to
**every** task in this workspace and do not depend on any particular database.
Project specifics (target version, paths, test command, connections) live in
`.kiro/steering/project.md`; when that file is absent, use the defaults below.

## Skills

| Skill | Status | Use it for |
|---|---|---|
| `.kiro/skills/sql-conversion/SKILL.md` | active | converting T-SQL to PL/pgSQL, fixing or reviewing a conversion |
| `.kiro/skills/sql-reporting/SKILL.md` | active | writing, reviewing and testing reporting / analytics SQL on PostgreSQL (rules `RQ-nn`, patterns `RP-nn`) |
| `.kiro/skills/informatica-etl-conversion/SKILL.md` | active | Informatica PowerCenter XML with SQL Server SQL → PostgreSQL (steering `informatica-etl.md`, corner cases `IC-nn`) |
| `.kiro/skills/schema-validation/SKILL.md` | planned | validating converted DDL and references |
| `.kiro/skills/metadata-validation/SKILL.md` | planned | auditing the migration log |

**For any conversion task follow `.kiro/skills/sql-conversion/SKILL.md`; for report or
analytics SQL follow `.kiro/skills/sql-reporting/SKILL.md`; for Informatica exports follow
`.kiro/skills/informatica-etl-conversion/SKILL.md`. If the skill was not activated
automatically, read that file before writing code.**

Rule IDs (`[H1]`, `[P4]`) and corner-case IDs (`[CC-43]`, catalogued in
`.kiro/skills/sql-conversion/references/corner-cases.md`) are referenced by the
tests. `scripts/check_rule_coverage.py` fails when a rule has no test.

## Defaults (overridable in project steering)

| Setting | Default |
|---|---|
| Target | PostgreSQL 15+ / Aurora PostgreSQL; version-gated features only when the project target allows them |
| Target schema | `public` (SQL Server `dbo` → `public`) |
| Layout | `source/` T-SQL · `source/schema/` T-SQL DDL · `generated/` converted code · `generated/schema.sql` converted DDL · `tests/` suites · `metadata/migration_log.json` |
| Test command | the project's test command; otherwise the skill's generic runner `bash .kiro/skills/sql-conversion/scripts/pgtest.sh <manifest.sql>` |

Version gates: **15** `MERGE`, `UNIQUE NULLS NOT DISTINCT`, `regexp_instr` ·
**16** `IS JSON`, `pg_input_is_valid()` · **17** `MERGE … WHEN NOT MATCHED BY SOURCE`,
`RETURNING merge_action()`, `MERGE` inside `WITH` · **18 (do not use until targeted)**
`OLD`/`NEW` in `RETURNING`, `uuidv7()`, virtual generated columns. When using a
gated feature, name the minimum version in the file header and give the fallback.

---

## Hard rules

1. **[H1] Preserve behaviour.** Same rows, values, errors and side effects for the same inputs —
   including the source's bugs: keep them and flag them (see [H16]). Never silently "improve" semantics.
2. **[H2] Names convert 1:1.** `dbo.OrderLines.OrderId` → `public.order_lines.order_id`. Never rename
   a key to `id`, never invent a column; check every table and column against the converted DDL.
3. **[H3] Schema.** `dbo.` → the target schema; schema-qualify every table reference inside routines.
4. **[H4] Money.** `MONEY` → `NUMERIC(19,4)`, `SMALLMONEY` → `NUMERIC(10,4)`; never the `money` type.
5. **[H5] Remove SQL Server-only syntax:** `GO`, `USE`, `SET NOCOUNT ON`, `WITH (NOLOCK)`, query and
   index hints, `N'…'` prefixes, `@@` functions. `WITH (UPDLOCK[, ROWLOCK])` → `SELECT … FOR UPDATE`.
6. **[H6] No `@variables`.** Parameters `p_name`, locals `v_name`, loop records `v_rec`.
7. **[H7] Routine form.** `CREATE OR REPLACE`; `LANGUAGE plpgsql` for procedural code,
   `LANGUAGE sql` for inline table-valued functions and single-statement functions.
8. **[H8] One result set per function.** A proc returning rows → `FUNCTION … RETURNS TABLE`;
   N result sets → N functions `<base>`, `<base>_<result_set>`. No routine name defined twice.
9. **[H9] Transactions.** A FUNCTION never commits. `COMMIT`/`ROLLBACK` only in a `PROCEDURE`
   invoked by top-level `CALL`, never inside a block that has an `EXCEPTION` clause. No
   `BEGIN TRANSACTION`, no `SAVEPOINT` — a nested `BEGIN … EXCEPTION … END` is the savepoint.
10. **[H10] Temp tables** are session-scoped: `CREATE TEMP TABLE IF NOT EXISTS …; TRUNCATE …;`.
11. **[H11] Qualify every column** with a table alias. `RETURNS TABLE`/`OUT` columns and variables are
    in scope inside queries (42702 "ambiguous"); give CTE columns non-colliding names; use
    `ON CONFLICT ON CONSTRAINT` when a conflict column shares an output column's name.
12. **[H12] `RETURNS TABLE` types equal the base types** of the returned expressions (`text` ≠
    `varchar`, `bigint` ≠ `integer`); typmods are **not** applied by `RETURN QUERY`, so cast explicitly.
13. **[H13] Volatility.** `STABLE`/`IMMUTABLE` only without DDL, DML, temp tables or volatile calls.
14. **[H14] Dynamic SQL:** identifiers via `format('%I')`, values via `EXECUTE … USING`; never
    concatenate values.
15. **[H15] String `+` → `||`** (NULL-propagating like `+`); never `CONCAT()` as its replacement.
16. **[H16] Flag, don't hide.** Unsupported features, preserved bugs and intentional differences get
    `-- TODO: MANUAL REVIEW REQUIRED — <reason>` in code and `"manual_review": true` in the log.
17. **[H17] Done means tested** (process rule): standard header, log entry, a test suite tagged with
    the rules it proves, and a passing test run.

## Canonical data type mapping (tables, columns, parameters, variables)

### Numeric

| SQL Server | PostgreSQL | Notes |
|---|---|---|
| `BIGINT` / `INT` / `SMALLINT` | `BIGINT` / `INTEGER` / `SMALLINT` | direct |
| `TINYINT` | `SMALLINT` | 0–255 range lost → add `CHECK (col BETWEEN 0 AND 255)` on columns |
| `BIT` | `BOOLEAN` | literals `1/0` → `TRUE/FALSE`; `WHERE flag = 1` → `WHERE flag` |
| `DECIMAL(p,s)` / `NUMERIC(p,s)` | `NUMERIC(p,s)` | direct |
| `MONEY` / `SMALLMONEY` | `NUMERIC(19,4)` / `NUMERIC(10,4)` | never `money` |
| `FLOAT` / `FLOAT(25–53)` | `DOUBLE PRECISION` | |
| `REAL` / `FLOAT(1–24)` | `REAL` | |
| `INT IDENTITY(s,i)` | `INTEGER GENERATED BY DEFAULT AS IDENTITY (START WITH s INCREMENT BY i)` | BY DEFAULT lets the data load insert existing keys; afterwards run `SELECT setval(pg_get_serial_sequence('t','col'), COALESCE(MAX(col),0)+1, false) FROM t;` |
| `SET IDENTITY_INSERT t ON` | not needed (BY DEFAULT); with ALWAYS: `INSERT … OVERRIDING SYSTEM VALUE` | |
| `SEQUENCE` / `NEXT VALUE FOR s` | `SEQUENCE` / `nextval('s')` | |

### Character

| SQL Server | PostgreSQL | Notes |
|---|---|---|
| `VARCHAR(n)` / `NVARCHAR(n)` | `VARCHAR(n)` | the database is UTF-8; drop the N |
| `VARCHAR(MAX)` / `NVARCHAR(MAX)` / `TEXT` / `NTEXT` | `TEXT` | |
| `CHAR(n)` / `NCHAR(n)` | `CHAR(n)` | |
| `SYSNAME` | `VARCHAR(128)` | |
| Case-insensitive collation (`…_CI_AS`, the SQL Server default) | case-sensitive by default | `LIKE` → `ILIKE`; equality → `LOWER(a) = LOWER(b)` (+ expression index) or `citext`. Nondeterministic ICU collations cannot do `LIKE`/`strpos` in PG 17 |

### Date / time

| SQL Server | PostgreSQL | Notes |
|---|---|---|
| `DATE` | `DATE` | |
| `TIME(n)` | `TIME(min(n,6))` | |
| `DATETIME` | `TIMESTAMP(3)` | SQL Server rounds to 1/300 s: `'…23:59:59.999'` becomes the next day; PG keeps it [CC-53] |
| `DATETIME2(n)` / `DATETIME2` | `TIMESTAMP(min(n,6))` / `TIMESTAMP` | |
| `SMALLDATETIME` | `TIMESTAMP(0)` | SQL Server rounds to the minute (≥ 29.999 s up): `date_trunc('minute', t + INTERVAL '30.001 seconds')` [CC-54] |
| `DATETIMEOFFSET(n)` | `TIMESTAMPTZ` | PG stores the instant, **not** the original offset → keep the offset in an extra column if it matters |

### Binary and other

| SQL Server | PostgreSQL | Notes |
|---|---|---|
| `BINARY` / `VARBINARY(n)` / `VARBINARY(MAX)` / `IMAGE` | `BYTEA` | |
| `UNIQUEIDENTIFIER` | `UUID` | `NEWID()` → `gen_random_uuid()` (core since 13, no pgcrypto). SQL Server sorts GUIDs differently → `ORDER BY uuid` changes order |
| `XML` | `XML` | |
| `ROWVERSION` / `TIMESTAMP` | see manual review | |
| `SQL_VARIANT` / `HIERARCHYID` / `GEOGRAPHY` | see manual review | |

### Column-level DDL

| SQL Server | PostgreSQL |
|---|---|
| `CONSTRAINT PK_X PRIMARY KEY [CLUSTERED]` | `CONSTRAINT pk_x PRIMARY KEY` (no clustered indexes) |
| `UNIQUE` on a nullable column (allows ONE NULL) | `UNIQUE NULLS NOT DISTINCT` (PG 15+) |
| Filtered unique index `… WHERE col IS NOT NULL` | plain `UNIQUE` (PG already allows many NULLs); other filters → partial unique index |
| `CONSTRAINT DF_X DEFAULT (v)` | `DEFAULT v` (defaults are not named objects) |
| `DEFAULT GETDATE()` / `SYSDATETIME()` / `NEWID()` | `DEFAULT LOCALTIMESTAMP` / `DEFAULT clock_timestamp()::TIMESTAMP` / `DEFAULT gen_random_uuid()` |
| `col AS (expr) PERSISTED` | `col type GENERATED ALWAYS AS (expr) STORED` |
| non-persisted computed column | `STORED` generated column, or compute it in a view |
| `NONCLUSTERED INDEX … INCLUDE (…)` | `CREATE INDEX … INCLUDE (…)` |
| Object names `PK_Orders`, `IX_Orders_CreatedAt` | `pk_orders`, `ix_orders_created_at` |

---

## Canonical syntax conversion rules

### Object types

| SQL Server object | PostgreSQL object |
|---|---|
| `CREATE PROCEDURE` that ends in a `SELECT` | `CREATE OR REPLACE FUNCTION … RETURNS TABLE(…)` |
| … returning N result sets | N functions `<base>`, `<base>_<result_set>` [CC-83] |
| … returning nothing / needing COMMIT | `CREATE OR REPLACE PROCEDURE` (called with `CALL`) |
| … with `OUTPUT` parameters / `RETURN n` | `PROCEDURE` with `INOUT` params (+ `p_return_code`) [CC-84] |
| Scalar function `RETURNS INT` | `FUNCTION … RETURNS INTEGER` (`IMMUTABLE` if argument-only) |
| Inline table-valued function (`RETURNS TABLE AS RETURN SELECT`) | `FUNCTION … RETURNS TABLE(…) LANGUAGE sql` [CC-85] |
| Multi-statement TVF (`RETURNS @t TABLE (…)`) | `FUNCTION … RETURNS TABLE(…) LANGUAGE plpgsql` + `RETURN QUERY` |
| `AFTER` trigger using `inserted`/`deleted` | trigger function + `FOR EACH STATEMENT … REFERENCING OLD TABLE AS deleted NEW TABLE AS inserted` [CC-86] |
| `INSTEAD OF` trigger on a table | `BEFORE` trigger returning `NULL`, or a view (manual review) |
| `CREATE VIEW … WITH SCHEMABINDING` | `CREATE OR REPLACE VIEW` (schemabinding dropped) |
| User-defined table type (TVP) | composite type + array, or `JSONB` |
| `CREATE SYNONYM` | view, or `search_path` |

### Variables, assignment, control flow

| T-SQL | PL/pgSQL | Gotcha |
|---|---|---|
| `DECLARE @x INT = 5` | `v_x INTEGER := 5;` (in `DECLARE`) | |
| `SET @x = expr` / `SET @x += 1` | `v_x := expr;` / `v_x := v_x + 1;` | no compound assignment |
| `SELECT @x = col FROM t WHERE …` | `SELECT t.col INTO v_x FROM t WHERE …;` | **no row:** T-SQL keeps the old value, PG sets NULL → temp variable + `IF FOUND`. **many rows:** T-SQL keeps the last, PG the first (`INTO STRICT` raises) |
| `SET @x = (SELECT col …)` | `v_x := (SELECT col …);` | NULL when no row, error when many — same in both |
| `IF … BEGIN … END ELSE …` / `ELSE IF` | `IF … THEN … ELSE … END IF;` / `ELSIF` | |
| `WHILE c BEGIN … END` | `WHILE c LOOP … END LOOP;` | |
| `BREAK` / `CONTINUE` | `EXIT;` / `CONTINUE;` | |
| `GOTO` | restructure | manual review |
| `WAITFOR DELAY '00:00:05'` | `PERFORM pg_sleep(5);` | |
| `EXEC dbo.p @a = 1` (inside a routine) | `PERFORM public.f(p_a => 1);` / `CALL public.p(p_a => 1);` | |
| `INSERT INTO t EXEC dbo.p …` | `INSERT INTO t SELECT * FROM public.f(…);` | |
| `@p INT OUTPUT` | `INOUT p_p INTEGER` (PROCEDURE) or `OUT p_p INTEGER` (FUNCTION) | |
| `RETURN @code` (proc return code) | extra `INOUT`/`OUT` parameter or `RETURNS INTEGER` | manual review |

### String functions

| T-SQL | PostgreSQL | Gotcha |
|---|---|---|
| `s1 + s2` | `s1 \|\| s2` | not `CONCAT` (hard rule 15) |
| `CONCAT(a, b)` / `CONCAT_WS` | same | both ignore NULLs |
| `ISNULL(a, b)` | `COALESCE(a, b)` | ISNULL returns **a's type** (truncates b to a's length); cast when types differ |
| `LEN(s)` | `char_length(rtrim(s))` | LEN ignores trailing spaces |
| `DATALENGTH(s)` | `octet_length(s)` | NVARCHAR is UTF-16 (2 bytes/char) in SQL Server |
| `CHARINDEX(n, h)` | `STRPOS(h, n)` | **arguments swap**; `CHARINDEX('', h) = 0` but `STRPOS(h, '') = 1`; CI collation → `STRPOS(LOWER(h), LOWER(n))` |
| `CHARINDEX(n, h, start)` | `CASE WHEN p = 0 THEN 0 ELSE p + s - 1 END` with `s = GREATEST(start,1)`, `p = STRPOS(SUBSTRING(h FROM s), n)` | |
| `PATINDEX('%[0-9]%', s)` | `regexp_instr(s, '[0-9]')` (PG 15+; 0 when no match) | LIKE pattern → regex: `%` → `.*`, `_` → `.`, `[…]` unchanged |
| `SUBSTRING(s, p, n)` / `LEFT` / `RIGHT` / `LTRIM` / `RTRIM` / `TRIM` / `UPPER` / `LOWER` / `REPLACE` / `REVERSE` / `TRANSLATE` | same | |
| `REPLICATE(s, n)` | `REPEAT(s, n)` | n < 0: REPLICATE → NULL, REPEAT → `''` → `CASE WHEN n >= 0 THEN REPEAT(s, n) END` |
| `SPACE(n)` | `REPEAT(' ', n)` | |
| `STUFF(s, p, l, r)` | `OVERLAY(s PLACING r FROM p FOR l)` | |
| `STR(n)` / `CAST(n AS VARCHAR)` | `n::TEXT` | |
| `QUOTENAME(x)` | `quote_ident(x)` / `format('%I', x)` | |
| `STRING_AGG(x, ',') WITHIN GROUP (ORDER BY y)` | `string_agg(x, ',' ORDER BY y)` | |
| `STRING_SPLIT(s, ',')` | `string_to_table(s, ',')` (`WITH ORDINALITY` for position) | |
| `CHAR(n)` / `NCHAR(n)` / `ASCII` / `UNICODE` | `chr(n)` / `chr(n)` / `ascii` / `ascii` | |
| `SOUNDEX` / `DIFFERENCE` | `fuzzystrmatch`: `soundex` / `difference` | extension |
| `FORMAT(number, 'N2')` | `to_char(n, 'FM999,999,999,990.00')` | |
| `a LIKE 'x%'` | `a ILIKE 'x%'` under a CI collation | `[abc]` / `[^a]` classes → `~` regex |
| `a = 'x '` | `rtrim(a) = 'x'` if trailing spaces matter | SQL Server `=` ignores trailing spaces |

### Date / time functions

| T-SQL | PostgreSQL | Gotcha |
|---|---|---|
| `GETDATE()` / `CURRENT_TIMESTAMP` | `LOCALTIMESTAMP` | fixed for the whole transaction |
| `SYSDATETIME()` | `clock_timestamp()::TIMESTAMP` | advances within a transaction |
| `GETUTCDATE()` / `SYSUTCDATETIME()` | `now() AT TIME ZONE 'UTC'` / `clock_timestamp() AT TIME ZONE 'UTC'` | |
| `SYSDATETIMEOFFSET()` | `clock_timestamp()` | |
| `CAST(GETDATE() AS DATE)` | `CURRENT_DATE` | |
| `DATEADD(unit, n, d)` | `d + n * INTERVAL '1 unit'`; on a `DATE` + days: `d + n` | month-end clamping is the same |
| `DATEDIFF(day, s, e)` | `e::DATE - s::DATE` | |
| `DATEDIFF(week, s, e)` | `((e::DATE - EXTRACT(DOW FROM e)::INT) - (s::DATE - EXTRACT(DOW FROM s)::INT)) / 7` | counts Sunday boundaries |
| `DATEDIFF(month, s, e)` | `(EXTRACT(YEAR FROM e) - EXTRACT(YEAR FROM s)) * 12 + EXTRACT(MONTH FROM e) - EXTRACT(MONTH FROM s)` | counts **boundaries**; never `AGE()` (completed months) |
| `DATEDIFF(year, s, e)` | `EXTRACT(YEAR FROM e) - EXTRACT(YEAR FROM s)` | not the age |
| `DATEDIFF(hour\|minute\|second, s, e)` | `EXTRACT(EPOCH FROM date_trunc('hour', e) - date_trunc('hour', s))::BIGINT / 3600` (same pattern per unit) | boundary count |
| `DATEPART(year\|month\|day\|hour\|minute\|second\|quarter\|dayofyear, d)` / `YEAR()` `MONTH()` `DAY()` | `EXTRACT(<unit> FROM d)::INTEGER` (`DOY` for dayofyear) | |
| `DATEPART(weekday, d)` | `EXTRACT(DOW FROM d)::INT + 1` (DATEFIRST 7) | general: `((EXTRACT(DOW FROM d)::INT + 7 - @@DATEFIRST % 7) % 7) + 1` |
| `DATEPART(week, d)` | `(EXTRACT(DOY FROM d)::INT + EXTRACT(DOW FROM date_trunc('year', d))::INT - 1) / 7 + 1` | not ISO |
| `DATEPART(iso_week, d)` | `EXTRACT(WEEK FROM d)::INT` (pair with `ISOYEAR`) | |
| `DATENAME(month\|weekday, d)` | `TO_CHAR(d, 'FMMonth')` / `TO_CHAR(d, 'FMDay')` | |
| `EOMONTH(d[, n])` | `(DATE_TRUNC('month', d) + INTERVAL '1 month' * (n + 1) - INTERVAL '1 day')::DATE` | |
| `DATEFROMPARTS(y,m,d)` / `DATETIMEFROMPARTS` / `TIMEFROMPARTS` | `make_date` / `make_timestamp` / `make_time` | |
| `DATEADD(week, DATEDIFF(week, 0, d), 0)` | `DATE_TRUNC('week', d + INTERVAL '1 day')::DATE` | SQL Server maps Sunday to the **next** Monday |
| `DATETRUNC(part, d)` (2022+) | `DATE_TRUNC('part', d)` | |
| `FORMAT(d, fmt)` | `TO_CHAR(d, fmt)` | codes: `yyyy→YYYY` `MM→MM` `M→FMMM` `MMM→Mon` `MMMM→FMMonth` `dd→DD` `d→FMDD` `ddd→Dy` `dddd→FMDay` `HH→HH24` `hh→HH12` `mm→MI` `ss→SS` `fff→MS` `tt→AM`; literal letters in `"…"` |
| `CONVERT(VARCHAR, d, 101/103/108/112/120/121/126)` | `TO_CHAR(d, 'MM/DD/YYYY' / 'DD/MM/YYYY' / 'HH24:MI:SS' / 'YYYYMMDD' / 'YYYY-MM-DD HH24:MI:SS' / 'YYYY-MM-DD HH24:MI:SS.MS' / 'YYYY-MM-DD"T"HH24:MI:SS.MS')` | `CONVERT(VARCHAR(n), d, s)` **truncates** → `LEFT(TO_CHAR(d, fmt), n)` [CC-55] |
| `ISDATE(s)` / `TRY_CAST(s AS T)` / `TRY_CONVERT` | `pg_input_is_valid(s, 'date')` (PG 16+) → `CASE WHEN pg_input_is_valid(s, 'integer') THEN s::INTEGER END` | |
| `d AT TIME ZONE 'tz'` / `SWITCHOFFSET` | `d AT TIME ZONE 'tz'` | Windows zone names → IANA names |

### Math

| T-SQL | PostgreSQL | Gotcha |
|---|---|---|
| `CAST(x AS INT)` of a decimal | `TRUNC(x)::INTEGER` | SQL Server truncates, PG **rounds** |
| `int / int` | `int / int` | both truncate |
| `ROUND(n, p)` / `ROUND(n, p, 1)` | `ROUND(n, p)` / `TRUNC(n, p)` | |
| `LOG(n)` / `LOG(n, b)` / `LOG10(n)` | `LN(n)` / `LOG(b, n)` / `LOG(n)` | PG `LOG(x)` is base 10; argument order swaps |
| `SQUARE(x)` / `POWER` / `SQRT` / `ABS` / `CEILING` / `FLOOR` / `SIGN` / `PI` / trig | `x * x` / same | |
| `RAND()` / `RAND(seed)` | `random()` / `setseed(seed/2^31)` + `random()` | |
| MONEY intermediate rounding | NUMERIC keeps full precision → cast the result to `NUMERIC(19,4)` where the value is returned or compared | |

### System / metadata

| T-SQL | PostgreSQL |
|---|---|
| `@@ROWCOUNT` | `GET DIAGNOSTICS v_n = ROW_COUNT;` or `FOUND`, read **directly** after the DML — the next `PERFORM`/`SELECT INTO` resets `FOUND` [CC-64] |
| `SCOPE_IDENTITY()` | `INSERT INTO t AS x … RETURNING x.<key> INTO v_key;` |
| `@@IDENTITY` / `IDENT_CURRENT('t')` | `RETURNING` / `currval(pg_get_serial_sequence('t','col'))` |
| `@@FETCH_STATUS = 0` | `FOR rec IN … LOOP` (or `FETCH …; EXIT WHEN NOT FOUND;`) |
| `@@ERROR`, `IF @@ERROR <> 0` | `EXCEPTION` block / `SQLSTATE` |
| `@@TRANCOUNT`, `XACT_STATE()` | not needed (see hard rule 9) |
| `@@SPID` / `DB_NAME()` / `USER_NAME()` / `SUSER_SNAME()` / `HOST_NAME()` | `pg_backend_pid()` / `current_database()` / `current_user` / `session_user` / `inet_client_addr()` |
| `OBJECT_ID('dbo.t') IS NOT NULL` | `to_regclass('public.t') IS NOT NULL` |
| `NEWID()` | `gen_random_uuid()` |
| `IIF(c, a, b)` / `CHOOSE(i, a, b)` | `CASE WHEN c THEN a ELSE b END` / `CASE i WHEN 1 THEN a WHEN 2 THEN b END` |
| `PRINT m` / `RAISERROR(m, 0–10, s)` | `RAISE NOTICE '%', m;` |

### DML

| T-SQL | PostgreSQL | Gotcha |
|---|---|---|
| `SELECT TOP (n) … ORDER BY` | `… ORDER BY … LIMIT n` | |
| `TOP (n) WITH TIES` / `TOP (n) PERCENT` | `FETCH FIRST n ROWS WITH TIES` / `LIMIT (SELECT CEIL(COUNT(*) * n / 100.0) …)` | PERCENT rounds up |
| `OFFSET x ROWS FETCH NEXT y ROWS ONLY` | `LIMIT y OFFSET x` | |
| `SELECT … INTO #t FROM …` | `CREATE TEMP TABLE t AS SELECT …` | |
| `UPDATE t SET … FROM t JOIN x ON …` | `UPDATE t SET … FROM x WHERE t.k = x.k` | never repeat the target table in `FROM` |
| `DELETE t FROM t JOIN x ON …` | `DELETE FROM t USING x WHERE t.k = x.k` | |
| `INSERT/UPDATE/DELETE … OUTPUT INSERTED.*` | `… RETURNING *` | |
| `OUTPUT DELETED.col` (old value) | lock rows in a CTE (`SELECT … FOR UPDATE`), `UPDATE … FROM cte … RETURNING cte.col` | `OLD` in `RETURNING` is PG 18 |
| `MERGE` with MATCHED/NOT MATCHED on a unique key | `INSERT … ON CONFLICT (key) DO UPDATE SET c = EXCLUDED.c` | concurrency-safe |
| `MERGE` with extra conditions / `NOT MATCHED BY SOURCE` / `OUTPUT $action` | PG 17 `MERGE … WHEN NOT MATCHED BY SOURCE … RETURNING merge_action()` | `$action` for BY SOURCE UPDATE is `'UPDATE'` in both |
| `CROSS APPLY` / `OUTER APPLY` | `CROSS JOIN LATERAL` / `LEFT JOIN LATERAL … ON TRUE` | |
| `WITH cte AS (… UNION ALL … cte …)` | `WITH RECURSIVE cte AS (…)` | add a depth guard; anchor/recursive types must match |
| `ORDER BY col` on a nullable column | `ORDER BY col ASC NULLS FIRST` / `DESC NULLS LAST` | SQL Server sorts NULL lowest, PG highest |
| `PIVOT` / `UNPIVOT` | `SUM(x) FILTER (WHERE k = 'A')` / `CROSS JOIN LATERAL (VALUES …)` | |

### Dynamic SQL

| T-SQL | PostgreSQL |
|---|---|
| `EXEC (@sql)` | `EXECUTE v_sql;` |
| `sp_executesql @sql, N'@a INT', @a = @x` | `EXECUTE v_sql USING v_x;` (`@a` → `$1`; numbers follow `USING` order) |
| `sp_executesql` with `OUTPUT` parameters | `EXECUTE v_sql INTO v_result USING …;` |
| Dynamic SELECT returned to the caller | `RETURN QUERY EXECUTE v_sql USING …;` (fixed columns → `RETURNS TABLE`; caller-chosen table → `SETOF JSONB`) |

### Transactions and error handling

| T-SQL | PL/pgSQL |
|---|---|
| `BEGIN TRAN … COMMIT` + CATCH that only `ROLLBACK`s and re-raises (`THROW;` / `RAISERROR(ERROR_MESSAGE()…)`) | no transaction statements, no EXCEPTION block — the error aborts and rolls back the whole call |
| CATCH that adds context, then re-raises | `EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION '<context>: %', SQLERRM USING ERRCODE = SQLSTATE;` |
| CATCH that logs and continues (per row) | nested `BEGIN … EXCEPTION … END` inside the loop; a log row written before a re-raise is rolled back |
| No explicit transaction, per-statement autocommit relied on | `PROCEDURE` with `COMMIT` outside EXCEPTION blocks (only if partial progress must survive), else accept the atomic call and note it |
| `SAVE TRAN s` / `ROLLBACK TRAN s` | nested `BEGIN … EXCEPTION … END` |
| `SET XACT_ABORT ON` | remove (PG always aborts on error) |
| `ERROR_MESSAGE()` / `ERROR_NUMBER()` / `ERROR_STATE()` | `SQLERRM` / `SQLSTATE` (text) / `SQLSTATE` |
| `ERROR_SEVERITY()` / `ERROR_LINE()` / `ERROR_PROCEDURE()` | no equivalent (`GET STACKED DIAGNOSTICS … PG_EXCEPTION_CONTEXT`) |
| `RAISERROR('… %d … %s', 16, 1, @a, @b)` | `RAISE EXCEPTION '… % … %', v_a, v_b USING ERRCODE = 'P0001';` (width specs → `format()`) |
| RAISERROR sev 11–19 **outside** TRY | does **not** stop T-SQL; `RAISE EXCEPTION` does → check the next statement is `RETURN`, else flag |
| `THROW 50001, 'msg', 1` | `RAISE EXCEPTION 'msg' USING ERRCODE = 'P0001', DETAIL = 'SQL Server error 50001';` |
| `THROW;` (in CATCH) | `RAISE;` — or no handler at all |

Use SQLSTATE `P0001` for converted user errors. Custom codes must be 5 characters,
must not end in `000`, and must avoid standard classes (e.g. not `20xxx`).

---

## Structural patterns

```sql
-- #temp table → session temp table, safe to call repeatedly in one session
CREATE TEMP TABLE IF NOT EXISTS tmp_batch (order_id INTEGER, amount NUMERIC(19,4));
TRUNCATE tmp_batch;

-- Cursor → FOR loop
FOR v_rec IN SELECT o.order_id FROM public.orders o WHERE o.status = 'Pending' LOOP
    UPDATE public.orders o SET status = 'Processing' WHERE o.order_id = v_rec.order_id;
END LOOP;

-- SCOPE_IDENTITY() → RETURNING into a variable (alias-qualified)
INSERT INTO public.orders AS o (customer_id, total_amount)
VALUES (p_customer_id, v_total)
RETURNING o.order_id INTO v_order_id;

-- Table variable read once after @@ROWCOUNT → RETURN QUERY + FOUND
RETURN QUERY SELECT …;
IF NOT FOUND THEN RAISE NOTICE 'Nothing found.'; END IF;

-- Dynamic SQL
v_sql := format('SELECT … FROM public.%I t WHERE t.%I = $1 ORDER BY t.%I LIMIT $2',
                p_table, p_col, p_sort);
RETURN QUERY EXECUTE v_sql USING p_value, p_limit;
```

---

---

## Behavioural parity checklist

Differences that silently change results. Review every conversion against this list
and write at least one test per item that applies.

1. **[P1]** `SELECT @v = …` with no row keeps `@v`; with several rows keeps the **last** — PG sets NULL / takes the first [CC-61, CC-62].
2. **[P2]** Default collation is case- and trailing-space-insensitive for `=`, `LIKE`, `GROUP BY`, `ORDER BY`, `CHARINDEX`; PG is neither [CC-05, CC-11–13, CC-21, CC-23].
3. **[P3]** `NULL` sorts first ascending in SQL Server, last in PG [CC-82].
4. **[P4]** `DATEDIFF` counts boundaries; `AGE()` counts elapsed units [CC-43–47].
5. **[P5]** `CAST(decimal AS INT)` and INT assignment truncate (PG rounds); `AVG(int)` is INT; `ISNULL` takes the first argument's type [CC-16, CC-17, CC-24–26, CC-31].
6. **[P6]** `LEN` ignores trailing spaces, `CHARINDEX('')` = 0, `REPLICATE(n<0)` = NULL, `LEFT(n<0)` errors, `CONVERT(VARCHAR(n))` truncates [CC-02–09, CC-55].
7. **[P7]** `+` propagates NULL, `CONCAT` does not [CC-01].
8. **[P8]** `GETDATE()`/`SYSDATETIME()` advance per statement; `LOCALTIMESTAMP` is fixed per transaction [CC-58].
9. **[P9]** Without `BEGIN TRAN` SQL Server keeps completed statements; `RAISERROR` outside TRY continues; CATCH log rows survive a re-throw — a PG function is atomic [CC-65, CC-67, CC-87].
10. **[P10]** `BETWEEN … AND <date>` excludes the rest of the last day in **both** engines — preserve it, flag it [CC-57].
11. **[P11]** Week logic depends on Sunday / `@@DATEFIRST` (`DATEPART(weekday|week)`, `DATEDIFF(week)`, week bucketing) [CC-46, CC-50–52].

---

## Validation checklist

Checked by review and — where marked — automatically by the skill's test engine
(`scripts/lib/static_checks.sql`, runtime tests, coverage check).

### Types
- [ ] `MONEY` → `NUMERIC(19,4)`, no `money` anywhere *(auto: STATIC-09/10)*
- [ ] `BIT` → `BOOLEAN` compared with `TRUE`/`FALSE`
- [ ] `DATETIME` → `TIMESTAMP(3)`, `DATETIME2` → `TIMESTAMP`, `DATETIMEOFFSET` → `TIMESTAMPTZ` (+ offset column if needed)
- [ ] `UNIQUEIDENTIFIER` → `UUID`; `NVARCHAR` → `VARCHAR`; `(N)VARCHAR(MAX)` → `TEXT`
- [ ] `IDENTITY` → `GENERATED BY DEFAULT AS IDENTITY`, `setval` in the load plan
- [ ] `UNIQUE` on nullable columns → `NULLS NOT DISTINCT`; `TINYINT` → `SMALLINT` + CHECK

### Syntax
- [ ] No `dbo.`, `@`, `NOLOCK`, `UPDLOCK`, `SET NOCOUNT`, `GO`, `@@` *(auto: STATIC-01..03)*
- [ ] No `ISNULL`, `LEN`, `GETDATE`, `CHARINDEX`, `REPLICATE`, `DATEADD`, `DATEDIFF`, `+` concatenation left
- [ ] `IF … END IF;`, `LOOP … END LOOP;`, `ELSIF`; cursors → `FOR … LOOP`
- [ ] TRY/CATCH → `EXCEPTION` only where the CATCH does more than re-raise
- [ ] `RAISERROR`/`THROW` → `RAISE EXCEPTION … USING ERRCODE`; `PRINT` → `RAISE NOTICE`
- [ ] Recursive CTEs: `WITH RECURSIVE` + depth guard; dynamic SQL: `%I` + `USING` only

### Structure
- [ ] `CREATE OR REPLACE`, `LANGUAGE plpgsql|sql` *(auto: STATIC-04)*; standard file header
- [ ] One result set per function; split names `<base>_<suffix>`; no duplicate names *(auto: STATIC-05)*
- [ ] No `COMMIT` in functions *(auto: STATIC-06)* or inside EXCEPTION blocks; no `SAVEPOINT`
- [ ] Temp tables `IF NOT EXISTS` + `TRUNCATE` *(auto: STATIC-07)*
- [ ] No `STABLE`/`IMMUTABLE` routine writes data *(auto: STATIC-08)*
- [ ] Every column alias-qualified; every table/column exists in the converted DDL

### Behaviour and tests
- [ ] Each applicable parity item [P1–P11] has a tagged test
- [ ] Preserved bugs / differences carry the TODO flag and `"manual_review": true`
- [ ] Migration log updated; the project's test command passes

---

## Features requiring manual review

Flag with `-- TODO: MANUAL REVIEW REQUIRED — <reason>` and set `"manual_review": true`.
Code-level workarounds: `.kiro/skills/sql-conversion/references/unsupported-features.md`.

| Feature | Suggested path |
|---|---|
| Linked servers, `OPENQUERY`, 4-part names, cross-database queries | `postgres_fdw` / `dblink` / one database with schemas |
| MSDTC distributed transactions | redesign (saga / outbox) |
| CLR functions | rewrite in PL/pgSQL |
| `EXECUTE AS` | `SECURITY DEFINER` + `SET search_path` |
| `##global` temp tables, table-valued parameters | staging table / arrays or JSONB |
| Proc return codes (`RETURN @n`), `GOTO` | `INOUT p_return_code` / restructure |
| `RAISERROR` outside TRY that is not followed by `RETURN` | decide per call site [CC-67] |
| `FOR XML` / `FOR JSON` / `OPENJSON` | `xmlagg` / `json_agg` / `jsonb_to_recordset` |
| `BULK INSERT` / `OPENROWSET` | `\copy`, `aws_s3.table_import_from_s3` |
| `CONTAINS` / `FREETEXT` | `tsvector` + GIN, or `ILIKE` + `pg_trgm` |
| `ROWVERSION` | `xmin` or version column + trigger |
| `HIERARCHYID` / `SQL_VARIANT` / `GEOGRAPHY` | `ltree` / `JSONB` / PostGIS |
| `PIVOT` with dynamic columns | `crosstab()` (tablefunc) |
| `INSTEAD OF` triggers on tables | `BEFORE` trigger returning NULL, or a view |
| SQL Agent jobs, Database Mail, `sp_getapplock` | `pg_cron`, app/SES, `pg_advisory_xact_lock` |
| `SET ANSI_NULLS OFF`, `SET DATEFIRST`, `SET LANGUAGE` dependencies | make the assumption explicit |
| `ISNUMERIC` | no exact equivalent — review each use [CC-38] |

---

## Naming conventions

| SQL Server | PostgreSQL |
|---|---|
| `usp_ProcName`, `sp_ProcName`, `fn_Name`, `vw_Name` | `proc_name`, `name`, `name` / `v_name` (drop the prefix) |
| `tr_Table_Event` | trigger `trg_table_event` + function `trg_table_event_fn()` |
| `[dbo].[TableName]`, `ColumnName` | `public.table_name`, `column_name` (unquoted snake_case; keys keep their names) |
| `@ParamName` / local `@Var` | `p_param_name` / `v_var` |
| `#TempTable` | `tmp_temp_table` |
| Split result sets of `usp_GetX` | `get_x` (first set), `get_x_<result_set>` |
| `PK_`/`UQ_`/`FK_`/`IX_`/`CK_` names | same prefix in lower snake_case |

## Output conventions

1. Source files keep their names; converted code goes to one file per source file
   (default `generated/<snake_case_name>.sql`), converted DDL to one schema file.
2. Every converted file starts with the standard header (Converted from, date,
   converter version, target, schema, notes) — see the skill, Step 7.
3. Update the migration log after every conversion.
4. Register the file and its suite with the project's test manifest and run the
   project's test command until it passes.
