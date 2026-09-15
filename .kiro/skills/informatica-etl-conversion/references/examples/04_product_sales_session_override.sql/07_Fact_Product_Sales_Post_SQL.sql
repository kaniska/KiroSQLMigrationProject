INSERT INTO public.audit_load (load_name, row_count, loaded_at)
SELECT 'Product Sales', COUNT(*), LOCALTIMESTAMP FROM public.fact_product_sales;
-- TODO: MANUAL REVIEW REQUIRED — "DBCC SHRINKFILE (SalesDW_log, 1)" has no PostgreSQL equivalent
-- (WAL is managed by the server) and was removed. No semicolons in comments here: Informatica splits on them.
