-- Worked example 11 — PostgreSQL conversion of 11_customer_dashboard.sqlserver.sql
-- Key decisions:
--   * A PostgreSQL function returns ONE result set, so N result sets become N
--     functions: <base> for the first, <base>_<result_set> for the others
--     (hard rule H8). The @IncludeOrders flag disappears: the caller simply
--     calls the second function when it wants the orders.
--       EXEC usp_GetCustomerDashboard 1, 1   →   SELECT * FROM get_customer_dashboard(1);
--                                                SELECT * FROM get_customer_dashboard_orders(1);
--   * COUNT(*) is INT in SQL Server but BIGINT in PostgreSQL → cast so the
--     declared INTEGER column matches (hard rule H12).
--   * Pure reads → STABLE; single SELECT → LANGUAGE sql would also do.
CREATE OR REPLACE FUNCTION public.get_customer_dashboard(
    p_customer_id  INTEGER
)
RETURNS TABLE(customer_id INTEGER, customer_name TEXT, email VARCHAR(255), order_count INTEGER)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        SELECT c.customer_id,
               c.first_name || ' ' || c.last_name,
               c.email,
               (SELECT COUNT(*) FROM public.orders o WHERE o.customer_id = c.customer_id)::INTEGER
        FROM   public.customers c
        WHERE  c.customer_id = p_customer_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_customer_dashboard_orders(
    p_customer_id  INTEGER
)
RETURNS TABLE(order_id INTEGER, created_at TIMESTAMP, total_amount NUMERIC(19,4), status VARCHAR(50))
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        SELECT o.order_id, o.created_at, o.total_amount, o.status
        FROM   public.orders o
        WHERE  o.customer_id = p_customer_id
        ORDER  BY o.created_at DESC
        LIMIT  5;                                         -- TOP (5)
END;
$$;

-- Usage:
-- SELECT * FROM public.get_customer_dashboard(1);
-- SELECT * FROM public.get_customer_dashboard_orders(1);
