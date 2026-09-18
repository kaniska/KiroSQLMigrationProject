-- Pattern RP-04 (Amazon Athena) — Period-over-period growth (MoM, YoY)
-- Dialect: RD-06 LAG over the gap-filled view, RD-12 DECIMAL arithmetic, no :: cast operator on Trino
-- Rules applied: RQ-11, RQ-03 (nullif: growth from 0 is undefined)
CREATE OR REPLACE VIEW sales_lake.v_report_revenue_growth AS
WITH lagged AS (
    SELECT s.period_start, s.revenue,
           lag(s.revenue)     OVER (ORDER BY s.period_start) AS prior_month,
           lag(s.revenue, 12) OVER (ORDER BY s.period_start) AS prior_year
    FROM   sales_lake.v_report_revenue_by_month s
)
SELECT l.period_start, l.revenue, l.prior_month,
       round((l.revenue - l.prior_month) * 100.0 / nullif(l.prior_month, 0), 2) AS mom_pct,
       l.prior_year,
       round((l.revenue - l.prior_year) * 100.0 / nullif(l.prior_year, 0), 2)   AS yoy_pct
FROM   lagged l
WHERE  l.period_start >= DATE '2025-01-01';
