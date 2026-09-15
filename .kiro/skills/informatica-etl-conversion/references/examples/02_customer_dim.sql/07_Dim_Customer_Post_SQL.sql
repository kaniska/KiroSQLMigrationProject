MERGE INTO public.dim_customer AS tgt
USING public.stg_customer AS src ON tgt.customer_id = src.customer_id
WHEN MATCHED THEN UPDATE SET email = src.email, updated_at = LOCALTIMESTAMP
WHEN NOT MATCHED THEN INSERT (customer_id, first_name, last_name, email, is_current)
     VALUES (src.customer_id, src.first_name, src.last_name, src.email, TRUE)
