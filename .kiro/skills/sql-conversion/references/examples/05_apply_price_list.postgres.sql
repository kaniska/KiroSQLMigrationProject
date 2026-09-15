-- Worked example 05 — PostgreSQL conversion of 05_apply_price_list.sqlserver.sql
-- Key decisions:
--   * A MERGE that only has MATCHED → UPDATE and NOT MATCHED → INSERT on a
--     column with a UNIQUE constraint → INSERT ... ON CONFLICT DO UPDATE.
--     Same rows, and unlike MERGE it is safe under concurrent inserts.
--     (Use MERGE when there are extra conditions, WHEN NOT MATCHED BY SOURCE,
--     or DELETE branches — see generated/customer_orders.sql
--     sync_product_catalog for a PG 17 MERGE ... RETURNING merge_action().)
--   * EXCLUDED.<col> is the proposed row, i.e. src.<col>.
--   * @@ROWCOUNT after the upsert → GET DIAGNOSTICS (inserted + updated).
--   * SELECT @@ROWCOUNT AS RowsAffected → RETURNS TABLE(rows_affected INTEGER).
--   * Duplicate SKUs in the source make both engines fail
--     ("cannot affect row a second time") — same behaviour.
CREATE OR REPLACE FUNCTION public.apply_price_list(
    p_effective_date  DATE
)
RETURNS TABLE(rows_affected INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows  INTEGER;
BEGIN
    INSERT INTO public.products AS tgt (sku, product_name, price, category_id, is_active, created_at)
    SELECT s.sku, s.product_name, s.price, s.category_id, TRUE, LOCALTIMESTAMP
    FROM   public.product_staging s
    WHERE  s.effective_date = p_effective_date
      AND  s.is_active = TRUE
    ON CONFLICT (sku) DO UPDATE
        SET product_name = EXCLUDED.product_name,
            price        = EXCLUDED.price,
            updated_at   = LOCALTIMESTAMP;

    GET DIAGNOSTICS v_rows = ROW_COUNT;                     -- @@ROWCOUNT

    RETURN QUERY SELECT v_rows;
END;
$$;

-- Usage:
-- SELECT * FROM public.apply_price_list('2026-10-01');
