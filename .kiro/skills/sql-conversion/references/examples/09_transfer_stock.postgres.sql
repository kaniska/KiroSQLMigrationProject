-- Worked example 09 — PostgreSQL conversion of 09_transfer_stock.sqlserver.sql
-- Key decisions:
--   * SET XACT_ABORT ON, BEGIN TRAN/COMMIT and a CATCH that only does
--     ROLLBACK + THROW → no transaction statements and no EXCEPTION block.
--     Any error aborts the call and rolls back everything, and the caller sees
--     the original error (what the bare THROW re-raised).
--   * THROW 50001, msg, 1 → RAISE EXCEPTION msg USING ERRCODE = 'P0001';
--     the SQL Server error number travels in DETAIL for callers that log it.
--   * UPDATE ...; IF @@ROWCOUNT = 0 INSERT ... → INSERT ... ON CONFLICT DO
--     UPDATE (atomic, no race). ON CONFLICT ON CONSTRAINT pk_inventory avoids
--     naming columns — the robust form whenever a RETURNS TABLE/OUT column
--     shares a name with a conflict column.
--   * The first UPDATE's @@ROWCOUNT check → IF NOT FOUND.
--   * OUTPUT INSERTED.TransferId INTO @Affected + final SELECT →
--     RETURNING ... INTO v_transfer_id + RETURN QUERY.
--   * SYSDATETIME() → clock_timestamp().
CREATE OR REPLACE FUNCTION public.transfer_stock(
    p_from_warehouse_id  INTEGER,
    p_to_warehouse_id    INTEGER,
    p_product_id         INTEGER,
    p_quantity           INTEGER,
    p_transferred_by     VARCHAR(100)
)
RETURNS TABLE(transfer_id INTEGER, status VARCHAR(20))
LANGUAGE plpgsql
AS $$
DECLARE
    v_transfer_id  INTEGER;
BEGIN
    UPDATE public.inventory i
    SET    quantity_on_hand = i.quantity_on_hand - p_quantity,
           last_updated     = clock_timestamp()
    WHERE  i.warehouse_id = p_from_warehouse_id
      AND  i.product_id   = p_product_id
      AND  i.quantity_on_hand >= p_quantity;

    IF NOT FOUND THEN                                         -- @@ROWCOUNT = 0
        RAISE EXCEPTION 'Insufficient stock or invalid warehouse/product.'
            USING ERRCODE = 'P0001',
                  DETAIL  = 'SQL Server error 50001';
    END IF;

    INSERT INTO public.inventory AS i (product_id, warehouse_id, quantity_on_hand, last_updated)
    VALUES (p_product_id, p_to_warehouse_id, p_quantity, clock_timestamp())
    ON CONFLICT ON CONSTRAINT pk_inventory DO UPDATE
        SET quantity_on_hand = i.quantity_on_hand + EXCLUDED.quantity_on_hand,
            last_updated     = EXCLUDED.last_updated;

    INSERT INTO public.stock_transfers AS st
        (from_warehouse_id, to_warehouse_id, product_id, quantity, transferred_by, transferred_at)
    VALUES
        (p_from_warehouse_id, p_to_warehouse_id, p_product_id, p_quantity,
         p_transferred_by, clock_timestamp())
    RETURNING st.transfer_id INTO v_transfer_id;            -- OUTPUT INSERTED.TransferId

    RETURN QUERY SELECT v_transfer_id, 'OK'::VARCHAR(20);
END;
$$;

-- Usage:
-- SELECT * FROM public.transfer_stock(1, 2, 1, 5, 'jsmith');
