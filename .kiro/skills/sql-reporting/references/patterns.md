# Reporting SQL: rules and patterns (PostgreSQL)

Two catalogs. **Rules** (`RQ-nn`) are the mechanics that silently corrupt a number.
**Patterns** (`RP-nn`) are the report shapes, each with a tested example in
`examples/`. Every `auto` row is proven by `scripts/tests/report_tests.sql`
(`scripts/check_rule_coverage.py` fails the self-test if one has no test).

## Rules

| ID | Rule | Why it matters | Test |
|---|---|---|---|
| RQ-01 | **Aggregate at the finest grain first, then join.** Joining a header to its lines and summing a header column multiplies it by the line count. Count entities with `COUNT(DISTINCT key)`. | 2025 revenue 4 999.37 becomes 8 309.10 when summed over lines | auto |
| RQ-02 | **One definition per measure**, written once in a CTE (or a view) and reused by every report. | Two reports disagreeing on "revenue" is the most common dashboard complaint | auto |
| RQ-03 | **NULL-safe arithmetic.** `COALESCE(SUM(x), 0)` for empty groups; `x / NULLIF(d, 0)`; growth from zero is NULL, not an error and not "infinite". | `SUM` over no rows is NULL; `/ 0` raises 22012 | auto |
| RQ-04 | **Cast before dividing, round last.** `int / int` truncates; compute ratios in NUMERIC, multiply by 100 first, `ROUND(…, 2)` at the end. | `7 / 2 = 3`; rounding parts then summing ≠ rounding the sum | auto |
| RQ-05 | **Half-open time ranges** `>= start AND < end`, never `BETWEEN` on timestamps; **fill gaps** with `generate_series` so empty periods appear as 0 and window functions see every period. | `BETWEEN … '2025-06-30'` drops everything after midnight on the 30th | auto |
| RQ-06 | **Bucket in the report's time zone.** `timestamptz` → `AT TIME ZONE 'Region/City'` before `date_trunc`; DST days are 23/25 hours. | 02:30 UTC on 1 July is still 30 June in New York | auto |
| RQ-07 | **Say which week.** `date_trunc('week')` is ISO (Monday); Sunday-start weeks need `d - EXTRACT(DOW FROM d)`. | Sunday 30 March lands in different weeks | auto |
| RQ-08 | **Write the window frame.** Running totals: `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` with a tie-breaker; the default `RANGE` frame merges rows with equal `ORDER BY` keys. Moving averages: `ROWS BETWEEN n PRECEDING AND CURRENT ROW`, and say that the first n rows are partial. | Default frame gives 20,20,30 instead of 10,20,30 | auto |
| RQ-09 | **Choose the ranking function on purpose.** `ROW_NUMBER` breaks ties arbitrarily, `RANK` leaves gaps, `DENSE_RANK` keeps ties and no gaps; top-N with ties → `FETCH FIRST n ROWS WITH TIES`. | A tied product silently drops out of a top-3 | auto |
| RQ-10 | **Percentiles:** `percentile_cont` interpolates (median of 1,2,3,4 = 2.5), `percentile_disc` returns an actual value (2). Name which one the report shows. | p90 differs by 40 in the sample | auto |
| RQ-11 | **Period-over-period only over a gap-filled series.** `LAG()` on the months that happen to exist returns the wrong "prior" after a gap; a missing comparison period is NULL. | August's prior month must be July (0), not June | auto |
| RQ-12 | **Pivot with `FILTER`**, include an explicit `other` bucket for unexpected values, and a `total` column that reconciles. | Unknown statuses disappear silently otherwise | auto |
| RQ-13 | **Semi-additive measures** (stock, balances, headcount) are point-in-time: take the last snapshot on or before the date (`DISTINCT ON … ORDER BY date DESC`), never `SUM` across dates. | Summing June snapshots gives 153 for a 53-unit balance | auto |
| RQ-14 | **Filter statuses explicitly and consistently** (cancelled, refunded, test accounts, internal orders). Put the filter in the shared definition (RQ-02). | 18 orders vs 15 revenue orders | auto |
| RQ-15 | **Subtotals via `GROUPING SETS` / `ROLLUP` and identify them with `GROUPING()`**, not by `IS NULL` — a real NULL dimension value is not a subtotal. | | auto |
| RQ-16 | **Deterministic order.** Every `ORDER BY` for a report, `DISTINCT ON`, `LIMIT` or window carries a unique tie-breaker (a key column). | Same query, different rows on the next run | auto |
| RQ-17 | **Cohorts:** cohort = period of the first *qualifying* event; `months_since` counts period boundaries; the denominator is the cohort size, not the active count. | | auto |
| RQ-18 | **Funnels count distinct users per step**, keep the step list explicit (a `VALUES` list) so empty steps still appear, and state open vs strict funnel. | 7 view events but 5 users | auto |
| RQ-19 | **Money in NUMERIC**, never `float`/`double precision`; round once, at the end. | `0.1 + 0.2 ≠ 0.3` in double | auto |
| RQ-20 | **Performance:** filter before aggregating, keep predicates sargable (`created_at >= $1`, not `date_trunc(created_at) = …`), index `(status, created_at)`-style columns, check `EXPLAIN (ANALYZE, BUFFERS)`, use materialized views for heavy dashboards and refresh them on a schedule. | | manual |
| RQ-21 | **Deliver reports as parameterized `LANGUAGE sql STABLE` functions** (or views): typed parameters, half-open date parameters, `RETURNS TABLE` with explicit casts (`COUNT(*)::INTEGER`). | Callable from BI tools, testable, planner-inlinable | auto |
| RQ-22 | **Normalise text dimensions** (`lower(trim(x))`) before grouping when data quality is unknown; migrated SQL Server data often relies on a case-insensitive collation. | `' Widgets'`, `'widgets'`, `'Widgets'` are three groups | auto |
| RQ-23 | **Never average averages.** A mean is `SUM/COUNT` over the whole set; weighted where needed. | 333.29 vs 248.59 | auto |
| RQ-24 | **`COUNT(*)` vs `COUNT(col)` vs `COUNT(DISTINCT col)`** — rows, non-NULL values, distinct values. | | auto |

## Patterns

| ID | Pattern | Use when | Example | Watch out for |
|---|---|---|---|---|
| RP-01 | Measure by period with gap filling | any time series | `01_revenue_by_month.sql` | RQ-05, RQ-03 |
| RP-02 | Measure by dimension from a child table | category / product / region breakdowns | `02_category_revenue.sql` | RQ-01 fan-out; line vs header revenue |
| RP-03 | Running total, moving average | cumulative charts, smoothing | `03_running_revenue.sql` | RQ-08 frames, partial windows |
| RP-04 | Period-over-period (MoM, YoY) | growth KPIs | `04_revenue_growth.sql` | RQ-11 gaps, RQ-03 zero base |
| RP-05 | Top-N per group | "best sellers per category" | `05_top_products_per_category.sql` | RQ-09 ties |
| RP-06 | Ranking, share, cumulative share (Pareto/ABC) | concentration analysis | `06_customer_pareto.sql` | RQ-08, RQ-16 |
| RP-07 | Distribution statistics | mean/median/percentiles | `07_order_value_stats.sql` | RQ-10, RQ-23 |
| RP-08 | Pivot (columns per value) | status / channel matrices | `08_orders_by_month_status.sql` | RQ-12 |
| RP-09 | Cohort retention | retention, churn | `09_cohort_retention.sql` | RQ-17 |
| RP-10 | Balance as of a date (semi-additive) | stock, account balances | `10_stock_as_of.sql` | RQ-13 |
| RP-11 | Funnel | conversion steps | `11_funnel.sql` | RQ-18 |
| RP-12 | Gaps and islands | streaks, continuous activity | `12_customer_activity_streaks.sql` | month arithmetic across years |
| RP-13 | Subtotals and grand total | financial layouts | `13_revenue_rollup.sql` | RQ-15 |
| RP-14 | First / last per group | first purchase, latest status | `14_customer_first_last_order.sql` | RQ-16 |
| RP-15 | Histogram / bucketing | value distributions | `15_order_value_histogram.sql` | RQ-04, RQ-05 |

## Quick reference: the PostgreSQL toolbox for reports

| Need | Use |
|---|---|
| Month / week / day bucket | `date_trunc('month', ts)::DATE`; weeks per RQ-07 |
| All periods in a range | `generate_series(start, end - interval '1 day', interval '1 month')` |
| Conditional aggregate | `COUNT(*) FILTER (WHERE …)`, `SUM(x) FILTER (WHERE …)` |
| Share of total | `x * 100.0 / NULLIF(SUM(x) OVER (), 0)` |
| Running total | `SUM(x) OVER (ORDER BY k, id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` |
| Prior period | `LAG(x, n) OVER (ORDER BY period)` on a gap-filled series |
| Top-N per group | `DENSE_RANK() OVER (PARTITION BY g ORDER BY m DESC)` then `WHERE rnk <= n`, or `JOIN LATERAL (… LIMIT n)` |
| Median / percentiles | `percentile_cont(0.5) WITHIN GROUP (ORDER BY x)` |
| Subtotals | `GROUP BY GROUPING SETS ((a, b), (a), ())` + `GROUPING(col)` |
| Latest row per key | `DISTINCT ON (key) … ORDER BY key, ts DESC, id DESC` |
| Bucketing | `width_bucket(x, lo, hi, n)` or `FLOOR(x / w) * w` |
| String aggregation | `string_agg(x, ', ' ORDER BY x)` |
| JSON output for APIs | `json_agg(row_to_json(t))`, `jsonb_build_object` |
| Heavy dashboards | `CREATE MATERIALIZED VIEW … ; REFRESH MATERIALIZED VIEW CONCURRENTLY` (needs a unique index) |
| Plan check | `EXPLAIN (ANALYZE, BUFFERS) SELECT …` |
