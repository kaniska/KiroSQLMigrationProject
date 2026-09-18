-- Pattern RP-09 (Amazon Redshift) — Cohort retention (customers by first-purchase month)
-- Dialect: RD-13 DATEDIFF(month, …) counts month boundaries, RD-02, RD-12
-- Rules applied: RQ-17 (cohort = first revenue order; denominator = cohort size), RQ-24 COUNT(DISTINCT)
CREATE OR REPLACE VIEW sales.v_report_cohort_retention AS
WITH activity AS (
    SELECT DISTINCT o.customer_id, DATE_TRUNC('month', o.created_at)::DATE AS activity_month
    FROM   sales.orders o
    WHERE  o.status NOT IN ('Cancelled', 'Refunded')
),
cohorts AS (
    SELECT a.customer_id, MIN(a.activity_month) AS cohort_month FROM activity a GROUP BY a.customer_id
),
cohort_sizes AS (
    SELECT c.cohort_month, COUNT(*) AS cohort_size FROM cohorts c GROUP BY c.cohort_month
),
cells AS (
    SELECT c.cohort_month,
           DATEDIFF(month, c.cohort_month, a.activity_month) AS months_since,
           COUNT(DISTINCT a.customer_id)                     AS active_customers
    FROM   activity a JOIN cohorts c ON c.customer_id = a.customer_id
    GROUP  BY c.cohort_month, DATEDIFF(month, c.cohort_month, a.activity_month)
)
SELECT ce.cohort_month, ce.months_since, ce.active_customers::INTEGER AS active_customers, cs.cohort_size::INTEGER AS cohort_size,
       ROUND(ce.active_customers * 100.0 / cs.cohort_size, 2)::DECIMAL(5,2) AS retention_pct
FROM   cells ce JOIN cohort_sizes cs ON cs.cohort_month = ce.cohort_month;
