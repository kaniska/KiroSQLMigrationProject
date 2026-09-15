-- Pattern RP-13 — Subtotals and grand total with GROUPING SETS
-- Rules applied: RQ-15 (GROUPING() tells a subtotal row from a NULL dimension value),
--                RQ-01 (line grain), RQ-16 (order subtotals after their detail rows)
CREATE OR REPLACE FUNCTION public.report_revenue_rollup(p_year INTEGER)
RETURNS TABLE(category VARCHAR(100), quarter INTEGER, revenue NUMERIC(19,4), is_category_total BOOLEAN, is_grand_total BOOLEAN)
LANGUAGE sql STABLE
AS $$
    WITH lines AS (
        SELECT p.category, EXTRACT(QUARTER FROM o.created_at)::INTEGER AS quarter,
               ol.quantity * ol.unit_price AS amount
        FROM   public.order_lines ol
        JOIN   public.orders   o ON o.order_id = ol.order_id
        JOIN   public.products p ON p.product_id = ol.product_id
        WHERE  o.created_at >= make_date(p_year, 1, 1) AND o.created_at < make_date(p_year + 1, 1, 1)
          AND  o.status NOT IN ('Cancelled', 'Refunded')
    )
    SELECT l.category, l.quarter, SUM(l.amount)::NUMERIC(19,4),
           GROUPING(l.quarter) = 1 AND GROUPING(l.category) = 0,
           GROUPING(l.category) = 1
    FROM   lines l
    GROUP  BY GROUPING SETS ((l.category, l.quarter), (l.category), ())
    ORDER  BY GROUPING(l.category), l.category, GROUPING(l.quarter), l.quarter;
$$;
-- SELECT * FROM public.report_revenue_rollup(2025);
