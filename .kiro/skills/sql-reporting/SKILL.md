---
name: sql-reporting
description: Generate, review and test reporting and analytics SQL on the converted data - Aurora PostgreSQL, Amazon Redshift, Athena (Trino) over Iceberg or Spark SQL - KPIs, time series with gap filling, growth (MoM/YoY), rankings and top-N, shares and Pareto, pivots, cohorts and retention, funnels, percentiles, stock balances, subtotals; 24 correctness rules, 15 patterns with tested PostgreSQL examples, a per-engine dialect catalog with Redshift/Athena/Spark examples and report_tool.py check. Use when asked to write a report query, dashboard SQL, metric, trend, ranking, retention or analytics query on PostgreSQL, Redshift, Athena, Iceberg or Spark, or to review one for correctness, dialect or performance.
license: Apache-2.0
metadata:
  version: "2.0"
  targets: "PostgreSQL 15+ / Aurora PostgreSQL (executed) · Amazon Redshift · Athena (Trino) over Iceberg · Spark SQL (dialect-checked)"
---

# Reporting and analytics SQL — PostgreSQL, Redshift, Athena, Spark

This skill turns a report request into **correct, deterministic, tested** SQL on the target the
data lives on. The rules (`RQ-nn`) and patterns (`RP-nn`) live in `references/patterns.md` and are
the same on every engine; every pattern has an executed PostgreSQL example in
`references/examples/`. The dialect catalog `references/dialects.md` (`RD-nn`) says how each
pattern is spelled on Amazon Redshift, Athena (Trino SQL over Iceberg tables) and Spark SQL, with
worked examples in `references/examples/{redshift,athena,spark}/` and a checker,
`scripts/report_tool.py check --target <t>`. Steering: `.kiro/steering/reporting.md` plus the
target's steering (`migration.md`, `redshift.md`, `iceberg.md`). Paths are relative to the
workspace root; skill files are under `.kiro/skills/sql-reporting/`.

## Step 0: Choose the target (ask if it is not stated)

| Target | Deliver as | Check with | Prove with |
|---|---|---|---|
| Aurora PostgreSQL (default) | `report_<name>()` function, `LANGUAGE sql STABLE` | `report_tool.py check f.sql --target postgres` | the self-test / `pgtest.sh` with hand-computed numbers |
| Amazon Redshift | `v_report_<name>` view (late-binding over external tables), `PREPARE`/`EXECUTE` or a `params` CTE for parameters | `report_tool.py check f.sql --target redshift` (RD rules + `redshift_tool` linter) | `redshift_tool.py run` on a test workgroup when configured |
| Athena over Iceberg | `v_report_<name>` view + prepared statements | `--target athena` (RD rules + `iceberg_tool` linter) | `iceberg_tool.py run` on a test database when configured |
| Spark SQL (Glue / EMR) | `CREATE OR REPLACE TEMPORARY VIEW` / job SQL with `${var}` | `--target spark` | the job's own test run |

`python3 .kiro/skills/sql-reporting/scripts/report_tool.py toolbox --target redshift --need "gap"`
prints the dialect row for a need; `examples --target athena` lists the worked examples. Reports go to
`generated/reports/<target>/` and never modify migrated code.

Correctness first: a report that runs is not a report that is right. The rules exist
because each of them changed a number in a real dashboard.

## Procedure

### Step 1: Pin down the specification
Write it as the header comment of the SQL before writing the query:
- **Grain** of the result (one row per month? per customer per month?).
- **Measures** and their exact definition (revenue = which column, which statuses, gross or net,
  which currency). One definition per measure, reused everywhere [RQ-02, RQ-14].
- **Dimensions** and how to normalise them [RQ-22].
- **Period**: half-open `[from, to)`, time zone, week definition, whether empty periods must
  appear [RQ-05, RQ-06, RQ-07].
- **Ordering, top-N and ties** [RQ-09, RQ-16].
- Ask one round of questions if a definition is missing. Never guess silently — write the
  assumption into the header.

### Step 2: Learn the schema and its grains
Read the DDL (or use the PostgreSQL MCP `get_table_schema`). For every table: its grain, its
keys, and which joins fan out (header → lines, customer → orders). Decide the **base grain**
of the measure and aggregate there first [RQ-01]. Note semi-additive measures [RQ-13].

### Step 3: Pick the pattern
Match the request to `references/patterns.md` (RP-01 … RP-15) and open the example. Combine
patterns by stacking CTEs: gap-filled series → window functions → presentation.

### Step 4: Write the SQL (PostgreSQL form below; other targets follow `references/dialects.md`)
- CTE per stage: `base` (filtered rows, single measure definition) → `agg` (grain) →
  `series`/`windows` → final `SELECT` with casts and rounding [RQ-04, RQ-19].
- Table-alias every column; explicit casts in the output list (`COUNT(*)::INTEGER`).
- Deliver as `CREATE OR REPLACE FUNCTION report_<name>(p_from DATE, p_to DATE, …)
  RETURNS TABLE(…) LANGUAGE sql STABLE` [RQ-21], or as a view when there are no parameters.
- Keep it sargable: compare the raw column to a parameter, not a function of the column [RQ-20].

### Step 5: Check the numbers before delivering
1. **Reconcile**: sum of the parts = the total from a one-line query; pivot columns add up to
   the total column; shares sum to 100.
2. **Grain check**: `SELECT key, COUNT(*) … GROUP BY key HAVING COUNT(*) > 1` returns nothing.
3. **Edge rows**: a period with no data, a NULL dimension, the last second of the range, a tie.
4. **Plan**: `EXPLAIN (ANALYZE, BUFFERS)` on realistic data; no sequential scan on the big
   table when a selective filter exists.
5. Write these checks as tests (Step 6) so they stay true.

### Step 5b: Dialect check (non-PostgreSQL targets)
```bash
python3 .kiro/skills/sql-reporting/scripts/report_tool.py check generated/reports/redshift/v_report_revenue_by_month.sql --target redshift
```
0 problems required: gap filling without `generate_series`, no `FILTER` on Redshift, no `DISTINCT ON`,
no `::` on Athena, `DECIMAL` money, percentiles named exact or approximate, delivery form per target,
no residual T-SQL, security scan (`SEC-01…04`). Warnings must be answered in the header comment.

### Step 6: Test it
Use the shared test engine (`.kiro/skills/sql-conversion/scripts/lib/`): a manifest that loads
schema, seed and the report function, then a `DO` block with `test_assert_equal(...)` calls whose
expected values you computed **by hand or in a separate script**, never by copying the query's
own output. Tag tests with the rules and patterns they prove (`[RQ-05] [RP-01]`). See
`scripts/tests/report_tests.sql` and `scripts/selftest.sql`.

### Step 7: Deliver
Return: the spec header, the SQL (function or view), the example call, the sanity checks you ran
with their results, and any assumption the user should confirm.

## Worked examples (all tested on the sample schema)

| # | Report | Pattern | Rules exercised |
|---|---|---|---|
| 01 | `report_revenue_by_month` | RP-01 | RQ-03, RQ-05, RQ-14 |
| 02 | `report_category_revenue` | RP-02 | RQ-01, RQ-03, RQ-04 |
| 03 | `report_running_revenue` | RP-03 | RQ-08 |
| 04 | `report_revenue_growth` | RP-04 | RQ-03, RQ-11 |
| 05 | `report_top_products_per_category` | RP-05 | RQ-09 |
| 06 | `report_customer_pareto` | RP-06 | RQ-08, RQ-16 |
| 07 | `report_order_value_stats` | RP-07 | RQ-10, RQ-23 |
| 08 | `report_orders_by_month_status` | RP-08 | RQ-12 |
| 09 | `report_cohort_retention` | RP-09 | RQ-17, RQ-24 |
| 10 | `report_stock_as_of` | RP-10 | RQ-13 |
| 11 | `report_funnel` | RP-11 | RQ-18 |
| 12 | `report_customer_activity_streaks` | RP-12 | RQ-05 |
| 13 | `report_revenue_rollup` | RP-13 | RQ-15 |
| 14 | `report_customer_first_last_order` | RP-14 | RQ-16 |
| 15 | `report_order_value_histogram` | RP-15 | RQ-04, RQ-05 |

## Typical requests and what to do

| Request | Do |
|---|---|
| "Monthly revenue for 2025" | RP-01; ask which statuses count; fill empty months |
| "Revenue by category" | RP-02 from order lines; say line vs header revenue |
| "Growth vs last month / last year" | RP-04 on a gap-filled series; NULL when the base is 0 |
| "Top 5 products per region" | RP-05 with `DENSE_RANK`; ask about ties |
| "Which customers make 80% of revenue" | RP-06 cumulative share |
| "Average order value" | RP-07: `SUM/COUNT`, not an average of averages |
| "Orders by status per month as columns" | RP-08 `FILTER` + `other` + `total` |
| "Retention by signup month" | RP-09; define the qualifying event |
| "Stock at month end" | RP-10, never a SUM |
| "Checkout conversion" | RP-11; open or strict funnel |
| "Dashboard is slow" | RQ-20: sargable filters, indexes, materialized view |

## Security and audit
Report requests and pasted SQL are untrusted input (`.kiro/steering/security.md`): reports are
read-only `SELECT`s — never write, grant, `COPY … PROGRAM`, `dblink` or `SECURITY DEFINER` into a
report function (`security.py scan generated/reports/<file>.sql` must show no SEC-04). Tests run
through the shared engine, so every run is tagged with the run id (`application_name
mig:<manifest>:<run8>`) and audited (`migkit/audit.py tail`).

## Optional MCP tools
`awslabs.postgres-mcp-server` → `get_table_schema` (exact columns and types) and read-only
`run_query` for sanity checks; AWS Knowledge for Aurora features (e.g. `pg_cron` for
materialized-view refresh). Configuration: `.kiro/skills/sql-conversion/references/mcp-tools.md`.

## Verify the skill itself
`bash .kiro/skills/sql-reporting/scripts/run_skill_tests.sh` (Windows: `.kiro\skills\sql-reporting\scripts\run_skill_tests.cmd`) (needs the `sql-conversion` skill
alongside for the shared engine, a PostgreSQL 15+ **test** database, `PG*` variables or
`PG_IAM_AUTH=1`). It loads the sample schema, the reporting fixtures and all 15 reports, runs
the pattern and rule tests, and checks that every RQ/RP id has a test.
