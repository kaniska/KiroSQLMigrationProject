-- Pattern RP-02 — Revenue by dimension from a child table, without join fan-out
-- Rules applied: RQ-01 (aggregate at the line grain; COUNT(DISTINCT) for orders),
--                RQ-03/RQ-04 (NULLIF + ROUND for the share), RQ-16 (tie-breaker in ORDER BY)
-- NOTE: line revenue (SUM(qty × unit_price)) is not the same number as order revenue
-- (orders.total_amount) when orders carry discounts or header-only amounts. State
-- which one a report uses (RQ-14).
CREATE OR REPLACE FUNCTION public.report_category_revenue(p_from DATE, p_to DATE)
RETURNS TABLE(category VARCHAR(100), revenue NUMERIC(19,4), share_pct NUMERIC(5,2), order_count INTEGER)
LANGUAGE sql STABLE
AS $$
    WITH revenue_orders AS (
        SELECT o.order_id
        FROM   public.orders o
        WHERE  o.created_at >= p_from AND o.created_at < p_to
          AND  o.status NOT IN ('Cancelled', 'Refunded')
    ),
    category_lines AS (                       -- aggregate BEFORE anything can fan out
        SELECT p.category,
               SUM(ol.quantity * ol.unit_price) AS revenue,
               COUNT(DISTINCT ol.order_id)      AS order_count
        FROM   public.order_lines ol
        JOIN   revenue_orders r USING (order_id)
        JOIN   public.products p ON p.product_id = ol.product_id
        GROUP  BY p.category
    )
    SELECT cl.category,
           cl.revenue::NUMERIC(19,4),
           ROUND(cl.revenue * 100.0 / NULLIF(SUM(cl.revenue) OVER (), 0), 2)::NUMERIC(5,2),
           cl.order_count::INTEGER
    FROM   category_lines cl
    ORDER  BY cl.revenue DESC, cl.category;
$$;
-- SELECT * FROM public.report_category_revenue('2025-01-01', '2026-01-01');
