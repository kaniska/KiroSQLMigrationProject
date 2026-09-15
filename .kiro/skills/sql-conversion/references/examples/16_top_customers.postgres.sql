-- Worked example 16 — PostgreSQL conversion of 16_top_customers.sqlserver.sql
-- Key decisions:
--   * An inline table-valued function (a single SELECT) → LANGUAGE sql
--     function (hard rule H7). The planner can inline it into the caller's
--     query just as SQL Server inlines an iTVF. Callers keep
--     SELECT * FROM f(…).
--   * In a LANGUAGE sql body, RETURNS TABLE column names are not variables,
--     so there is no name-clash risk. Parameters are referenced by name.
--   * TOP (@n) WITH TIES … ORDER BY → ORDER BY … FETCH FIRST (n) ROWS WITH TIES
--     (PG 13+) [CC-40]. LIMIT has no WITH TIES.
--   * COUNT → ::INTEGER (SQL Server INT); SUM(money) → NUMERIC.
CREATE OR REPLACE FUNCTION public.top_customers(
    p_min_orders  INTEGER,
    p_top_n       INTEGER
)
RETURNS TABLE(customer_id INTEGER, customer_name TEXT, order_count INTEGER, total_spent NUMERIC(19,4))
LANGUAGE sql
STABLE
AS $$
    SELECT c.customer_id,
           c.first_name || ' ' || c.last_name,
           COUNT(o.order_id)::INTEGER,
           SUM(o.total_amount)
    FROM   public.customers c
    JOIN   public.orders    o ON o.customer_id = c.customer_id
    WHERE  o.status <> 'Cancelled'
    GROUP  BY c.customer_id, c.first_name, c.last_name
    HAVING COUNT(o.order_id) >= p_min_orders
    ORDER  BY COUNT(o.order_id) DESC
    FETCH  FIRST (p_top_n) ROWS WITH TIES;
$$;

-- Usage:
-- SELECT * FROM public.top_customers(1, 3);
