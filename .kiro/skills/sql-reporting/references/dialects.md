# Reporting dialect catalog: PostgreSQL · Amazon Redshift · Athena (Trino) · Spark SQL

How each reporting pattern is spelled per engine. `auto` rows are proven by
`scripts/tests/test_report_dialects.py` (`[RD-nn]` tags) through `report_tool.py check --target`
and the worked examples in `references/examples/{redshift,athena,spark}/`;
`check_rule_coverage.py --catalog references/dialects.md --prefix RD` fails the self-test otherwise.
Facts verified against the PostgreSQL 17, Amazon Redshift, Amazon Athena engine v3 (Trino) and
Apache Spark 3.5 / 4.0 documentation (2026).

| ID | Need | PostgreSQL | Amazon Redshift | Athena (Trino) | Spark SQL | Test |
|---|---|---|---|---|---|---|
| RD-01 | All periods in a range (gap filling) | `generate_series(start, end - interval '1 day', interval '1 month')` | recursive CTE `WITH RECURSIVE months(period_start) AS (…)` or a date dimension — `generate_series` runs on the leader node only and cannot join user tables | `CROSS JOIN UNNEST(sequence(start, end, INTERVAL '1' MONTH)) AS t(m)` | `explode(sequence(start, end, interval 1 month))` | auto |
| RD-02 | Period bucket | `date_trunc('month', ts)::DATE` | `DATE_TRUNC('month', ts)::DATE` | `CAST(date_trunc('month', ts) AS DATE)` | `CAST(date_trunc('MONTH', ts) AS DATE)` / `trunc(d, 'MONTH')` | auto |
| RD-03 | Conditional aggregate | `SUM(x) FILTER (WHERE …)` | `SUM(CASE WHEN … THEN x END)` — no `FILTER` | `SUM(x) FILTER (WHERE …)` | `SUM(x) FILTER (WHERE …)` (3.0+) | auto |
| RD-04 | Share of total | `x * 100.0 / NULLIF(SUM(x) OVER (), 0)` | same, or `RATIO_TO_REPORT(x) OVER ()` | same | same after `CAST(x AS DECIMAL(19,4))` | auto |
| RD-05 | Running total | `SUM(x) OVER (ORDER BY k, id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` | same | same | same | auto |
| RD-06 | Prior period | `LAG(x, n) OVER (ORDER BY period)` on a gap-filled series | same | same | same | auto |
| RD-07 | Top-N per group | `DENSE_RANK() OVER (PARTITION BY g ORDER BY m DESC)` then `WHERE rnk <= n`; or `JOIN LATERAL … LIMIT n` | same; `QUALIFY` allowed | same in a subquery (no `QUALIFY`) | same in a subquery (no `QUALIFY` in OSS Spark) | auto |
| RD-08 | Median / percentiles | `percentile_cont(0.5) WITHIN GROUP (ORDER BY x)` (exact) | `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x)` (verify on your engine version) or `APPROXIMATE PERCENTILE_DISC` — say which | `approx_percentile(x, 0.5)` (approximate) | `percentile(x, 0.5)` (exact) / `percentile_approx` | auto |
| RD-09 | Subtotals | `GROUP BY GROUPING SETS ((a, b), (a), ())` + `GROUPING(col)` | same | same | same | auto |
| RD-10 | Latest row per key | `DISTINCT ON (key) … ORDER BY key, ts DESC, id DESC` | `ROW_NUMBER() … QUALIFY rn = 1` or subquery — no `DISTINCT ON` | `ROW_NUMBER()` in a subquery | `ROW_NUMBER()` in a subquery | auto |
| RD-11 | String aggregation | `string_agg(x, ', ' ORDER BY x)` | `LISTAGG(x, ', ') WITHIN GROUP (ORDER BY x)` | `listagg(x, ', ') WITHIN GROUP (ORDER BY x)` or `array_join(array_agg(x ORDER BY x), ', ')` | `array_join(sort_array(collect_list(x)), ', ')` (Spark 4: `listagg`) | auto |
| RD-12 | Money and ratios | `NUMERIC(19,4)`; `ROUND(…, 2)` last | `DECIMAL(19,4)` | `DECIMAL(19,4)` (no `NUMERIC` keyword) | `DECIMAL(19,4)`; cast before `/` (floating-point division) | auto |
| RD-13 | Months between two dates | `(EXTRACT(YEAR …) - …) * 12 + EXTRACT(MONTH …) - …` | `DATEDIFF(month, a, b)` (counts month boundaries) | `date_diff('month', a, b)` (exact on first-of-month dates) | `(year(b) - year(a)) * 12 + month(b) - month(a)` (`months_between` is fractional) | auto |
| RD-14 | Delivery form | `CREATE OR REPLACE FUNCTION report_x(…) RETURNS TABLE … LANGUAGE sql STABLE` | `CREATE OR REPLACE VIEW` (late-binding over external tables); parameters via `PREPARE`/`EXECUTE` or a `params` CTE; procedure + refcursor only when needed | `CREATE OR REPLACE VIEW` (no parameters, no user functions) + `PREPARE … EXECUTE … USING` | `CREATE OR REPLACE TEMPORARY VIEW` / job SQL with `${var}` | auto |
| RD-15 | Text normalisation | `lower(trim(x))` | `lower(trim(x))` (or `CASE_INSENSITIVE` collation) | `lower(trim(x))` (case-sensitive engine) | `lower(trim(x))` | auto |
| RD-16 | Checking and proving | executed by the self-test (`pgtest.sh`) | `report_tool.py check --target redshift` (dialect rules + `redshift_tool` linter), `redshift_tool.py run` on a test DB | `report_tool.py check --target athena`, `iceberg_tool.py run` on a test DB | `report_tool.py check --target spark` | auto |
| RD-17 | Week bucket | `date_trunc('week', d)` = ISO Monday | `DATE_TRUNC('week', d)` = Monday | `date_trunc('week', d)` = Monday | `date_trunc('WEEK', d)` = Monday; Sunday weeks need arithmetic on every engine | auto |
| RD-18 | Time zone of a bucket | `ts AT TIME ZONE 'Region/City'` | `CONVERT_TIMEZONE('UTC', 'Region/City', ts)` — no `AT TIME ZONE` | `ts AT TIME ZONE 'Region/City'` | `from_utc_timestamp(ts, 'Region/City')` | auto |

Cast operator: `::` works on PostgreSQL and Redshift; Athena (Trino) needs `CAST(x AS t)`; Spark
accepts `::` only on recent versions — `CAST` is portable. `make_date` exists on PostgreSQL and
Spark, not on Redshift or Athena (`DATE '2025-01-01'` literals are portable). Named windows
(`WINDOW w AS (…)`) are not supported on Redshift — inline the `OVER (…)`.
