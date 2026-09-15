SELECT p.product_id, SUM(ol.quantity) AS units_sold, SUM(ol.quantity * ol.unit_price) AS revenue,
       date_trunc('month', o.created_at) AS period_start
FROM public.order_lines ol
JOIN public.orders o ON o.order_id = ol.order_id
JOIN public.products p ON p.product_id = ol.product_id
WHERE o.status IN ('Processed', 'Completed')
  AND p.product_name <> 'Smith & Sons Special'
  AND o.created_at >= '$$PERIOD_START'::TIMESTAMP
GROUP BY p.product_id, date_trunc('month', o.created_at)
ORDER BY period_start, p.product_id
