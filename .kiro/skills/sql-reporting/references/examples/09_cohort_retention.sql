-- Pattern RP-09 — Cohort retention (customers by first-purchase month)
-- Rules applied: RQ-17 (cohort = first revenue order; months_since counts month
--                boundaries; denominator = cohort size, not active customers),
--                RQ-24 (COUNT(DISTINCT customer) per cell)
CREATE OR REPLACE FUNCTION public.report_cohort_retention()
RETURNS TABLE(cohort_month DATE, months_since INTEGER, active_customers INTEGER, cohort_size INTEGER, retention_pct NUMERIC(5,2))
LANGUAGE sql STABLE
AS $$
    WITH activity AS (
        SELECT DISTINCT o.customer_id, date_trunc('month', o.created_at)::DATE AS activity_month
        FROM   public.orders o
        WHERE  o.status NOT IN ('Cancelled', 'Refunded')
    ),
    cohorts AS (
        SELECT a.customer_id, MIN(a.activity_month) AS cohort_month
        FROM   activity a
        GROUP  BY a.customer_id
    ),
    cohort_sizes AS (
        SELECT c.cohort_month, COUNT(*) AS cohort_size FROM cohorts c GROUP BY c.cohort_month
    ),
    cells AS (
        SELECT c.cohort_month,
               ((EXTRACT(YEAR FROM a.activity_month) - EXTRACT(YEAR FROM c.cohort_month)) * 12
                + EXTRACT(MONTH FROM a.activity_month) - EXTRACT(MONTH FROM c.cohort_month))::INTEGER AS months_since,
               COUNT(DISTINCT a.customer_id) AS active_customers
        FROM   activity a
        JOIN   cohorts  c ON c.customer_id = a.customer_id
        GROUP  BY c.cohort_month, 2
    )
    SELECT ce.cohort_month, ce.months_since, ce.active_customers::INTEGER, cs.cohort_size::INTEGER,
           ROUND(ce.active_customers * 100.0 / cs.cohort_size, 2)::NUMERIC(5,2)
    FROM   cells ce
    JOIN   cohort_sizes cs ON cs.cohort_month = ce.cohort_month
    ORDER  BY ce.cohort_month, ce.months_since;
$$;
-- SELECT * FROM public.report_cohort_retention();
