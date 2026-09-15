-- Pattern RP-03 — Running total and moving average over a gap-filled series
-- Rules applied: RQ-08 (explicit ROWS frame; the default RANGE frame would merge
--                peers, and a moving average needs the gap-filled zero months),
--                RQ-05 (build on the gap-filled monthly series)
CREATE OR REPLACE FUNCTION public.report_running_revenue(p_year INTEGER)
RETURNS TABLE(period_start DATE, revenue NUMERIC(19,4), running_total NUMERIC(19,4), avg_3m NUMERIC(19,4))
LANGUAGE sql STABLE
AS $$
    SELECT m.period_start,
           m.revenue,
           SUM(m.revenue) OVER (ORDER BY m.period_start
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)::NUMERIC(19,4),
           -- first two rows average over 1 and 2 months (partial window) — say so in the report
           ROUND(AVG(m.revenue) OVER (ORDER BY m.period_start
                                      ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)::NUMERIC(19,4)
    FROM   public.report_revenue_by_month(make_date(p_year, 1, 1), make_date(p_year + 1, 1, 1)) m
    ORDER  BY m.period_start;
$$;
-- SELECT * FROM public.report_running_revenue(2025);
