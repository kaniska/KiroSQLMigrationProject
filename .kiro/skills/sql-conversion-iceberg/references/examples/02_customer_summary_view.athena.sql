-- Worked example 02 — Amazon Athena view over Iceberg tables (Trino SQL; BI edge view, IB-70)
-- Ledger: IB-40 ISNULL → coalesce · IB-41 IIF → CASE · IB-42 GETDATE → current_timestamp · IB-43 date_add/date_diff argument order
--         IB-44 CHARINDEX → strpos, LEN → length · IB-45 TOP removed · IB-46 + → || · IB-47 STRING_AGG → listagg · IB-51 brackets/NOLOCK removed
CREATE OR REPLACE VIEW sales_lake.v_customer_summary AS
SELECT c.customer_key,
       c.customer_name || ' (' || c.region || ')'                                                    AS display_name,
       coalesce(sum(f.line_total), 0)                                                              AS revenue,
       CASE WHEN max(f.sale_date) >= date_add('day', -30, current_date) THEN 'ACTIVE' ELSE 'DORMANT' END AS status,
       date_diff('day', min(f.sale_date), current_date)                                            AS days_since_first_sale,
       listagg(cast(f.sale_date AS varchar), ',') WITHIN GROUP (ORDER BY f.sale_date)               AS sale_dates,
       length(c.customer_name)                                                                     AS name_length,
       strpos(c.customer_name, 'Ltd')                                                              AS ltd_pos
FROM   sales_lake.dim_customer c
       LEFT JOIN sales_lake.fact_sales f ON f.customer_key = c.customer_key
WHERE  c.is_active
GROUP BY c.customer_key, c.customer_name, c.region;
