-- Pattern RP-06 (Amazon Athena) — Ranking with share and cumulative share (Pareto / ABC)
-- Dialect: RD-04 share of total, RD-05 explicit ROWS frame, RD-12 DECIMAL, RD-11 concat with ||
-- Rules applied: RQ-08, RQ-16 customer_id tie-breaker, RQ-04
CREATE OR REPLACE VIEW sales_lake.v_report_customer_pareto AS
WITH lifetime AS (
    SELECT o.customer_id, sum(o.total_amount) AS revenue
    FROM   sales_lake.orders o
    WHERE  o.status NOT IN ('Cancelled', 'Refunded')
    GROUP  BY o.customer_id
)
SELECT row_number() OVER (ORDER BY l.revenue DESC, c.customer_id)                                   AS rnk,
       c.customer_id,
       c.first_name || ' ' || c.last_name                                                           AS customer_name,
       l.revenue                                                                                    AS lifetime_revenue,
       round(l.revenue * 100.0 / nullif(sum(l.revenue) OVER (), 0), 2)                              AS share_pct,
       round(sum(l.revenue) OVER (ORDER BY l.revenue DESC, c.customer_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) * 100.0
             / nullif(sum(l.revenue) OVER (), 0), 2)                                                AS cumulative_share_pct
FROM   lifetime l
JOIN   sales_lake.customers c ON c.customer_id = l.customer_id;
