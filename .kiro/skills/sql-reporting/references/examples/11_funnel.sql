-- Pattern RP-11 — Funnel with step-to-step and overall conversion
-- Rules applied: RQ-18 (count DISTINCT users per step, not events; steps come from a
--                VALUES list so an empty step still appears), RQ-03 (NULLIF)
-- Variant: a STRICT funnel (a user counts for step n only if they did step n-1
-- earlier) needs a self-join or LAG per user — this is the open funnel.
CREATE OR REPLACE FUNCTION public.report_funnel(p_from DATE, p_to DATE)
RETURNS TABLE(step INTEGER, event_type VARCHAR(20), users INTEGER, pct_of_previous NUMERIC(5,2), pct_of_first NUMERIC(5,2))
LANGUAGE sql STABLE
AS $$
    WITH steps(step, event_type) AS (
        VALUES (1, 'view'), (2, 'cart'), (3, 'checkout'), (4, 'purchase')
    ),
    step_users AS (
        SELECT s.step, s.event_type, COUNT(DISTINCT e.customer_id) AS users
        FROM   steps s
        LEFT   JOIN public.web_events e
               ON  e.event_type = s.event_type
               AND e.event_at >= p_from AND e.event_at < p_to
        GROUP  BY s.step, s.event_type
    )
    SELECT su.step, su.event_type::VARCHAR(20), su.users::INTEGER,
           ROUND(su.users * 100.0 / NULLIF(LAG(su.users) OVER (ORDER BY su.step), 0), 2)::NUMERIC(5,2),
           ROUND(su.users * 100.0 / NULLIF(FIRST_VALUE(su.users) OVER (ORDER BY su.step), 0), 2)::NUMERIC(5,2)
    FROM   step_users su
    ORDER  BY su.step;
$$;
-- SELECT * FROM public.report_funnel('2025-06-01', '2025-07-01');
