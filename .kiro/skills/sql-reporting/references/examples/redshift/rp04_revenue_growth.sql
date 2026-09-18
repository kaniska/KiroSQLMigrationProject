-- Pattern RP-04 (Amazon Redshift) — Period-over-period growth (MoM, YoY)
-- Dialect: RD-06 LAG over the gap-filled view, RD-12 DECIMAL, RD-14 view
-- Rules applied: RQ-11 (LAG only over a gap-filled series), RQ-03 (NULLIF: growth from 0 is undefined)
CREATE OR REPLACE VIEW sales.v_report_revenue_growth AS
WITH lagged AS (
    SELECT s.period_start, s.revenue,
           LAG(s.revenue)     OVER (ORDER BY s.period_start) AS prior_month,
           LAG(s.revenue, 12) OVER (ORDER BY s.period_start) AS prior_year
    FROM   sales.v_report_revenue_by_month s
)
SELECT l.period_start, l.revenue, l.prior_month,
       ROUND((l.revenue - l.prior_month) * 100.0 / NULLIF(l.prior_month, 0), 2)::DECIMAL(8,2) AS mom_pct,
       l.prior_year,
       ROUND((l.revenue - l.prior_year) * 100.0 / NULLIF(l.prior_year, 0), 2)::DECIMAL(8,2)   AS yoy_pct
FROM   lagged l
WHERE  l.period_start >= DATE '2025-01-01';
