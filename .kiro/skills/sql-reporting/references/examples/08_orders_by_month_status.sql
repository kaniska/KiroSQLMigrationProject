-- Pattern RP-08 — Pivot (one column per category value) with FILTER
-- Rules applied: RQ-12 (FILTER instead of SUM(CASE…); an explicit "other" bucket so
--                unexpected values are visible; a total column to reconcile against)
CREATE OR REPLACE FUNCTION public.report_orders_by_month_status(p_year INTEGER)
RETURNS TABLE(period_start DATE, completed INTEGER, processed INTEGER, pending INTEGER,
              cancelled INTEGER, refunded INTEGER, other INTEGER, total INTEGER)
LANGUAGE sql STABLE
AS $$
    SELECT date_trunc('month', o.created_at)::DATE,
           COUNT(*) FILTER (WHERE o.status = 'Completed')::INTEGER,
           COUNT(*) FILTER (WHERE o.status = 'Processed')::INTEGER,
           COUNT(*) FILTER (WHERE o.status = 'Pending')::INTEGER,
           COUNT(*) FILTER (WHERE o.status = 'Cancelled')::INTEGER,
           COUNT(*) FILTER (WHERE o.status = 'Refunded')::INTEGER,
           COUNT(*) FILTER (WHERE o.status IS NULL
                               OR o.status NOT IN ('Completed', 'Processed', 'Pending', 'Cancelled', 'Refunded'))::INTEGER,
           COUNT(*)::INTEGER
    FROM   public.orders o
    WHERE  o.created_at >= make_date(p_year, 1, 1) AND o.created_at < make_date(p_year + 1, 1, 1)
    GROUP  BY 1
    ORDER  BY 1;
$$;
-- SELECT * FROM public.report_orders_by_month_status(2025);
