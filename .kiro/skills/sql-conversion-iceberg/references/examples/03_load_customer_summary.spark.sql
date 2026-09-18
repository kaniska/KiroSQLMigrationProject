-- Worked example 03 — Spark SQL for the Glue job (the procedure body becomes a set-based load; IB-06, IB-71)
-- Ledger: IB-63 SELECT INTO #stage → TEMPORARY VIEW · IB-60/61 MERGE with deduplicated source, BY SOURCE → separate DELETE
--         IB-42 GETDATE → current_timestamp · IB-43 DATEADD → date_add · IB-51 SET NOCOUNT/@@ROWCOUNT/RETURN → job metrics
-- Parameters: ${as_of} (DATE) supplied by the job arguments.
CREATE OR REPLACE TEMPORARY VIEW stage AS
SELECT c.customer_key, sum(f.line_total) AS revenue, max(f.sale_date) AS last_sale
FROM   glue_catalog.sales_lake.dim_customer c
       JOIN glue_catalog.sales_lake.fact_sales f ON f.customer_key = c.customer_key
WHERE  f.sale_date <= to_date('${as_of}')
GROUP BY c.customer_key;

-- WHEN NOT MATCHED BY SOURCE THEN DELETE (portable form)
DELETE FROM glue_catalog.sales_lake.customer_summary
WHERE  customer_key NOT IN (SELECT customer_key FROM stage);

MERGE INTO glue_catalog.sales_lake.customer_summary t
USING (SELECT customer_key, revenue, last_sale
       FROM (SELECT s.*, row_number() OVER (PARTITION BY customer_key ORDER BY last_sale DESC) AS rn FROM stage s) d
       WHERE d.rn = 1) s
ON t.customer_key = s.customer_key
WHEN MATCHED AND t.revenue <> s.revenue THEN UPDATE SET revenue = s.revenue, last_sale = s.last_sale, updated_at = current_timestamp()
WHEN NOT MATCHED THEN INSERT (customer_key, revenue, last_sale, updated_at) VALUES (s.customer_key, s.revenue, s.last_sale, current_timestamp());

-- result set of the procedure → the caller reads the table (or an Athena view) at the new snapshot (IB-73)
SELECT customer_key, revenue
FROM   glue_catalog.sales_lake.customer_summary
WHERE  last_sale >= date_add(to_date('${as_of}'), -7);
