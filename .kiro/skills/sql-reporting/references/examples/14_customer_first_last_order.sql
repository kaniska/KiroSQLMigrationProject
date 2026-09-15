-- Pattern RP-14 — First and last row per group (DISTINCT ON)
-- Rules applied: RQ-16 (ORDER BY … , order_id as the tie-breaker: two orders at the
--                same instant would otherwise pick either one), RQ-14
CREATE OR REPLACE FUNCTION public.report_customer_first_last_order()
RETURNS TABLE(customer_id INTEGER, first_order_at TIMESTAMP, first_amount NUMERIC(19,4),
              last_order_at TIMESTAMP, last_amount NUMERIC(19,4))
LANGUAGE sql STABLE
AS $$
    WITH revenue_orders AS (
        SELECT o.order_id, o.customer_id, o.created_at, o.total_amount
        FROM   public.orders o
        WHERE  o.status NOT IN ('Cancelled', 'Refunded')
    ),
    first_orders AS (
        SELECT DISTINCT ON (r.customer_id) r.customer_id, r.created_at, r.total_amount
        FROM   revenue_orders r ORDER BY r.customer_id, r.created_at, r.order_id
    ),
    last_orders AS (
        SELECT DISTINCT ON (r.customer_id) r.customer_id, r.created_at, r.total_amount
        FROM   revenue_orders r ORDER BY r.customer_id, r.created_at DESC, r.order_id DESC
    )
    SELECT f.customer_id, f.created_at, f.total_amount, l.created_at, l.total_amount
    FROM   first_orders f
    JOIN   last_orders  l ON l.customer_id = f.customer_id
    ORDER  BY f.customer_id;
$$;
-- SELECT * FROM public.report_customer_first_last_order();
