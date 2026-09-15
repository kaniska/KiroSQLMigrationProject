-- Worked example 02 — PostgreSQL conversion of 02_recalc_order_totals.sqlserver.sql
-- Key decisions:
--   * No result set → PROCEDURE (CALL mirrors EXEC). No COMMIT: the whole
--     CALL is atomic, which only differs from SQL Server's per-statement
--     autocommit if the proc fails half-way (then nothing is kept).
--   * Cursor + FETCH/@@FETCH_STATUS loop → FOR rec IN <query> LOOP.
--     (Set-based UPDATE ... FROM (SELECT ... GROUP BY) would be faster; the
--     loop is kept to show the mechanical mapping.)
--   * An aggregate always returns one row, so SELECT ... INTO behaves like the
--     T-SQL assignment here (NULL when no lines) and COALESCE replaces ISNULL.
--   * DATETIME parameters → TIMESTAMP(3).
CREATE OR REPLACE PROCEDURE public.recalc_order_totals(
    p_start_date  TIMESTAMP(3),
    p_end_date    TIMESTAMP(3)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec        RECORD;
    v_new_total  NUMERIC(19,4);
BEGIN
    FOR v_rec IN
        SELECT o.order_id
        FROM   public.orders o
        WHERE  o.created_at BETWEEN p_start_date AND p_end_date
    LOOP
        SELECT SUM(ol.quantity * ol.unit_price)
        INTO   v_new_total
        FROM   public.order_lines ol
        WHERE  ol.order_id = v_rec.order_id;

        UPDATE public.orders o
        SET    total_amount = COALESCE(v_new_total, 0)
        WHERE  o.order_id = v_rec.order_id;
    END LOOP;
END;
$$;

-- Usage:
-- CALL public.recalc_order_totals('2024-03-01', '2024-03-31 23:59:59');
