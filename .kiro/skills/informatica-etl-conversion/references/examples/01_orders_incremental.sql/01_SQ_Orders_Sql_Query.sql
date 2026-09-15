SELECT o.order_id, o.customer_id,
       COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '') AS customer_name,
       o.total_amount, o.status,
       date_trunc('day', o.created_at) AS order_date
FROM public.orders o
LEFT JOIN public.customers c ON c.customer_id = o.customer_id
WHERE o.created_at > '$$LAST_RUN_DATE'::TIMESTAMP
  AND o.created_at <= LOCALTIMESTAMP - INTERVAL '1 day'
  AND o.status <> 'Cancelled'
ORDER BY o.order_id
LIMIT $$BATCH_SIZE
