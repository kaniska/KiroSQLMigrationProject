-- Pattern RP-09 (Amazon Athena) — Cohort retention
-- Dialect: RD-13 date_diff('month', a, b) on first-of-month dates, RD-02, RD-12
-- Rules applied: RQ-17, RQ-24 count(DISTINCT)
CREATE OR REPLACE VIEW sales_lake.v_report_cohort_retention AS
WITH activity AS (
    SELECT DISTINCT o.customer_id, CAST(date_trunc('month', o.created_at) AS DATE) AS activity_month
    FROM   sales_lake.orders o
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
           date_diff('month', c.cohort_month, a.activity_month) AS months_since,
           count(DISTINCT a.customer_id)                        AS active_customers
    FROM   activity a JOIN cohorts c ON c.customer_id = a.customer_id
    GROUP  BY c.cohort_month, date_diff('month', c.cohort_month, a.activity_month)
)
SELECT ce.cohort_month, ce.months_since, ce.active_customers, cs.cohort_size,
       round(CAST(ce.active_customers AS DECIMAL(19,4)) * 100 / cs.cohort_size, 2) AS retention_pct
FROM   cells ce JOIN cohort_sizes cs ON cs.cohort_month = ce.cohort_month;
