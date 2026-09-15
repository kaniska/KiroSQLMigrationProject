-- Pattern RP-15 — Histogram / bucketing of a measure
-- Rules applied: RQ-04 (bucket edges computed in NUMERIC), RQ-05 (half-open buckets
--                [start, end)), RQ-16
CREATE OR REPLACE FUNCTION public.report_order_value_histogram(p_from DATE, p_to DATE, p_bucket_width NUMERIC DEFAULT 100)
RETURNS TABLE(bucket_start NUMERIC(19,2), bucket_end NUMERIC(19,2), order_count INTEGER)
LANGUAGE sql STABLE
AS $$
    SELECT (FLOOR(o.total_amount / p_bucket_width) * p_bucket_width)::NUMERIC(19,2),
           ((FLOOR(o.total_amount / p_bucket_width) + 1) * p_bucket_width)::NUMERIC(19,2),
           COUNT(*)::INTEGER
    FROM   public.orders o
    WHERE  o.created_at >= p_from AND o.created_at < p_to
      AND  o.status NOT IN ('Cancelled', 'Refunded')
    GROUP  BY 1, 2
    ORDER  BY 1;
$$;
-- SELECT * FROM public.report_order_value_histogram('2025-01-01', '2026-01-01', 100);
