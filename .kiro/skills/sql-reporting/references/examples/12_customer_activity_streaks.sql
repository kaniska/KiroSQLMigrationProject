-- Pattern RP-12 — Gaps and islands: consecutive active months per customer
-- Rules applied: RQ-05 (month arithmetic on a month number, not on dates), RQ-16
CREATE OR REPLACE FUNCTION public.report_customer_activity_streaks(p_customer_id INTEGER)
RETURNS TABLE(streak_start DATE, streak_end DATE, months INTEGER)
LANGUAGE sql STABLE
AS $$
    WITH active_months AS (
        SELECT DISTINCT date_trunc('month', o.created_at)::DATE AS m
        FROM   public.orders o
        WHERE  o.customer_id = p_customer_id
          AND  o.status NOT IN ('Cancelled', 'Refunded')
    ),
    grouped AS (
        -- month_number - row_number is constant inside one unbroken run of months
        SELECT am.m,
               (EXTRACT(YEAR FROM am.m) * 12 + EXTRACT(MONTH FROM am.m))::INTEGER
                 - ROW_NUMBER() OVER (ORDER BY am.m) AS island
        FROM   active_months am
    )
    SELECT MIN(g.m), MAX(g.m), COUNT(*)::INTEGER
    FROM   grouped g
    GROUP  BY g.island
    ORDER  BY 1;
$$;
-- SELECT * FROM public.report_customer_activity_streaks(1);
