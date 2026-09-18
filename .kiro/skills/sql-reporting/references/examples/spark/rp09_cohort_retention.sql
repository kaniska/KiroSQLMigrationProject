-- Pattern RP-09 (Spark SQL) — Cohort retention
-- Dialect: RD-13 year/month arithmetic (months_between is fractional), RD-12 cast before dividing, RD-02
-- Rules applied: RQ-17, RQ-24
CREATE OR REPLACE TEMPORARY VIEW v_report_cohort_retention AS
WITH activity AS (
    SELECT DISTINCT o.customer_id, CAST(date_trunc('MONTH', o.created_at) AS DATE) AS activity_month
    FROM   glue_catalog.sales_lake.orders o
    WHERE  o.status NOT IN ('Cancelled', 'Refunded')
),
cohorts AS (
    SELECT a.customer_id, min(a.activity_month) AS cohort_month FROM activity a GROUP BY a.customer_id
),
cohort_sizes AS (
    SELECT c.cohort_month, count(*) AS cohort_size FROM cohorts c GROUP BY c.cohort_month
),
cells AS (
    SELECT c.cohort_month,
           (year(a.activity_month) - year(c.cohort_month)) * 12 + month(a.activity_month) - month(c.cohort_month) AS months_since,
           count(DISTINCT a.customer_id) AS active_customers
    FROM   activity a JOIN cohorts c ON c.customer_id = a.customer_id
    GROUP  BY c.cohort_month, (year(a.activity_month) - year(c.cohort_month)) * 12 + month(a.activity_month) - month(c.cohort_month)
)
SELECT ce.cohort_month, ce.months_since, ce.active_customers, cs.cohort_size,
       round(CAST(ce.active_customers AS DECIMAL(19,4)) * 100 / cs.cohort_size, 2) AS retention_pct
FROM   cells ce JOIN cohort_sizes cs ON cs.cohort_month = ce.cohort_month;
