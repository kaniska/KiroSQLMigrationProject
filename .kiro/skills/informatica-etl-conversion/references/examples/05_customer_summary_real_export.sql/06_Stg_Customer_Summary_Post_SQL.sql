-- UPDATE STATISTICS … WITH FULLSCAN → ANALYZE (always a full sample in PostgreSQL) (IC-11)
ANALYZE public.stg_customer_summary;
-- GETDATE() → LOCALTIMESTAMP. The escaped \; stays escaped because Informatica splits Pre/Post SQL at every semicolon (IC-10)
UPDATE public.etl_run_log SET ended_at = LOCALTIMESTAMP, rows_loaded = (SELECT COUNT(*) FROM public.stg_customer_summary), note = 'loaded\; see summary' WHERE load_id = $$LOAD_ID AND ended_at IS NULL
