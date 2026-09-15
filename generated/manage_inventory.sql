-- ============================================================
-- Converted from: source/usp_ManageInventory.sql
-- Conversion date: 2026-09-10
-- Converter: sql-conversion skill v2
-- Target: Aurora PostgreSQL 17 (PostgreSQL 15+ compatible)
-- Schema: generated/schema.sql
-- Notes:
--   USE [InventoryDB], GO, SET NOCOUNT ON removed
--   WITH (NOLOCK) removed; WITH (UPDLOCK, ROWLOCK) → SELECT ... FOR UPDATE
--   Procs that end with a SELECT → FUNCTION ... RETURNS TABLE
--   BEGIN TRAN / COMMIT / TRY-CATCH(ROLLBACK + re-raise) → no explicit
--     transaction control: the function runs inside the caller's
--     transaction and any exception rolls all of its work back
--   SCOPE_IDENTITY() → RETURNING audit_id INTO ...
--   GETDATE() → LOCALTIMESTAMP; SYSDATETIME() → clock_timestamp()::TIMESTAMP
--   ISNULL → COALESCE; DATEDIFF(day, a, b) → b::DATE - a::DATE
--   CONVERT(VARCHAR, dt, 101) → TO_CHAR(dt, 'MM/DD/YYYY')
--   Table variable read once after an @@ROWCOUNT check → RETURN QUERY + IF NOT FOUND
--   #ReorderQueue → TEMP TABLE IF NOT EXISTS + TRUNCATE (idempotent per session)
--   OUTPUT INSERTED.* INTO @table → INSERT ... RETURNING inside a CTE
--   TOP (n) ... ORDER BY → ORDER BY ... LIMIT n
--   ORDER BY on nullable columns: NULLS LAST on DESC to match SQL Server
--     (SQL Server sorts NULL lowest; PostgreSQL sorts NULL highest)
-- ============================================================


-- ============================================================
-- 1. adjust_stock
--    Converted from: usp_AdjustStock
--    Returns the T-SQL result set (AdjustmentId, PreviousStock, NewStock).
--    FUNCTION, not PROCEDURE: the proc needs no mid-body COMMIT, and a
--    PROCEDURE may not COMMIT/ROLLBACK inside a block that has an
--    EXCEPTION handler anyway.
-- ============================================================
CREATE OR REPLACE FUNCTION public.adjust_stock(
    p_product_id    INTEGER,
    p_warehouse_id  INTEGER,
    p_quantity      INTEGER,        -- positive = add, negative = remove
    p_reason        VARCHAR(200),
    p_adjusted_by   VARCHAR(100)
)
RETURNS TABLE(adjustment_id INTEGER, previous_stock INTEGER, new_stock INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_stock  INTEGER;
    v_new_stock      INTEGER;
    v_adjustment_id  INTEGER;
    v_adjusted_at    TIMESTAMP := clock_timestamp();   -- SYSDATETIME()
BEGIN
    -- WITH (UPDLOCK, ROWLOCK) → FOR UPDATE row lock
    SELECT i.quantity_on_hand
    INTO   v_current_stock
    FROM   public.inventory i
    WHERE  i.product_id   = p_product_id
      AND  i.warehouse_id = p_warehouse_id
    FOR UPDATE;

    IF v_current_stock IS NULL THEN
        -- Initialise the inventory row if it does not exist
        INSERT INTO public.inventory (product_id, warehouse_id, quantity_on_hand, last_updated)
        VALUES (p_product_id, p_warehouse_id, 0, v_adjusted_at);
        v_current_stock := 0;
    END IF;

    v_new_stock := v_current_stock + p_quantity;

    IF v_new_stock < 0 THEN
        -- RAISERROR sev 16 inside TRY → CATCH → ROLLBACK + re-raise.
        -- RAISE EXCEPTION aborts and rolls back everything this call did.
        RAISE EXCEPTION 'Insufficient stock. Current: %, Requested: %',
            v_current_stock, ABS(p_quantity)
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.inventory i
    SET    quantity_on_hand = v_new_stock,
           last_updated     = v_adjusted_at
    WHERE  i.product_id   = p_product_id
      AND  i.warehouse_id = p_warehouse_id;

    -- Audit log; SCOPE_IDENTITY() → RETURNING
    INSERT INTO public.inventory_audit AS a
        (product_id, warehouse_id, previous_qty, adjustment, new_qty,
         reason, adjusted_by, adjusted_at)
    VALUES
        (p_product_id, p_warehouse_id, v_current_stock, p_quantity, v_new_stock,
         p_reason, p_adjusted_by, v_adjusted_at)
    RETURNING a.audit_id INTO v_adjustment_id;

    RETURN QUERY SELECT v_adjustment_id, v_current_stock, v_new_stock;
END;
$$;

-- Usage:
-- SELECT * FROM public.adjust_stock(1, 1, -5, 'Sold at counter', 'jsmith');


-- ============================================================
-- 2. get_low_stock_alerts
--    Converted from: usp_GetLowStockAlerts
--    The @Alerts table variable only existed to test @@ROWCOUNT before
--    returning it, so it becomes RETURN QUERY + IF NOT FOUND (same
--    observable result: empty set + message). No temp table → STABLE.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_low_stock_alerts(
    p_reorder_threshold  INTEGER DEFAULT 10,
    p_warehouse_id       INTEGER DEFAULT NULL
)
RETURNS TABLE(
    product_id                INTEGER,
    product_name              VARCHAR(200),
    sku                       VARCHAR(50),
    warehouse_id              INTEGER,
    warehouse_name            VARCHAR(100),
    current_stock             INTEGER,
    reorder_point             INTEGER,
    shortfall_qty             INTEGER,
    last_restocked_formatted  TEXT,
    days_since_restock        INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        SELECT
            p.product_id,
            p.product_name,
            p.sku,
            w.warehouse_id,
            w.warehouse_name,
            i.quantity_on_hand                                        AS current_stock,
            COALESCE(p.reorder_point, p_reorder_threshold)            AS reorder_point,
            COALESCE(p.reorder_point, p_reorder_threshold)
                - i.quantity_on_hand                                  AS shortfall_qty,
            TO_CHAR(i.last_restocked, 'MM/DD/YYYY')                   AS last_restocked_formatted,
            (CURRENT_DATE - i.last_restocked::DATE)                   AS days_since_restock
        FROM   public.inventory   i
        JOIN   public.products    p ON p.product_id   = i.product_id
        JOIN   public.warehouses  w ON w.warehouse_id = i.warehouse_id
        WHERE  i.quantity_on_hand <= COALESCE(p.reorder_point, p_reorder_threshold)
          AND  p.is_active = TRUE
          AND  (p_warehouse_id IS NULL OR i.warehouse_id = p_warehouse_id)
        ORDER  BY 8 DESC NULLS LAST,      -- shortfall_qty
                  10 DESC NULLS LAST;     -- days_since_restock

    IF NOT FOUND THEN
        RAISE NOTICE 'No low-stock alerts found.';   -- PRINT
    END IF;
END;
$$;

-- Usage:
-- SELECT * FROM public.get_low_stock_alerts();
-- SELECT * FROM public.get_low_stock_alerts(p_warehouse_id => 2);


-- ============================================================
-- 3. process_reorders
--    Converted from: usp_ProcessReorders
--    #ReorderQueue → TEMP TABLE (read twice: INSERT source + final join)
--    OUTPUT INSERTED.* INTO @CreatedOrders → INSERT ... RETURNING in a CTE
-- ============================================================
CREATE OR REPLACE FUNCTION public.process_reorders(
    p_created_by  VARCHAR(100),
    p_max_orders  INTEGER DEFAULT 50
)
RETURNS TABLE(
    purchase_order_id  INTEGER,
    product_id         INTEGER,
    product_name       VARCHAR(200),
    reorder_qty        INTEGER,
    current_stock      INTEGER
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- IF NOT EXISTS + TRUNCATE: a temp table outlives the call in PostgreSQL
    CREATE TEMP TABLE IF NOT EXISTS tmp_reorder_queue (
        product_id    INTEGER,
        warehouse_id  INTEGER,
        current_stock INTEGER,
        reorder_qty   INTEGER
    );
    TRUNCATE tmp_reorder_queue;

    INSERT INTO tmp_reorder_queue (product_id, warehouse_id, current_stock, reorder_qty)
    SELECT i.product_id,
           i.warehouse_id,
           i.quantity_on_hand,
           p.reorder_quantity
    FROM   public.inventory i
    JOIN   public.products  p ON p.product_id = i.product_id
    WHERE  i.quantity_on_hand <= COALESCE(p.reorder_point, 10)
      AND  p.is_active = TRUE
      AND  NOT EXISTS (
               SELECT 1
               FROM   public.purchase_orders po
               WHERE  po.product_id   = i.product_id
                 AND  po.warehouse_id = i.warehouse_id
                 AND  po.status IN ('Draft', 'Submitted', 'InTransit')
           )
    ORDER  BY i.quantity_on_hand ASC
    LIMIT  p_max_orders;                       -- TOP (@MaxOrders)

    RETURN QUERY
        WITH created_orders AS (
            INSERT INTO public.purchase_orders AS po
                (product_id, warehouse_id, quantity, status, created_by, created_at)
            SELECT rq.product_id, rq.warehouse_id, rq.reorder_qty,
                   'Draft', p_created_by, LOCALTIMESTAMP
            FROM   tmp_reorder_queue rq
            -- OUTPUT INSERTED.PurchaseOrderId, INSERTED.ProductId, INSERTED.Quantity
            RETURNING po.purchase_order_id AS po_id,
                      po.product_id        AS po_product_id,
                      po.quantity          AS po_quantity
        )
        SELECT co.po_id,
               co.po_product_id,
               p.product_name,
               co.po_quantity,
               rq.current_stock
        FROM   created_orders    co
        JOIN   tmp_reorder_queue rq ON rq.product_id = co.po_product_id
        JOIN   public.products   p  ON p.product_id  = co.po_product_id
        ORDER  BY co.po_id;
END;
$$;

-- Usage:
-- SELECT * FROM public.process_reorders('system', 50);
