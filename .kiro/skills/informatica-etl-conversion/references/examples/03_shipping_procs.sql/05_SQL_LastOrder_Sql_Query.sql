SELECT o.order_id, o.total_amount
FROM public.orders o
WHERE o.customer_id = ?CustomerId? AND o.status <> 'Cancelled'
ORDER BY o.created_at DESC
LIMIT 1
