---
inclusion: always
---

# Reporting and Analytics SQL — Rules Across Targets

Rules for generating report, dashboard, KPI and analytics SQL on the converted data, whatever the
target: **Aurora PostgreSQL**, **Amazon Redshift**, **Iceberg on S3 queried with Athena (Trino
SQL)** or **Spark SQL** (Glue / EMR). Implemented by `.kiro/skills/sql-reporting/SKILL.md`. The
correctness rules `RQ-01…RQ-24` and patterns `RP-01…RP-15` (`references/patterns.md`) are
target-independent; the dialect rules `RD-01…RD-18` (`references/dialects.md`) say how each pattern
is written on each engine. Rule ids `[RE-n]`.

## Hard rules

1. **[RE-1] Correctness rules first, dialect second.** Grain, one measure definition, half-open
   ranges, gap filling, NULL-safe arithmetic, deterministic order, explicit ranking, cohorts and
   funnels follow `RQ-nn` on every target; the dialect only changes the spelling [RD-01…RD-18].
2. **[RE-2] The target is a decision, not a guess.** A report request names its target (or the
   agent asks): PostgreSQL (`report_<name>()` function, `LANGUAGE sql STABLE`), Redshift (view or
   late-binding view, parameters via `PREPARE`/`EXECUTE` or a `params` CTE, procedures with a
   refcursor only when necessary), Athena (view + prepared statement, no user functions), Spark
   (temporary view / job SQL with `${var}` substitution) [RD-14].
3. **[RE-3] Gap filling per engine:** `generate_series` on PostgreSQL only; Redshift uses a
   recursive CTE or a date dimension (`generate_series` runs on the leader node and cannot join user
   tables); Athena `UNNEST(sequence(…))`; Spark `explode(sequence(…))` [RD-01].
4. **[RE-4] Money and ratios stay exact:** `NUMERIC`/`DECIMAL` everywhere; on Spark cast before
   dividing (`/` is floating-point) and never `double` for money [RD-12].
5. **[RE-5] Engine-specific functions are spelled per the dialect table:** conditional aggregates
   (`FILTER` vs `CASE`), string aggregation (`string_agg` / `LISTAGG` / `listagg`·`array_join` /
   `array_join(collect_list)`), percentiles (exact vs approximate — say which), latest row per key
   (`DISTINCT ON` is PostgreSQL only), time zones (`AT TIME ZONE` / `CONVERT_TIMEZONE` /
   `from_utc_timestamp`), month arithmetic (`EXTRACT` / `DATEDIFF(month)` / `date_diff('month')` /
   year·month arithmetic) [RD-03, RD-08, RD-10, RD-11, RD-13, RD-18].
6. **[RE-6] Check, then prove.** `report_tool.py check --target <t>` must report 0 problems (it
   runs the target's residual-SQL linter plus the reporting dialect rules). PostgreSQL reports are
   executed by the self-test with hand-computed expected numbers; Redshift and Athena reports are
   executed on a test workgroup/database when configured (`redshift_tool.py run`,
   `iceberg_tool.py run`), otherwise the execution check stays listed as unexecuted [RD-16].
7. **[RE-7] Reports never change migrated code.** They are additive objects (`report_*`,
   `v_report_*`) in their own folder (`generated/reports/<target>/`); schema questions go to
   `schema-conformance` snapshots, not to guesses.

## Which steering applies per target

| Target | Dialect rules | Also apply |
|---|---|---|
| Aurora PostgreSQL | `RD-nn` PostgreSQL column | `migration.md` (type map, naming) |
| Amazon Redshift | `RD-nn` Redshift column | `redshift.md` [R-2…R-5, R-11, R-12] |
| Athena over Iceberg | `RD-nn` Athena column | `iceberg.md` [I-6, I-8] |
| Spark SQL over Iceberg | `RD-nn` Spark column | `iceberg.md` [I-6, I-9] |
