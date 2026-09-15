-- Kundenübersicht / résumé client: one row per customer with orders up to $$AS_OF_DATE
-- Converted: WITH (NOLOCK) removed, [Status] unbracketed, N'' dropped (IC-23, IC-20, IC-30);
-- CONVERT(DATE, '$$AS_OF_DATE', 112) → '$$AS_OF_DATE'::DATE (yyyymmdd parses as ISO, IC-26);
-- DATEDIFF(DAY, ts, d) counts day boundaries → (d - ts::DATE), not an interval (CC date rules);
-- LTRIM(RTRIM()) + ISNULL → TRIM() || COALESCE(); OUTER APPLY → LEFT JOIN LATERAL … ON TRUE;
-- STRING_AGG(…) WITHIN GROUP (ORDER BY …) → string_agg(… ORDER BY …). Seven columns, same order (IC-04).
WITH ranked AS (
    SELECT o.customer_id, o.order_id, o.created_at, o.total_amount,
           ROW_NUMBER() OVER (PARTITION BY o.customer_id ORDER BY o.created_at DESC, o.order_id DESC) AS rn
    FROM public.orders o
    WHERE o.status <> 'Cancelled'
      AND o.created_at < '$$AS_OF_DATE'::DATE + 1
), totals AS (
    SELECT r.customer_id,
           COUNT(*)::INTEGER AS order_count,
           CAST(SUM(r.total_amount) AS NUMERIC(19,4)) AS lifetime_amount,
           MAX(CASE WHEN r.rn = 1 THEN r.total_amount END) AS last_order_amount,
           MAX(r.created_at) AS last_order_at
    FROM ranked r
    GROUP BY r.customer_id
)
SELECT c.customer_id,
       TRIM(c.first_name) || ' ' || COALESCE(c.last_name, '') AS customer_name,
       t.order_count,
       t.lifetime_amount,
       t.last_order_amount,
       ('$$AS_OF_DATE'::DATE - t.last_order_at::DATE) AS days_since_last_order,
       COALESCE(sk.skus, '') AS purchased_skus
FROM totals t
JOIN public.customers c ON c.customer_id = t.customer_id
LEFT JOIN LATERAL (
    SELECT string_agg(d.sku, ',' ORDER BY d.sku) AS skus
    FROM (SELECT DISTINCT p.sku
          FROM public.order_lines ol
          JOIN public.orders o2 ON o2.order_id = ol.order_id
          JOIN public.products p ON p.product_id = ol.product_id
          WHERE o2.customer_id = c.customer_id
            AND o2.status <> 'Cancelled'
            AND o2.created_at < '$$AS_OF_DATE'::DATE + 1) d
) sk ON TRUE
ORDER BY c.customer_id
