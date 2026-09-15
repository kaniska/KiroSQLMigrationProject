-- SET NOCOUNT ON has no PostgreSQL equivalent and is dropped (IC-11)
-- IF OBJECT_ID(N'dbo.Stg_Customer_Summary', N'U') IS NOT NULL: the staging table is part of the target schema, so the TRUNCATE is unconditional (IC-11)
TRUNCATE TABLE public.stg_customer_summary;
-- EXEC dbo.usp_EtlRunStart @JobName = N'...', @LoadId = $$LOAD_ID → function converted with the sql-conversion skill (IC-13)
SELECT public.etl_run_start('wf_Load_Customer_Summary', $$LOAD_ID)
