-- Worked example 02 — Amazon Redshift late-binding edge view
-- Ledger: RS-10 GETDATE/DATEADD/DATEDIFF/LEN/CHARINDEX kept · RS-11 ISNULL → NVL · RS-12 IIF → CASE
--         RS-13 STRING_AGG → LISTAGG WITHIN GROUP · RS-14 + → ||, N'' dropped · RS-17 brackets → snake_case
--         RS-18 NOLOCK / TOP 100 PERCENT / ORDER BY in view removed · RS-52 WITH NO SCHEMA BINDING, schema-qualified
CREATE OR REPLACE VIEW sales.v_customer_summary AS
SELECT c.customer_key,
       c.customer_name || ' (' || c.region || ')'                                          AS display_name,
       NVL(SUM(f.line_total), 0)                                                          AS revenue,
       CASE WHEN MAX(f.sale_date) >= DATEADD(day, -30, GETDATE()) THEN 'ACTIVE' ELSE 'DORMANT' END AS status,
       DATEDIFF(day, MIN(f.sale_date), GETDATE())                                         AS days_since_first_sale,
       LISTAGG(TO_CHAR(f.sale_date, 'YYYY-MM-DD'), ',') WITHIN GROUP (ORDER BY f.sale_date) AS sale_dates,
       LEN(c.customer_name)                                                                AS name_length,
       CHARINDEX('Ltd', c.customer_name)                                                   AS ltd_pos
FROM   sales.dim_customer c
       LEFT JOIN sales.fact_sales f ON f.customer_key = c.customer_key
WHERE  c.is_active
GROUP BY c.customer_key, c.customer_name, c.region
WITH NO SCHEMA BINDING;
