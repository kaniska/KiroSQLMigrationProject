-- Worked example 06 — PostgreSQL conversion of 06_bulk_update_prices.sqlserver.sql
-- Key decisions:
--   * RETURNING only sees NEW values in PG 17 (OLD/NEW in RETURNING is PG 18).
--     DELETED.<col> → lock the target rows in a CTE first (SELECT ... FOR
--     UPDATE), then UPDATE ... FROM that CTE and RETURN its column. The lock
--     makes the captured value the one actually overwritten, even with
--     concurrent writers.
--   * OUTPUT INTO @AuditLog + INSERT ... SELECT FROM @AuditLog → one
--     statement: UPDATE ... RETURNING inside a CTE feeding the INSERT.
--   * SELECT COUNT(*) FROM @AuditLog → GET DIAGNOSTICS on the INSERT.
--   * MONEY arithmetic: the NUMERIC(19,4) column rounds on assignment, as
--     MONEY did. INT result → INTEGER (COUNT would be BIGINT).
CREATE OR REPLACE FUNCTION public.bulk_update_prices(
    p_pct_change   NUMERIC(5,2),
    p_category_id  INTEGER
)
RETURNS TABLE(products_updated INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count  INTEGER;
BEGIN
    WITH old AS (
        SELECT p.product_id, p.price
        FROM   public.products p
        WHERE  p.category_id = p_category_id
          AND  p.is_active   = TRUE
        FOR UPDATE
    ),
    upd AS (
        UPDATE public.products p
        SET    price      = p.price * (1 + p_pct_change / 100.0),
               updated_at = LOCALTIMESTAMP
        FROM   old
        WHERE  p.product_id = old.product_id
        RETURNING p.product_id,
                  old.price  AS old_price,                  -- DELETED.Price
                  p.price    AS new_price                   -- INSERTED.Price
    )
    INSERT INTO public.price_audit (product_id, old_price, new_price, changed_at)
    SELECT u.product_id, u.old_price, u.new_price, LOCALTIMESTAMP
    FROM   upd u;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN QUERY SELECT v_count;
END;
$$;

-- Usage:
-- SELECT * FROM public.bulk_update_prices(10.00, 2);
