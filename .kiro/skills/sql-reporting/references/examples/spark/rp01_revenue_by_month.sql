-- Pattern RP-01 (Spark SQL over Iceberg, Glue / EMR) — Revenue by month with gap filling
-- Dialect: RD-01 explode(sequence(...)), RD-02 trunc/date_trunc, RD-12 DECIMAL and cast before dividing, RD-14 temporary view (job SQL; ${var} substitution for parameters)
-- Rules applied: RQ-05, RQ-14, RQ-03
CREATE OR REPLACE TEMPORARY VIEW v_report_revenue_by_month AS
WITH params AS (
    SELECT DATE '2024-01-01' AS p_from, DATE '2026-01-01' AS p_to
),
months AS (
    SELECT explode(sequence(trunc(p.p_from, 'MONTH'), date_sub(p.p_to, 1), interval 1 month)) AS period_start
    FROM   params p
),
revenue_orders AS (
    SELECT CAST(date_trunc('MONTH', o.created_at) AS DATE) AS period_start, o.total_amount
    FROM   glue_catalog.sales_lake.orders o
    CROSS JOIN params p
    WHERE  o.created_at >= CAST(p.p_from AS TIMESTAMP) AND o.created_at < CAST(p.p_to AS TIMESTAMP)
      AND  o.status NOT IN ('Cancelled', 'Refunded')
)
SELECT m.period_start,
       count(r.total_amount)                                     AS order_count,
       coalesce(sum(r.total_amount), CAST(0 AS DECIMAL(19,4)))   AS revenue
FROM   months m
LEFT   JOIN revenue_orders r ON r.period_start = m.period_start
GROUP  BY m.period_start;
