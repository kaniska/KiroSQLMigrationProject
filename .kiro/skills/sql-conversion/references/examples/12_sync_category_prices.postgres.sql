-- Worked example 12 — PostgreSQL conversion of 12_sync_category_prices.sqlserver.sql
-- Requires PostgreSQL 17 (WHEN NOT MATCHED BY SOURCE, RETURNING merge_action(),
-- MERGE inside WITH).
-- Key decisions:
--   * MERGE maps almost 1:1 in PG 17. Keep the WHEN clause order: the first
--     matching clause wins in both engines.
--   * OUTPUT $action → RETURNING merge_action(). A NOT MATCHED BY SOURCE →
--     UPDATE row reports 'UPDATE' in both engines [CC-77].
--   * OUTPUT … INTO @Changes + SELECT FROM @Changes → MERGE inside a CTE,
--     then the final SELECT (no table variable needed).
--   * SET column names in MERGE are never qualified; everything else is
--     (tgt./src.) because RETURNS TABLE names are variables (H11).
--   * PG 15/16 fallback: three statements (INSERT … WHERE NOT EXISTS,
--     UPDATE … FROM, UPDATE … WHERE NOT EXISTS), each with RETURNING.
CREATE OR REPLACE FUNCTION public.sync_category_prices(
    p_category_id     INTEGER,
    p_effective_date  DATE
)
RETURNS TABLE(action VARCHAR(10), product_id INTEGER, sku VARCHAR(50))
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        WITH changes AS (
            MERGE INTO public.products AS tgt
            USING (
                SELECT s.sku, s.product_name, s.price, s.category_id
                FROM   public.product_staging s
                WHERE  s.category_id    = p_category_id
                  AND  s.effective_date = p_effective_date
            ) AS src
            ON tgt.sku = src.sku
            WHEN MATCHED AND tgt.price <> src.price THEN
                UPDATE SET price = src.price, updated_at = LOCALTIMESTAMP
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (sku, product_name, price, category_id, is_active, created_at)
                VALUES (src.sku, src.product_name, src.price, src.category_id, TRUE, LOCALTIMESTAMP)
            WHEN NOT MATCHED BY SOURCE AND tgt.category_id = p_category_id AND tgt.is_active THEN
                UPDATE SET is_active = FALSE, updated_at = LOCALTIMESTAMP
            RETURNING merge_action() AS act, tgt.product_id AS pid, tgt.sku AS psku
        )
        SELECT c.act::VARCHAR(10), c.pid, c.psku
        FROM   changes c
        ORDER  BY c.psku;
END;
$$;

-- Usage:
-- SELECT * FROM public.sync_category_prices(1, '2026-11-01');
