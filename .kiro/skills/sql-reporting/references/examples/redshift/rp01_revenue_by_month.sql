-- Pattern RP-01 (Amazon Redshift) — Revenue by month with gap filling
-- Dialect: RD-01 recursive CTE instead of generate_series (leader-node only), RD-02, RD-12, RD-14 (view; parameters in a params CTE — use PREPARE/EXECUTE for ad-hoc ranges)
-- Rules applied: RQ-05 half-open range, RQ-14 one revenue definition, RQ-03 COALESCE for empty months
CREATE OR REPLACE VIEW sales.v_report_revenue_by_month AS
WITH RECURSIVE params(p_from, p_to) AS (
    SELECT DATE '2024-01-01', DATE '2026-01-01'
),
months(period_start) AS (
    SELECT DATE_TRUNC('month', p.p_from)::DATE FROM params p
    UNION ALL
    SELECT DATEADD(month, 1, m.period_start)::DATE
    FROM   months m JOIN params p ON DATEADD(month, 1, m.period_start) < p.p_to
),
revenue_orders AS (                       -- the single definition of "revenue"
    SELECT DATE_TRUNC('month', o.created_at)::DATE AS period_start, o.total_amount
    FROM   sales.orders o JOIN params p ON o.created_at >= p.p_from AND o.created_at < p.p_to
    WHERE  o.status NOT IN ('Cancelled', 'Refunded')
)
SELECT m.period_start,
       COUNT(r.total_amount)::INTEGER                    AS order_count,
       COALESCE(SUM(r.total_amount), 0)::DECIMAL(19,4)   AS revenue
FROM   months m
LEFT   JOIN revenue_orders r ON r.period_start = m.period_start
GROUP  BY m.period_start;
-- SELECT * FROM sales.v_report_revenue_by_month ORDER BY period_start;
