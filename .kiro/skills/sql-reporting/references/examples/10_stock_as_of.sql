-- Pattern RP-10 — Semi-additive measure: balance as of a date (last snapshot, not a sum)
-- Rules applied: RQ-13 (stock levels are point-in-time; never SUM them across dates),
--                RQ-16 (DISTINCT ON needs a complete ORDER BY)
CREATE OR REPLACE FUNCTION public.report_stock_as_of(p_as_of DATE)
RETURNS TABLE(product_id INTEGER, warehouse_id INTEGER, quantity_on_hand INTEGER, snapshot_date DATE)
LANGUAGE sql STABLE
AS $$
    SELECT DISTINCT ON (s.product_id, s.warehouse_id)
           s.product_id, s.warehouse_id, s.quantity_on_hand, s.snapshot_date
    FROM   public.inventory_snapshots s
    WHERE  s.snapshot_date <= p_as_of
    ORDER  BY s.product_id, s.warehouse_id, s.snapshot_date DESC;
$$;
-- SELECT SUM(quantity_on_hand) FROM public.report_stock_as_of('2025-06-30');
