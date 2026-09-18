-- Pattern RP-06 (Amazon Redshift) — Ranking with share and cumulative share (Pareto / ABC)
-- Dialect: RD-04 share of total (RATIO_TO_REPORT is the Redshift shortcut), RD-05 explicit ROWS frame,
--          no named WINDOW clause on Redshift (inlined), RD-12 DECIMAL, VARCHAR instead of TEXT
-- Rules applied: RQ-08, RQ-16 customer_id tie-breaker, RQ-04 cast before dividing
CREATE OR REPLACE VIEW sales.v_report_customer_pareto AS
WITH lifetime AS (
    SELECT o.customer_id, SUM(o.total_amount) AS revenue
    FROM   sales.orders o
    WHERE  o.status NOT IN ('Cancelled', 'Refunded')
    GROUP  BY o.customer_id
)
SELECT ROW_NUMBER() OVER (ORDER BY l.revenue DESC, c.customer_id)                       AS rnk,
       c.customer_id,
       (c.first_name || ' ' || c.last_name)::VARCHAR(201)                                AS customer_name,
       l.revenue::DECIMAL(19,4)                                                          AS lifetime_revenue,
       ROUND(l.revenue * 100.0 / NULLIF(SUM(l.revenue) OVER (), 0), 2)::DECIMAL(5,2)    AS share_pct,
       ROUND(SUM(l.revenue) OVER (ORDER BY l.revenue DESC, c.customer_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) * 100.0
             / NULLIF(SUM(l.revenue) OVER (), 0), 2)::DECIMAL(5,2)                       AS cumulative_share_pct
FROM   lifetime l
JOIN   sales.customers c ON c.customer_id = l.customer_id;
