-- Worked example 03 — PostgreSQL conversion of 03_generate_monthly_invoices.sqlserver.sql
-- Key decisions:
--   * No result set → PROCEDURE. BEGIN TRAN/COMMIT are dropped: PL/pgSQL
--     cannot start a transaction, and COMMIT is forbidden inside a block that
--     has an EXCEPTION handler. The CALL is atomic instead.
--   * The CATCH block ADDS text to the message, so an EXCEPTION block is
--     justified here (a CATCH that only rolls back + re-raises needs none).
--     The handler's implicit rollback undoes the inserts, like ROLLBACK did.
--   * #Uninvoiced → TEMP TABLE IF NOT EXISTS + TRUNCATE (temp tables live for
--     the whole session in PostgreSQL; the source's DROP TABLE is not needed).
--   * @@ROWCOUNT → GET DIAGNOSTICS immediately after the INSERT.
--   * OUTPUT ... INTO @NewInvoices + UPDATE ... FROM → one statement: a
--     data-modifying CTE feeding UPDATE ... FROM.
--   * MONTH()/YEAR() equality → DATE_TRUNC('month') equality (same rows).
--   * RAISERROR('...%s', 16, 1, @Err) → RAISE EXCEPTION '...%', SQLERRM.
CREATE OR REPLACE PROCEDURE public.generate_monthly_invoices(
    p_billing_month  DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_row_count  INTEGER;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS tmp_uninvoiced (
        customer_id  INTEGER,
        order_id     INTEGER,
        amount       NUMERIC(19,4)
    );
    TRUNCATE tmp_uninvoiced;

    INSERT INTO tmp_uninvoiced (customer_id, order_id, amount)
    SELECT o.customer_id, o.order_id, o.total_amount
    FROM   public.orders o
    -- ::TIMESTAMP: DATE_TRUNC(text, date) would pick the timestamptz overload
    WHERE  DATE_TRUNC('month', o.created_at) = DATE_TRUNC('month', p_billing_month::TIMESTAMP)
      AND  o.invoice_id IS NULL;

    GET DIAGNOSTICS v_row_count = ROW_COUNT;               -- @@ROWCOUNT

    IF v_row_count = 0 THEN
        RAISE NOTICE 'No uninvoiced orders for this period.';   -- PRINT
        RETURN;
    END IF;

    BEGIN
        WITH new_invoices AS (
            INSERT INTO public.invoices AS i (customer_id, period_start, total_amount, created_at)
            SELECT u.customer_id, p_billing_month, SUM(u.amount), LOCALTIMESTAMP
            FROM   tmp_uninvoiced u
            GROUP  BY u.customer_id
            RETURNING i.invoice_id, i.customer_id           -- OUTPUT INSERTED.* INTO @NewInvoices
        )
        UPDATE public.orders o
        SET    invoice_id = ni.invoice_id
        FROM   tmp_uninvoiced u
        JOIN   new_invoices   ni ON ni.customer_id = u.customer_id
        WHERE  u.order_id = o.order_id;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Invoice generation failed: %', SQLERRM
                USING ERRCODE = SQLSTATE;
    END;
END;
$$;

-- Usage:
-- CALL public.generate_monthly_invoices('2025-06-01');
