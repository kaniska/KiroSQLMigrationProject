-- ============================================================
-- Converted from: examples/source_example.sql
-- Conversion date: 2026-09-10
-- Converter: sql-conversion skill v2
-- Target: Aurora PostgreSQL 17 (upsert_customer uses PG 17 MERGE ... RETURNING)
-- Schema: generated/schema.sql
-- Reference pair: read this side by side with examples/source_example.sql.
-- Notes:
--   USE [SalesDB], GO, SET NOCOUNT ON, WITH (NOLOCK) removed
--   dbo.PascalCase → public.snake_case; keys keep their names (OrderId → order_id)
--   @Param → p_param; locals → v_name
--   MONEY → NUMERIC(19,4); NVARCHAR → VARCHAR; DATETIME → TIMESTAMP(3);
--   DATETIME2 → TIMESTAMP; UNIQUEIDENTIFIER → UUID; BIT → BOOLEAN
--   GETDATE() → LOCALTIMESTAMP
--   SCOPE_IDENTITY() → INSERT ... RETURNING <alias>.<key> INTO v_...
--   RAISERROR(msg, 16, 1, args) → RAISE EXCEPTION 'msg %', args USING ERRCODE = 'P0001'
--   PRINT → RAISE NOTICE; @@ROWCOUNT → GET DIAGNOSTICS
--   Cursor → FOR loop; per-row TRY/CATCH → nested BEGIN ... EXCEPTION
--   #temp → TEMP TABLE IF NOT EXISTS + TRUNCATE
--   MERGE ... OUTPUT $action → MERGE ... RETURNING merge_action() (PG 17)
--   sp_executesql → RETURN QUERY EXECUTE ... USING; LIKE → ILIKE
--   TOP (n) → LIMIT n; OFFSET/FETCH → LIMIT/OFFSET
--   FORMAT(d, 'yyyy-MM-dd') → TO_CHAR(d, 'YYYY-MM-DD'); DATEDIFF(day) → date subtraction
-- ============================================================


-- ============================================================
-- 1. create_order
--    Converted from: usp_CreateOrder
--    NOTE: the T-SQL has no BEGIN TRAN, so if the OrderLines insert failed
--    the Orders row stayed committed. The PostgreSQL function is atomic
--    (both inserts roll back together) — a deliberate, safer difference.
-- ============================================================
-- TODO: MANUAL REVIEW REQUIRED — intentional difference: the function is atomic while the
--       T-SQL (no BEGIN TRAN) could leave an Orders row committed after a failed OrderLines insert
CREATE OR REPLACE FUNCTION public.create_order(
    p_customer_id  INTEGER,
    p_product_id   INTEGER,
    p_quantity     SMALLINT,
    p_notes        VARCHAR(500) DEFAULT NULL
)
RETURNS TABLE(order_id INTEGER, total_amount NUMERIC(19,4), created_at TIMESTAMP(3))
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_id    INTEGER;
    v_unit_price  NUMERIC(19,4);
    v_total_amt   NUMERIC(19,4);
    v_created_at  TIMESTAMP(3) := LOCALTIMESTAMP;   -- DATETIME = GETDATE()
BEGIN
    SELECT p.price
    INTO   v_unit_price
    FROM   public.products p
    WHERE  p.product_id = p_product_id
      AND  p.is_active  = TRUE;

    IF v_unit_price IS NULL THEN
        RAISE EXCEPTION 'Product % not found or inactive.', p_product_id
            USING ERRCODE = 'P0001';
    END IF;

    v_total_amt := v_unit_price * p_quantity;

    -- TRY/CATCH that only re-raises ERROR_MESSAGE() → no EXCEPTION block needed
    INSERT INTO public.orders AS o (customer_id, created_at, total_amount, notes, status)
    VALUES (p_customer_id, v_created_at, v_total_amt, p_notes, 'Pending')
    RETURNING o.order_id INTO v_order_id;             -- SCOPE_IDENTITY()

    INSERT INTO public.order_lines (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_unit_price);

    RETURN QUERY SELECT v_order_id, v_total_amt, v_created_at;
END;
$$;

-- Usage:
-- SELECT * FROM public.create_order(1, 1, 3::SMALLINT, 'Rush order');


-- ============================================================
-- 2. process_pending_orders
--    Converted from: usp_ProcessPendingOrders
--    PROCEDURE because it COMMITs: the T-SQL runs without BEGIN TRAN, so
--    every order's updates were committed as they happened. The COMMIT sits
--    OUTSIDE the per-order BEGIN ... EXCEPTION block — PostgreSQL rejects
--    COMMIT inside a block that has an exception handler.
--    Call it with CALL, outside an explicit transaction block.
-- ============================================================
CREATE OR REPLACE PROCEDURE public.process_pending_orders(
    p_batch_size      INTEGER   DEFAULT 100,
    p_processed_date  TIMESTAMP DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_processed_date  TIMESTAMP := COALESCE(p_processed_date, LOCALTIMESTAMP);
    v_row_count       INTEGER;
    v_rec             RECORD;
BEGIN
    -- #PendingBatch → session temp table; IF NOT EXISTS + TRUNCATE keeps it
    -- reusable (ON COMMIT DROP would drop it at the first COMMIT below)
    CREATE TEMP TABLE IF NOT EXISTS tmp_pending_batch (
        order_id      INTEGER       NOT NULL,
        customer_id   INTEGER       NOT NULL,
        total_amount  NUMERIC(19,4) NOT NULL,
        status        VARCHAR(50)   NOT NULL
    );
    TRUNCATE tmp_pending_batch;

    INSERT INTO tmp_pending_batch (order_id, customer_id, total_amount, status)
    SELECT o.order_id, o.customer_id, o.total_amount, o.status
    FROM   public.orders o
    WHERE  o.status = 'Pending'
    ORDER  BY o.order_id ASC
    LIMIT  p_batch_size;                               -- TOP (@BatchSize)

    GET DIAGNOSTICS v_row_count = ROW_COUNT;

    IF v_row_count = 0 THEN
        RAISE NOTICE 'No pending orders to process.';
        RETURN;
    END IF;

    FOR v_rec IN
        SELECT b.order_id, b.customer_id, b.total_amount
        FROM   tmp_pending_batch b
        ORDER  BY b.order_id
    LOOP
        BEGIN                                           -- BEGIN TRY
            UPDATE public.orders o
            SET    status     = 'Processing',
                   updated_at = v_processed_date
            WHERE  o.order_id = v_rec.order_id;

            IF v_rec.total_amount > 1000 THEN
                UPDATE public.orders o
                SET    requires_approval = TRUE
                WHERE  o.order_id = v_rec.order_id;
            END IF;

            UPDATE public.orders o
            SET    status       = 'Processed',
                   processed_at = v_processed_date
            WHERE  o.order_id = v_rec.order_id;
        EXCEPTION                                       -- BEGIN CATCH
            WHEN OTHERS THEN
                -- Log the failure and continue with the next order
                INSERT INTO public.processing_errors (order_id, error_message, occurred_at)
                VALUES (v_rec.order_id, SQLERRM, LOCALTIMESTAMP);
        END;

        COMMIT;   -- per-order commit, matching the source's autocommit behaviour
    END LOOP;
END;
$$;

-- Usage (top level, not inside BEGIN ... COMMIT):
-- CALL public.process_pending_orders(50);


-- ============================================================
-- 3. upsert_customer
--    Converted from: usp_UpsertCustomer
--    MERGE ... OUTPUT $action, INSERTED.* INTO @ResultTable
--      → PG 17 MERGE ... RETURNING merge_action(), tgt.*  (@ResultTable not needed)
--    PG 15/16 alternative:
--      INSERT ... ON CONFLICT (external_id) DO UPDATE ...
--      RETURNING CASE WHEN xmax = 0 THEN 'INSERT' ELSE 'UPDATE' END, customer_id, email
-- ============================================================
CREATE OR REPLACE FUNCTION public.upsert_customer(
    p_external_id  UUID,
    p_first_name   VARCHAR(100),
    p_last_name    VARCHAR(100),
    p_email        VARCHAR(255),
    p_phone        VARCHAR(20) DEFAULT NULL,
    p_birth_date   DATE        DEFAULT NULL
)
RETURNS TABLE(action VARCHAR(10), customer_id INTEGER, email VARCHAR(255))
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        WITH merged AS (
            MERGE INTO public.customers AS tgt
            USING (SELECT p_external_id AS external_id,
                          p_first_name  AS first_name,
                          p_last_name   AS last_name,
                          p_email       AS email,
                          p_phone       AS phone,
                          p_birth_date  AS birth_date) AS src
            ON tgt.external_id = src.external_id
            WHEN MATCHED THEN
                UPDATE SET first_name = src.first_name,
                           last_name  = src.last_name,
                           email      = src.email,
                           phone      = src.phone,
                           updated_at = LOCALTIMESTAMP
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (external_id, first_name, last_name, email, phone, birth_date, created_at)
                VALUES (src.external_id, src.first_name, src.last_name, src.email,
                        src.phone, src.birth_date, LOCALTIMESTAMP)
            RETURNING merge_action() AS merge_act, tgt.customer_id AS cust_id, tgt.email AS cust_email
        )
        SELECT m.merge_act::VARCHAR(10), m.cust_id, m.cust_email
        FROM   merged m;
END;
$$;

-- Usage:
-- SELECT * FROM public.upsert_customer(
--     'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Jane', 'Doe', 'jane@example.com',
--     '+1-555-0100', '1990-06-15');


-- ============================================================
-- 4. search_orders
--    Converted from: usp_SearchOrders
--    @ParamDef order is kept for the $n placeholders:
--      $1 DateFrom, $2 DateTo, $3 CustomerId, $4 Status,
--      $5 SearchText, $6 Offset, $7 PageSize
-- ============================================================
CREATE OR REPLACE FUNCTION public.search_orders(
    p_customer_id  INTEGER       DEFAULT NULL,
    p_status       VARCHAR(50)   DEFAULT NULL,
    p_date_from    TIMESTAMP(3)  DEFAULT NULL,
    p_date_to      TIMESTAMP(3)  DEFAULT NULL,
    p_search_text  VARCHAR(200)  DEFAULT NULL,
    p_page_number  INTEGER       DEFAULT 1,
    p_page_size    INTEGER       DEFAULT 20
)
RETURNS TABLE(
    order_id       INTEGER,
    customer_id    INTEGER,
    customer_name  TEXT,
    total_amount   NUMERIC(19,4),
    status         VARCHAR(50),
    order_date     TEXT,
    days_old       INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sql        TEXT;
    v_offset     INTEGER      := (p_page_number - 1) * p_page_size;
    v_date_from  TIMESTAMP(3) := COALESCE(p_date_from, LOCALTIMESTAMP - INTERVAL '3 months');
    v_date_to    TIMESTAMP(3) := COALESCE(p_date_to,   LOCALTIMESTAMP);
BEGIN
    v_sql := $q$
        SELECT o.order_id,
               o.customer_id,
               c.first_name || ' ' || c.last_name,
               o.total_amount,
               o.status,
               TO_CHAR(o.created_at, 'YYYY-MM-DD'),
               (CURRENT_DATE - o.created_at::DATE)
        FROM   public.orders    o
        JOIN   public.customers c ON c.customer_id = o.customer_id
        WHERE  o.created_at BETWEEN $1 AND $2
    $q$;

    IF p_customer_id IS NOT NULL THEN
        v_sql := v_sql || ' AND o.customer_id = $3';
    END IF;

    IF p_status IS NOT NULL THEN
        v_sql := v_sql || ' AND o.status = $4';
    END IF;

    IF p_search_text IS NOT NULL THEN
        v_sql := v_sql || $q$
            AND (c.first_name ILIKE '%' || $5 || '%'
              OR c.last_name  ILIKE '%' || $5 || '%'
              OR c.email      ILIKE '%' || $5 || '%')$q$;
    END IF;

    v_sql := v_sql || ' ORDER BY o.created_at DESC LIMIT $7 OFFSET $6';

    -- EXECUTE ... USING binds values as parameters (no string interpolation)
    RETURN QUERY EXECUTE v_sql
        USING v_date_from,     -- $1
              v_date_to,       -- $2
              p_customer_id,   -- $3
              p_status,        -- $4
              p_search_text,   -- $5
              v_offset,        -- $6
              p_page_size;     -- $7
END;
$$;

-- Usage:
-- SELECT * FROM public.search_orders(p_status => 'Pending', p_search_text => 'ali');
