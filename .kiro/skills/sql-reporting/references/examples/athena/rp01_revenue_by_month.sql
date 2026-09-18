-- Pattern RP-01 (Amazon Athena, Trino SQL over Iceberg tables) — Revenue by month with gap filling
-- Dialect: RD-01 UNNEST(sequence(...)), RD-02 CAST(date_trunc(...) AS DATE), RD-12 DECIMAL, RD-14 view + params CTE
--          (ad-hoc ranges: PREPARE stmt FROM SELECT ... WHERE created_at >= ? ... ; EXECUTE stmt USING DATE '2025-01-01', DATE '2026-01-01')
-- Rules applied: RQ-05 half-open range, RQ-14 one revenue definition, RQ-03 coalesce for empty months
CREATE OR REPLACE VIEW sales_lake.v_report_revenue_by_month AS
WITH params AS (
    SELECT DATE '2024-01-01' AS p_from, DATE '2026-01-01' AS p_to
),
months AS (
    SELECT CAST(m AS DATE) AS period_start
    FROM   params p
    CROSS JOIN UNNEST(sequence(date_trunc('month', p.p_from), date_add('day', -1, p.p_to), INTERVAL '1' MONTH)) AS t(m)
),
revenue_orders AS (
    SELECT CAST(date_trunc('month', o.created_at) AS DATE) AS period_start, o.total_amount
    FROM   sales_lake.orders o
    CROSS JOIN params p
    WHERE  o.created_at >= CAST(p.p_from AS TIMESTAMP) AND o.created_at < CAST(p.p_to AS TIMESTAMP)
      AND  o.status NOT IN ('Cancelled', 'Refunded')
)
SELECT m.period_start,
       count(r.total_amount)                                       AS order_count,
       coalesce(sum(r.total_amount), CAST(0 AS DECIMAL(19,4)))     AS revenue
FROM   months m
LEFT   JOIN revenue_orders r ON r.period_start = m.period_start
GROUP  BY m.period_start;
