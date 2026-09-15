ANALYZE public.stg_orders;
SELECT public.etl_log_load('Stg_Orders', $$LOAD_ID)
