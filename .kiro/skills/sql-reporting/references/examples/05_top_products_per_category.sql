-- Pattern RP-05 — Top-N per group, ties kept
-- Rules applied: RQ-09 (DENSE_RANK keeps ties and leaves no gaps; ROW_NUMBER would
--                drop a tied product arbitrarily), RQ-01 (aggregate first), RQ-16
CREATE OR REPLACE FUNCTION public.report_top_products_per_category(p_from DATE, p_to DATE, p_n INTEGER DEFAULT 3)
RETURNS TABLE(category VARCHAR(100), sku VARCHAR(50), units BIGINT, rnk BIGINT)
LANGUAGE sql STABLE
AS $$
    WITH product_units AS (
        SELECT p.category, p.sku, SUM(ol.quantity)::BIGINT AS units
        FROM   public.order_lines ol
        JOIN   public.orders   o ON o.order_id = ol.order_id
        JOIN   public.products p ON p.product_id = ol.product_id
        WHERE  o.created_at >= p_from AND o.created_at < p_to
          AND  o.status NOT IN ('Cancelled', 'Refunded')
        GROUP  BY p.category, p.sku
    ),
    ranked AS (
        SELECT pu.*, DENSE_RANK() OVER (PARTITION BY pu.category ORDER BY pu.units DESC) AS rnk
        FROM   product_units pu
    )
    SELECT r.category, r.sku, r.units, r.rnk
    FROM   ranked r
    WHERE  r.rnk <= p_n
    ORDER  BY r.category, r.rnk, r.sku;
$$;
-- SELECT * FROM public.report_top_products_per_category('2025-01-01', '2026-01-01', 1);
