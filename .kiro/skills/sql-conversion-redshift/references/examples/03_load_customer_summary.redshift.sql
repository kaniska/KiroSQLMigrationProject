-- Worked example 03 — Amazon Redshift PL/pgSQL procedure (atomic mode, result via INOUT refcursor)
-- Ledger: RS-44 OUTPUT → INOUT · RS-55 SELECT INTO #t → CREATE TEMP TABLE · RS-50 MERGE split (Redshift MERGE has one
--         WHEN MATCHED, no BY SOURCE, no AND) into DELETE/UPDATE/INSERT · RS-16 @@ROWCOUNT → GET DIAGNOSTICS
--         RS-41 BEGIN TRAN/COMMIT → implicit transaction of the CALL · RS-42 TRY/CATCH → EXCEPTION (no subtransactions) + RAISE
--         RS-46 RETURN code → p_return_code INOUT · RS-40 final SELECT → refcursor opened for the caller
CREATE OR REPLACE PROCEDURE sales.usp_load_customer_summary(
    p_as_of        DATE,
    INOUT p_rows_merged INTEGER,
    INOUT p_return_code INTEGER,
    INOUT p_result  refcursor)
LANGUAGE plpgsql
AS $$
DECLARE
    v_upd INTEGER := 0;
    v_ins INTEGER := 0;
    v_del INTEGER := 0;
BEGIN
    DROP TABLE IF EXISTS stage;
    CREATE TEMP TABLE stage AS
    SELECT c.customer_key, SUM(f.line_total) AS revenue, MAX(f.sale_date) AS last_sale
    FROM   sales.dim_customer c JOIN sales.fact_sales f ON f.customer_key = c.customer_key
    WHERE  f.sale_date <= p_as_of
    GROUP BY c.customer_key;

    -- WHEN NOT MATCHED BY SOURCE THEN DELETE
    DELETE FROM sales.customer_summary USING stage
    WHERE  sales.customer_summary.customer_key NOT IN (SELECT customer_key FROM stage);
    GET DIAGNOSTICS v_del := ROW_COUNT;

    -- WHEN MATCHED AND s.revenue <> t.revenue THEN UPDATE
    UPDATE sales.customer_summary
    SET    revenue = s.revenue, last_sale = s.last_sale, updated_at = GETDATE()
    FROM   stage s
    WHERE  sales.customer_summary.customer_key = s.customer_key
    AND    sales.customer_summary.revenue <> s.revenue;
    GET DIAGNOSTICS v_upd := ROW_COUNT;

    -- WHEN NOT MATCHED BY TARGET THEN INSERT
    INSERT INTO sales.customer_summary (customer_key, revenue, last_sale, updated_at)
    SELECT s.customer_key, s.revenue, s.last_sale, GETDATE()
    FROM   stage s
    WHERE  NOT EXISTS (SELECT 1 FROM sales.customer_summary t WHERE t.customer_key = s.customer_key);
    GET DIAGNOSTICS v_ins := ROW_COUNT;

    p_rows_merged := v_upd + v_ins + v_del;
    p_return_code := 0;

    OPEN p_result FOR
        SELECT customer_key, revenue FROM sales.customer_summary WHERE last_sale >= DATEADD(day, -7, p_as_of);
EXCEPTION
    WHEN OTHERS THEN
        p_return_code := 1;
        RAISE EXCEPTION 'usp_load_customer_summary failed: %', SQLERRM;  -- the CALL's implicit transaction rolls back
END;
$$;

-- Caller (inside a transaction so the cursor stays open):
-- BEGIN; CALL sales.usp_load_customer_summary(CURRENT_DATE, 0, 0, 'rs'); FETCH ALL FROM rs; COMMIT;
