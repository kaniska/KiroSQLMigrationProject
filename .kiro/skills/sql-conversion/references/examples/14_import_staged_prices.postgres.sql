-- Worked example 14 — PostgreSQL conversion of 14_import_staged_prices.sqlserver.sql
-- Key decisions:
--   * The source relies on per-statement autocommit: good rows and error-log
--     rows survive even though the procedure finally raises. A PostgreSQL
--     FUNCTION is atomic — its final RAISE would roll back the log too [CC-65].
--     So: PROCEDURE + COMMIT after every row (H9).
--   * COMMIT must sit OUTSIDE the per-row BEGIN … EXCEPTION block —
--     PostgreSQL rejects COMMIT inside a block with an exception handler.
--   * The final RAISE runs after the last COMMIT, so the caller gets the error
--     while the log rows stay committed — the log-then-rethrow pattern.
--   * THROW inside TRY → RAISE EXCEPTION inside the inner block (caught by its
--     own handler). @@ROWCOUNT = 0 → IF NOT FOUND. CONCAT keeps its
--     NULL-ignoring behaviour, so it maps 1:1 (only `+` becomes `||`, H15).
--   * The cursor loop over a query that COMMITs is fine: PL/pgSQL converts
--     it to a holdable cursor at the first COMMIT.
--   * Must be CALLed at top level (not inside BEGIN … COMMIT, not from a
--     function, not from a DO block that has an EXCEPTION clause).
CREATE OR REPLACE PROCEDURE public.import_staged_prices(
    p_effective_date  DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_row     RECORD;
    v_failed  INTEGER := 0;
BEGIN
    FOR v_row IN
        SELECT s.staging_id, s.sku, s.price
        FROM   public.product_staging s
        WHERE  s.effective_date = p_effective_date
        ORDER  BY s.staging_id
    LOOP
        BEGIN                                               -- BEGIN TRY
            IF v_row.price <= 0 THEN
                RAISE EXCEPTION 'Price must be positive'
                    USING ERRCODE = 'P0001', DETAIL = 'SQL Server error 50010';
            END IF;

            UPDATE public.products p
            SET    price = v_row.price, updated_at = LOCALTIMESTAMP
            WHERE  p.sku = v_row.sku;

            IF NOT FOUND THEN                               -- @@ROWCOUNT = 0
                RAISE EXCEPTION 'Unknown SKU'
                    USING ERRCODE = 'P0001', DETAIL = 'SQL Server error 50011';
            END IF;
        EXCEPTION                                           -- BEGIN CATCH
            WHEN OTHERS THEN
                v_failed := v_failed + 1;
                INSERT INTO public.processing_errors (order_id, error_message, occurred_at)
                VALUES (NULL, CONCAT(v_row.sku, ': ', SQLERRM), LOCALTIMESTAMP);
        END;

        COMMIT;   -- reproduce per-statement autocommit (outside the EXCEPTION block)
    END LOOP;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'Some staged prices failed; see ProcessingErrors.'
            USING ERRCODE = 'P0001', DETAIL = 'SQL Server error 50012';
    END IF;
END;
$$;

-- Usage (top level only):
-- CALL public.import_staged_prices('2026-12-01');
