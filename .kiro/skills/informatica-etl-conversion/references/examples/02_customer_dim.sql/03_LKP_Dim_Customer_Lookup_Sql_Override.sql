SELECT d.customer_key AS CustomerKey, d.customer_id AS CustomerId, TRIM(d.email) AS Email
FROM public.dim_customer d
WHERE d.is_current
ORDER BY d.customer_id --
