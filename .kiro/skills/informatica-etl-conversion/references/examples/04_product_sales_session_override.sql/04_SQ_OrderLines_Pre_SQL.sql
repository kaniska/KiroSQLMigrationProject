-- #ActiveProducts → session temp table. Works only while Pre SQL and the read share one
-- connection (no partitioning / pooling): IC-22. A permanent staging table or a CTE is safer.
DROP TABLE IF EXISTS tmp_active_products;
CREATE TEMP TABLE tmp_active_products AS SELECT p.product_id FROM public.products p WHERE p.is_active
