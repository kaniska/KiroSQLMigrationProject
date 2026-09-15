-- Pattern RP-06 — Ranking with share and cumulative share (Pareto / ABC)
-- Rules applied: RQ-08 (ROWS frame for the cumulative sum), RQ-16 (customer_id
--                tie-breaker so equal revenues rank deterministically), RQ-04
CREATE OR REPLACE FUNCTION public.report_customer_pareto()
RETURNS TABLE(rnk BIGINT, customer_id INTEGER, customer_name TEXT, lifetime_revenue NUMERIC(19,4),
              share_pct NUMERIC(5,2), cumulative_share_pct NUMERIC(5,2))
LANGUAGE sql STABLE
AS $$
    WITH lifetime AS (
        SELECT o.customer_id, SUM(o.total_amount) AS revenue
        FROM   public.orders o
        WHERE  o.status NOT IN ('Cancelled', 'Refunded')
        GROUP  BY o.customer_id
    )
    SELECT ROW_NUMBER() OVER w,
           c.customer_id,
           c.first_name || ' ' || c.last_name,
           l.revenue::NUMERIC(19,4),
           ROUND(l.revenue * 100.0 / SUM(l.revenue) OVER (), 2)::NUMERIC(5,2),
           ROUND(SUM(l.revenue) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) * 100.0
                 / SUM(l.revenue) OVER (), 2)::NUMERIC(5,2)
    FROM   lifetime l
    JOIN   public.customers c ON c.customer_id = l.customer_id
    WINDOW w AS (ORDER BY l.revenue DESC, c.customer_id)
    ORDER  BY 1;
$$;
-- SELECT * FROM public.report_customer_pareto();
