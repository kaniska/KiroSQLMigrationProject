-- Worked example 15 — PostgreSQL conversion of 15_order_stats.sqlserver.sql
-- Key decisions:
--   * T-SQL OUTPUT parameters are really input/output → PROCEDURE with INOUT
--     parameters. An early RETURN leaves them as the caller passed them, in
--     both engines.
--   * The RETURN status code has no PROCEDURE equivalent → an extra trailing
--     INOUT parameter p_return_code (flag it for the callers).
--   * INOUT parameters after the first defaulted one need defaults too, so all
--     outputs get DEFAULT NULL. CALL returns them as one row:
--       CALL public.get_order_stats(1, NULL, NULL, NULL, NULL);
--     From PL/pgSQL pass variables and they are assigned back (see Caller).
--   * SELECT @a = COUNT(*), @b = … → SELECT … INTO p_a, p_b (an aggregate
--     always returns a row, so no-row semantics do not matter here).
--   * MONEY / INT → assignment to NUMERIC(19,4) rounds to 4 places, like MONEY.
--   * Alternative when callers use SELECT: a FUNCTION with OUT parameters.
CREATE OR REPLACE PROCEDURE public.get_order_stats(
    p_customer_id         INTEGER,
    INOUT p_order_count   INTEGER       DEFAULT NULL,
    INOUT p_total_spent   NUMERIC(19,4) DEFAULT NULL,
    INOUT p_avg_order     NUMERIC(19,4) DEFAULT NULL,
    INOUT p_return_code   INTEGER       DEFAULT NULL    -- replaces RETURN n
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.customer_id = p_customer_id) THEN
        p_return_code := 1;                               -- RETURN 1
        RETURN;
    END IF;

    SELECT COUNT(*), COALESCE(SUM(o.total_amount), 0)
    INTO   p_order_count, p_total_spent
    FROM   public.orders o
    WHERE  o.customer_id = p_customer_id AND o.status <> 'Cancelled';

    p_avg_order := CASE WHEN p_order_count = 0 THEN NULL
                        ELSE p_total_spent / p_order_count END;
    p_return_code := 0;                                   -- RETURN 0
END;
$$;

-- Caller (PL/pgSQL) — the EXEC @rc = … OUTPUT pattern:
-- DO $$
-- DECLARE v_rc INTEGER; v_n INTEGER; v_total NUMERIC(19,4); v_avg NUMERIC(19,4);
-- BEGIN
--     CALL public.get_order_stats(1, v_n, v_total, v_avg, v_rc);
--     RAISE NOTICE 'rc=% n=% total=% avg=%', v_rc, v_n, v_total, v_avg;
-- END $$;
