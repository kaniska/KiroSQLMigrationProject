SELECT p.product_id, SUM(ol.quantity) AS units_sold, SUM(ol.quantity * ol.unit_price) AS revenue,
       date_trunc('month', o.created_at) AS period_start
FROM public.order_lines ol
JOIN public.orders o ON o.order_id = ol.order_id
JOIN public.products p ON p.product_id = ol.product_id
JOIN tmp_active_products ap ON ap.product_id = p.product_id
JOIN public.inventory i ON i.product_id = p.product_id
JOIN public.warehouses w ON w.warehouse_id = i.warehouse_id AND w.warehouse_name = '$$REGION'
WHERE o.status IN ('Processed', 'Completed')
  AND o.created_at >= '$$PERIOD_START'::TIMESTAMP
GROUP BY p.product_id, date_trunc('month', o.created_at)
HAVING SUM(ol.quantity) >= $$MIN_UNITS
ORDER BY period_start, p.product_id
