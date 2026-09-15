-- Pattern RP-07 — Distribution statistics: mean, median, percentiles
-- Rules applied: RQ-10 (percentile_cont interpolates, percentile_disc returns a real
--                value — pick one and name it), RQ-23 (the mean is SUM/COUNT over the
--                whole set, never an average of period averages), RQ-19 (NUMERIC)
CREATE OR REPLACE FUNCTION public.report_order_value_stats(p_from DATE, p_to DATE)
RETURNS TABLE(order_count INTEGER, avg_order_value NUMERIC(19,2), median_order_value NUMERIC(19,2),
              p90_order_value NUMERIC(19,2), p90_discrete NUMERIC(19,4), min_order NUMERIC(19,4), max_order NUMERIC(19,4))
LANGUAGE sql STABLE
AS $$
    SELECT COUNT(*)::INTEGER,
           ROUND(AVG(o.total_amount), 2),
           ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY o.total_amount)::NUMERIC, 2),
           ROUND(percentile_cont(0.9) WITHIN GROUP (ORDER BY o.total_amount)::NUMERIC, 2),
           percentile_disc(0.9) WITHIN GROUP (ORDER BY o.total_amount),
           MIN(o.total_amount),
           MAX(o.total_amount)
    FROM   public.orders o
    WHERE  o.created_at >= p_from AND o.created_at < p_to
      AND  o.status NOT IN ('Cancelled', 'Refunded');
$$;
-- SELECT * FROM public.report_order_value_stats('2025-01-01', '2026-01-01');
