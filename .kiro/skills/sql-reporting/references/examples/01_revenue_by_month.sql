-- Pattern RP-01 — Revenue by period with gap filling
-- Rules applied: RQ-05 (half-open range, generate_series fills empty months),
--                RQ-14 (one revenue definition), RQ-03 (COALESCE for empty periods)
-- Grain: one row per calendar month in [p_from, p_to), even months with no orders.
CREATE OR REPLACE FUNCTION public.report_revenue_by_month(p_from DATE, p_to DATE)
RETURNS TABLE(period_start DATE, order_count INTEGER, revenue NUMERIC(19,4))
LANGUAGE sql STABLE
AS $$
    WITH months AS (
        SELECT gs::DATE AS period_start
        FROM   generate_series(date_trunc('month', p_from::TIMESTAMP),
                               p_to::TIMESTAMP - INTERVAL '1 day', INTERVAL '1 month') gs
    ),
    revenue_orders AS (                       -- the single definition of "revenue"
        SELECT date_trunc('month', o.created_at)::DATE AS period_start, o.total_amount
        FROM   public.orders o
        WHERE  o.created_at >= p_from AND o.created_at < p_to   -- half-open, never BETWEEN
          AND  o.status NOT IN ('Cancelled', 'Refunded')
    )
    SELECT m.period_start,
           COUNT(r.total_amount)::INTEGER,                      -- COUNT(col): 0 for empty months
           COALESCE(SUM(r.total_amount), 0)::NUMERIC(19,4)     -- SUM over no rows is NULL
    FROM   months m
    LEFT   JOIN revenue_orders r ON r.period_start = m.period_start
    GROUP  BY m.period_start
    ORDER  BY m.period_start;
$$;
-- SELECT * FROM public.report_revenue_by_month('2025-01-01', '2026-01-01');
