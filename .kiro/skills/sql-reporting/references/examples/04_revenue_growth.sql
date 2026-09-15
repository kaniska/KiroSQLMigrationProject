-- Pattern RP-04 — Period-over-period growth (MoM, YoY)
-- Rules applied: RQ-11 (LAG only over a gap-filled series — otherwise the "prior
--                month" of August is June), RQ-03 (NULLIF: growth from 0 is undefined,
--                not infinite or an error)
CREATE OR REPLACE FUNCTION public.report_revenue_growth(p_year INTEGER)
RETURNS TABLE(period_start DATE, revenue NUMERIC(19,4), prior_month NUMERIC(19,4), mom_pct NUMERIC(8,2),
              prior_year NUMERIC(19,4), yoy_pct NUMERIC(8,2))
LANGUAGE sql STABLE
AS $$
    WITH series AS (                          -- two full years, every month present
        SELECT * FROM public.report_revenue_by_month(make_date(p_year - 1, 1, 1), make_date(p_year + 1, 1, 1))
    ),
    lagged AS (
        SELECT s.period_start, s.revenue,
               LAG(s.revenue)     OVER (ORDER BY s.period_start) AS prior_month,
               LAG(s.revenue, 12) OVER (ORDER BY s.period_start) AS prior_year
        FROM   series s
    )
    SELECT l.period_start, l.revenue, l.prior_month,
           ROUND((l.revenue - l.prior_month) * 100.0 / NULLIF(l.prior_month, 0), 2)::NUMERIC(8,2),
           l.prior_year,
           ROUND((l.revenue - l.prior_year) * 100.0 / NULLIF(l.prior_year, 0), 2)::NUMERIC(8,2)
    FROM   lagged l
    WHERE  l.period_start >= make_date(p_year, 1, 1)
    ORDER  BY l.period_start;
$$;
-- SELECT * FROM public.report_revenue_growth(2025);
