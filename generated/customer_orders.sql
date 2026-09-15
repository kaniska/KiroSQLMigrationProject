-- ============================================================
-- Converted from: source/usp_CustomerOrders.sql
-- Conversion date: 2026-09-10
-- Converter: sql-conversion skill v2
-- Target: Aurora PostgreSQL 17 (sync_product_catalog needs PG 17 MERGE;
--         everything else is PostgreSQL 15+ compatible)
-- Schema: generated/schema.sql
-- Notes:
--   USE [SalesDB], GO, SET NOCOUNT ON, WITH (NOLOCK), N'' prefixes removed
--   Column names converted 1:1 (OrderId → order_id — never "id")
--   MONEY → NUMERIC(19,4); DECIMAL → NUMERIC; NVARCHAR → VARCHAR;
--   DATETIME → TIMESTAMP(3); DATETIME2 → TIMESTAMP; BIT → BOOLEAN;
--   UNIQUEIDENTIFIER → UUID; NEWID() → gen_random_uuid() (core since PG 13)
--   GETDATE() → LOCALTIMESTAMP; SYSDATETIME() → clock_timestamp()::TIMESTAMP;
--   CAST(GETDATE() AS DATE) → CURRENT_DATE
--   SCOPE_IDENTITY() → INSERT ... RETURNING <alias>.<key> INTO v_...
--   BEGIN TRAN/COMMIT + CATCH that only rolls back and re-raises → no
--     EXCEPTION block: the error propagates unchanged and PostgreSQL
--     rolls back the whole call
--   SELECT @v = col with no matching row leaves @v UNCHANGED in T-SQL;
--     SELECT ... INTO sets NULL → assign only IF FOUND where it matters
--   Cursor → FOR loop; #temp → TEMP TABLE IF NOT EXISTS + TRUNCATE
--   Multi-result-set usp_GetCustomerSummary → get_customer_summary +
--     get_customer_summary_referrals (caller replaces @IncludeReferrals)
--   MERGE ... OUTPUT $action → PG 17 MERGE ... RETURNING merge_action()
--   sp_executesql → RETURN QUERY EXECUTE format(...) USING
--   QUOTENAME(col) → whitelist + format('%I')
--   LIKE under the case-insensitive default collation → ILIKE
--   CHARINDEX(n, h) → STRPOS(LOWER(h), LOWER(n)), with CHARINDEX('', h) = 0 kept
--   REPLICATE(s, n) → REPEAT(s, n), NULL when n < 0 (REPEAT would return '')
--   DATEDIFF(day|month|year) → boundary arithmetic (not AGE())
--   CONVERT(VARCHAR(10), dt, 120) → TO_CHAR(dt, 'YYYY-MM-DD') (VARCHAR(10) truncates)
--   FORMAT(dt, 'MMM d, yyyy') → TO_CHAR(dt, 'Mon FMDD, YYYY')
-- ============================================================


-- ============================================================
-- 1. create_customer_order
--    Converted from: usp_CreateCustomerOrder
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_customer_order(
    p_customer_id  INTEGER,
    p_product_id   INTEGER,
    p_quantity     SMALLINT,
    p_notes        VARCHAR(500) DEFAULT NULL,
    p_coupon_code  VARCHAR(50)  DEFAULT NULL
)
RETURNS TABLE(
    order_id              INTEGER,
    customer_id           INTEGER,
    customer_name         TEXT,
    total_amount          NUMERIC(19,4),
    discount_pct          NUMERIC(5,2),
    status                VARCHAR(50),
    created_at_formatted  TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_id         INTEGER;
    v_unit_price       NUMERIC(19,4);
    v_discount         NUMERIC(5,2)  := 0;
    v_coupon_discount  NUMERIC(5,2);
    v_total_amt        NUMERIC(19,4);
    v_created_at       TIMESTAMP     := clock_timestamp();   -- SYSDATETIME()
BEGIN
    SELECT p.price
    INTO   v_unit_price
    FROM   public.products p
    WHERE  p.product_id = p_product_id
      AND  p.is_active  = TRUE;

    IF v_unit_price IS NULL THEN
        RAISE EXCEPTION 'Product % is not available.', p_product_id
            USING ERRCODE = 'P0001';
    END IF;

    IF p_coupon_code IS NOT NULL THEN
        SELECT c.discount_pct
        INTO   v_coupon_discount
        FROM   public.coupons c
        WHERE  c.code       = p_coupon_code
          AND  c.is_active  = TRUE
          AND  c.expires_at > LOCALTIMESTAMP;

        -- T-SQL "SELECT @Discount = DiscountPct" keeps @Discount = 0 when no
        -- coupon matches, so assign only when a row was found.
        IF FOUND THEN
            v_discount := v_coupon_discount;
        END IF;

        -- TODO: MANUAL REVIEW REQUIRED — source bug preserved: this check can
        -- never fire (v_discount is still 0 for an unknown/expired coupon), so
        -- such orders are accepted at full price, exactly as in SQL Server.
        -- The intended behaviour was probably to test IF NOT FOUND instead.
        IF v_discount IS NULL THEN
            RAISE EXCEPTION 'Coupon % is invalid or expired.', p_coupon_code
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    v_total_amt := v_unit_price * p_quantity * (1 - v_discount / 100.0);

    INSERT INTO public.orders AS o
        (customer_id, created_at, total_amount, discount_pct, notes, status)
    VALUES
        (p_customer_id, v_created_at, v_total_amt, v_discount, p_notes, 'Pending')
    RETURNING o.order_id INTO v_order_id;                  -- SCOPE_IDENTITY()

    INSERT INTO public.order_lines (order_id, product_id, quantity, unit_price, line_total)
    VALUES (v_order_id, p_product_id, p_quantity, v_unit_price, v_total_amt);

    IF p_coupon_code IS NOT NULL THEN
        UPDATE public.coupons c
        SET    use_count = c.use_count + 1
        WHERE  c.code = p_coupon_code;
    END IF;

    RETURN QUERY
        SELECT o.order_id,
               o.customer_id,
               c.first_name || ' ' || c.last_name,
               o.total_amount,
               o.discount_pct,
               o.status,
               TO_CHAR(o.created_at, 'YYYY-MM-DD HH24:MI:SS')
        FROM   public.orders    o
        JOIN   public.customers c ON c.customer_id = o.customer_id
        WHERE  o.order_id = v_order_id;
END;
$$;

-- Usage:
-- SELECT * FROM public.create_customer_order(1, 1, 3::SMALLINT, 'Rush order', 'SAVE10');


-- ============================================================
-- 2. get_order_history
--    Converted from: usp_GetOrderHistory
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_order_history(
    p_customer_id    INTEGER       DEFAULT NULL,
    p_status_filter  VARCHAR(50)   DEFAULT NULL,
    p_date_from      TIMESTAMP(3)  DEFAULT NULL,
    p_date_to        TIMESTAMP(3)  DEFAULT NULL,
    p_search_text    VARCHAR(200)  DEFAULT NULL,
    p_page_number    INTEGER       DEFAULT 1,
    p_page_size      INTEGER       DEFAULT 25
)
RETURNS TABLE(
    order_id            INTEGER,
    customer_id         INTEGER,
    customer_name       TEXT,
    email               VARCHAR(255),
    total_amount        NUMERIC(19,4),
    discount_pct        NUMERIC(5,2),
    status              VARCHAR(50),
    days_ago            INTEGER,
    order_date_display  TEXT,
    month_end           TEXT,
    value_tier          TEXT,
    star_rating         TEXT,
    row_num             BIGINT,
    total_count         BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_offset     INTEGER      := (p_page_number - 1) * p_page_size;
    v_date_from  TIMESTAMP(3) := COALESCE(p_date_from, LOCALTIMESTAMP - INTERVAL '6 months');
    v_date_to    TIMESTAMP(3) := COALESCE(p_date_to,   LOCALTIMESTAMP);
BEGIN
    RETURN QUERY
        SELECT
            o.order_id,
            o.customer_id,
            c.first_name || ' ' || c.last_name,
            c.email,
            o.total_amount,
            o.discount_pct,
            o.status,
            (CURRENT_DATE - o.created_at::DATE),                               -- DATEDIFF(day, ...)
            TO_CHAR(o.created_at, 'Mon FMDD, YYYY'),                           -- FORMAT 'MMM d, yyyy'
            TO_CHAR((DATE_TRUNC('month', o.created_at)
                     + INTERVAL '1 month - 1 day')::DATE, 'MM/DD/YYYY'),       -- CONVERT(.., EOMONTH, 101)
            CASE
                WHEN o.total_amount >= 1000 THEN 'High Value'
                WHEN o.total_amount >= 100  THEN 'Medium Value'
                ELSE 'Low Value'
            END,
            REPEAT('★', CASE
                WHEN o.total_amount >= 1000 THEN 3
                WHEN o.total_amount >= 100  THEN 2
                ELSE 1
            END),
            ROW_NUMBER() OVER (ORDER BY o.created_at DESC),
            COUNT(*)     OVER ()
        FROM   public.orders    o
        JOIN   public.customers c ON c.customer_id = o.customer_id
        WHERE  o.created_at BETWEEN v_date_from AND v_date_to
          AND  (p_customer_id   IS NULL OR o.customer_id = p_customer_id)
          AND  (p_status_filter IS NULL OR o.status      = p_status_filter)
          -- LIKE is case-insensitive under SQL Server's default collation → ILIKE
          AND  (p_search_text IS NULL
                OR c.first_name ILIKE '%' || p_search_text || '%'
                OR c.last_name  ILIKE '%' || p_search_text || '%'
                OR c.email      ILIKE '%' || p_search_text || '%')
        ORDER  BY o.created_at DESC
        LIMIT  p_page_size OFFSET v_offset;                  -- OFFSET/FETCH NEXT
END;
$$;

-- Usage:
-- SELECT * FROM public.get_order_history(p_status_filter => 'Pending', p_page_size => 10);


-- ============================================================
-- 3. process_refund
--    Converted from: usp_ProcessRefund
--    Cursor → FOR loop; #RestockQueue → TEMP TABLE
--    @RefundedLines (write-only table variable) dropped — nothing reads it
-- ============================================================
CREATE OR REPLACE FUNCTION public.process_refund(
    p_order_id       INTEGER,
    p_refund_reason  VARCHAR(500),
    p_processed_by   VARCHAR(100)
)
RETURNS TABLE(refund_id INTEGER, refund_amount NUMERIC(19,4), status VARCHAR(20))
LANGUAGE plpgsql
AS $$
DECLARE
    v_refund_id     INTEGER;
    v_order_total   NUMERIC(19,4);
    v_warehouse_id  INTEGER;
    v_restocked     INTEGER;
    v_line          RECORD;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS tmp_restock_queue (
        product_id    INTEGER,
        warehouse_id  INTEGER,
        quantity      SMALLINT
    );
    TRUNCATE tmp_restock_queue;

    SELECT o.total_amount
    INTO   v_order_total
    FROM   public.orders o
    WHERE  o.order_id = p_order_id
      AND  o.status   = 'Completed';

    IF v_order_total IS NULL THEN
        -- RAISERROR inside TRY → CATCH → ROLLBACK + re-raise: same message reaches the caller
        RAISE EXCEPTION 'Order % is not eligible for refund.', p_order_id
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.refunds AS r (order_id, amount, reason, processed_by, processed_at, status)
    VALUES (p_order_id, v_order_total, p_refund_reason, p_processed_by, LOCALTIMESTAMP, 'Pending')
    RETURNING r.refund_id INTO v_refund_id;                -- SCOPE_IDENTITY()

    UPDATE public.orders o
    SET    status     = 'Refunded',
           updated_at = LOCALTIMESTAMP
    WHERE  o.order_id = p_order_id;

    -- DECLARE CURSOR / FETCH / @@FETCH_STATUS loop → FOR loop
    FOR v_line IN
        SELECT ol.line_id, ol.product_id, ol.quantity
        FROM   public.order_lines ol
        WHERE  ol.order_id = p_order_id
    LOOP
        SELECT p.default_warehouse_id
        INTO   v_warehouse_id
        FROM   public.products p
        WHERE  p.product_id = v_line.product_id;

        IF v_warehouse_id IS NOT NULL THEN
            INSERT INTO tmp_restock_queue (product_id, warehouse_id, quantity)
            VALUES (v_line.product_id, v_warehouse_id, v_line.quantity);
        END IF;
    END LOOP;

    UPDATE public.inventory i
    SET    quantity_on_hand = i.quantity_on_hand + rq.quantity,
           last_updated     = LOCALTIMESTAMP
    FROM   tmp_restock_queue rq
    WHERE  rq.product_id   = i.product_id
      AND  rq.warehouse_id = i.warehouse_id;

    GET DIAGNOSTICS v_restocked = ROW_COUNT;               -- @@ROWCOUNT

    IF v_restocked > 0 THEN
        RAISE NOTICE 'Inventory restocked for % item(s).', v_restocked;   -- PRINT
    END IF;

    UPDATE public.refunds r
    SET    status = 'Completed'
    WHERE  r.refund_id = v_refund_id;

    RETURN QUERY SELECT v_refund_id, v_order_total, 'Completed'::VARCHAR(20);
END;
$$;

-- Usage:
-- SELECT * FROM public.process_refund(6, 'Customer requested cancellation', 'agent_001');


-- ============================================================
-- 4a. get_customer_summary
--     Converted from: usp_GetCustomerSummary (result set 1)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_customer_summary(
    p_customer_id  INTEGER
)
RETURNS TABLE(
    customer_id           INTEGER,
    full_name             TEXT,
    masked_email          TEXT,
    age                   INTEGER,
    total_spend           NUMERIC(19,4),
    order_count           INTEGER,
    avg_order_value       NUMERIC(19,4),
    tier                  VARCHAR(20),
    tenure_months         INTEGER,
    first_order_date      TEXT,
    last_order_date       TEXT,
    estimated_next_order  TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total_spend    NUMERIC(19,4);
    v_order_count    INTEGER;
    v_avg_order      NUMERIC(19,4);
    v_first_order    TIMESTAMP(3);
    v_last_order     TIMESTAMP(3);
    v_tenure_months  INTEGER;
    v_tier           VARCHAR(20);
    v_masked_email   TEXT;
    v_email          VARCHAR(255);
    v_at_pos         INTEGER;
BEGIN
    SELECT SUM(o.total_amount), COUNT(*), MIN(o.created_at), MAX(o.created_at)
    INTO   v_total_spend, v_order_count, v_first_order, v_last_order
    FROM   public.orders o
    WHERE  o.customer_id = p_customer_id
      AND  o.status <> 'Cancelled';

    v_avg_order := CASE WHEN v_order_count > 0 THEN v_total_spend / v_order_count ELSE 0 END;

    -- DATEDIFF(month, first, GETDATE()) → month-boundary count
    v_tenure_months :=
          (EXTRACT(YEAR  FROM LOCALTIMESTAMP) - EXTRACT(YEAR  FROM v_first_order)) * 12
        + (EXTRACT(MONTH FROM LOCALTIMESTAMP) - EXTRACT(MONTH FROM v_first_order));

    v_tier := CASE
        WHEN v_total_spend >= 10000 THEN 'Platinum'
        WHEN v_total_spend >= 5000  THEN 'Gold'
        WHEN v_total_spend >= 1000  THEN 'Silver'
        ELSE 'Bronze'
    END;

    SELECT c.email INTO v_email FROM public.customers c WHERE c.customer_id = p_customer_id;

    -- LEFT(e,1) + REPLICATE('*', CHARINDEX('@', e) - 2) + SUBSTRING(e, CHARINDEX('@', e), LEN(e))
    v_at_pos := STRPOS(v_email, '@');
    v_masked_email :=
           LEFT(v_email, 1)
        || CASE WHEN v_at_pos - 2 >= 0 THEN REPEAT('*', v_at_pos - 2) END   -- REPLICATE(n < 0) = NULL
        || SUBSTRING(v_email FROM v_at_pos FOR LENGTH(v_email));

    RETURN QUERY
        SELECT
            c.customer_id,
            c.first_name || ' ' || c.last_name,
            v_masked_email,
            -- DATEDIFF(year, BirthDate, GETDATE()) counts year boundaries, NOT age
            (EXTRACT(YEAR FROM CURRENT_DATE) - EXTRACT(YEAR FROM c.birth_date))::INTEGER,
            v_total_spend,
            v_order_count,
            v_avg_order,
            v_tier,
            v_tenure_months,
            TO_CHAR(v_first_order, 'YYYY-MM-DD'),
            TO_CHAR(v_last_order,  'YYYY-MM-DD'),
            -- CONVERT(VARCHAR(10), DATEADD(day, 30, @LastOrder), 120): VARCHAR(10) keeps the date only
            TO_CHAR(v_last_order + INTERVAL '30 days', 'YYYY-MM-DD')
        FROM   public.customers c
        WHERE  c.customer_id = p_customer_id;
END;
$$;


-- ============================================================
-- 4b. get_customer_summary_referrals
--     Converted from: usp_GetCustomerSummary (result set 2, returned only
--     when @IncludeReferrals = 1)
--     NOTE: same logic as get_customer_lifetime_value_referrals
--     (generated/sales_reporting.sql) — candidate for consolidation after cut-over.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_customer_summary_referrals(
    p_customer_id  INTEGER
)
RETURNS TABLE(
    customer_id       INTEGER,
    name              TEXT,
    level             INTEGER,
    referral_revenue  NUMERIC(19,4)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        WITH RECURSIVE referral_tree AS (
            SELECT c.customer_id                       AS ref_customer_id,
                   c.first_name || ' ' || c.last_name  AS ref_name,
                   c.referred_by,
                   1                                   AS lvl
            FROM   public.customers c
            WHERE  c.referred_by = p_customer_id

            UNION ALL

            SELECT c.customer_id,
                   c.first_name || ' ' || c.last_name,
                   c.referred_by,
                   rt.lvl + 1
            FROM   public.customers c
            JOIN   referral_tree rt ON rt.ref_customer_id = c.referred_by
            WHERE  rt.lvl < 5
        )
        SELECT rt.ref_customer_id,
               rt.ref_name,
               rt.lvl,
               COALESCE(SUM(o.total_amount), 0)::NUMERIC(19,4)
        FROM   referral_tree rt
        LEFT   JOIN public.orders o
               ON  o.customer_id = rt.ref_customer_id
               AND o.status <> 'Cancelled'
        GROUP  BY rt.ref_customer_id, rt.ref_name, rt.lvl
        ORDER  BY rt.lvl, 4 DESC;
END;
$$;

-- Usage (replaces EXEC usp_GetCustomerSummary @CustomerId = 42, @IncludeReferrals = 1):
-- SELECT * FROM public.get_customer_summary(42);
-- SELECT * FROM public.get_customer_summary_referrals(42);


-- ============================================================
-- 5. sync_product_catalog
--    Converted from: usp_SyncProductCatalog
--    Requires PostgreSQL 17: WHEN NOT MATCHED BY SOURCE, RETURNING merge_action(),
--    and MERGE inside WITH. (PG 15/16: split into INSERT ... WHERE NOT EXISTS,
--    UPDATE ... FROM and UPDATE ... WHERE NOT EXISTS, each counted separately.)
--    @SyncResults only fed the final summary, so the summary is aggregated
--    straight from MERGE ... RETURNING. SQL Server reports the
--    NOT MATCHED BY SOURCE → UPDATE rows as 'UPDATE' (not 'DELETE'), and so does
--    merge_action().
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_product_catalog(
    p_effective_date  DATE DEFAULT NULL
)
RETURNS TABLE(action VARCHAR(10), count INTEGER, inserted INTEGER, updated INTEGER, deleted INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_effective_date  DATE := COALESCE(p_effective_date, CURRENT_DATE);   -- CAST(GETDATE() AS DATE)
BEGIN
    RETURN QUERY
        WITH merged AS (
            MERGE INTO public.products AS tgt
            USING (
                SELECT s.product_id, s.sku, s.product_name, s.price, s.category_id, s.is_active
                FROM   public.product_staging s
                WHERE  s.effective_date <= v_effective_date
                  AND  (s.expires_date IS NULL OR s.expires_date > v_effective_date)
            ) AS src
            ON tgt.sku = src.sku
            WHEN MATCHED AND src.is_active = FALSE THEN
                UPDATE SET is_active = FALSE, updated_at = LOCALTIMESTAMP
            WHEN MATCHED AND (tgt.price <> src.price OR tgt.product_name <> src.product_name) THEN
                UPDATE SET product_name = src.product_name,
                           price        = src.price,
                           updated_at   = LOCALTIMESTAMP
            WHEN NOT MATCHED BY TARGET AND src.is_active = TRUE THEN
                INSERT (sku, product_name, price, category_id, is_active, created_at)
                VALUES (src.sku, src.product_name, src.price, src.category_id, TRUE, LOCALTIMESTAMP)
            WHEN NOT MATCHED BY SOURCE THEN
                UPDATE SET is_active = FALSE, updated_at = LOCALTIMESTAMP
            RETURNING merge_action() AS merge_act, tgt.product_id AS merged_product_id
        )
        SELECT m.merge_act::VARCHAR(10),
               COUNT(*)::INTEGER,
               COUNT(*) FILTER (WHERE m.merge_act = 'INSERT')::INTEGER,
               COUNT(*) FILTER (WHERE m.merge_act = 'UPDATE')::INTEGER,
               COUNT(*) FILTER (WHERE m.merge_act = 'DELETE')::INTEGER
        FROM   merged m
        GROUP  BY m.merge_act
        ORDER  BY m.merge_act;
END;
$$;

-- Usage:
-- SELECT * FROM public.sync_product_catalog('2026-09-10');


-- ============================================================
-- 6. search_products_dynamic
--    Converted from: usp_SearchProductsDynamic
--    RETURNS TABLE (typed), not SETOF RECORD: the column list is fixed,
--    only the WHERE / ORDER BY vary.
-- ============================================================
CREATE OR REPLACE FUNCTION public.search_products_dynamic(
    p_category     VARCHAR(100)   DEFAULT NULL,
    p_min_price    NUMERIC(19,4)  DEFAULT NULL,
    p_max_price    NUMERIC(19,4)  DEFAULT NULL,
    p_search_text  VARCHAR(200)   DEFAULT NULL,
    p_sort_column  VARCHAR(50)    DEFAULT 'Price',
    p_sort_dir     VARCHAR(4)     DEFAULT 'ASC',
    p_page         INTEGER        DEFAULT 1,
    p_page_size    INTEGER        DEFAULT 20
)
RETURNS TABLE(
    product_id      INTEGER,
    product_name    VARCHAR(200),
    sku             VARCHAR(50),
    price           NUMERIC(19,4),
    category_id     INTEGER,
    category_name   VARCHAR(100),
    match_position  INTEGER,
    age_days        INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sql       TEXT;
    v_sort_col  TEXT;
    v_sort_dir  TEXT;
    v_offset    INTEGER := (p_page - 1) * p_page_size;
BEGIN
    -- Whitelist (case-insensitive, like the source's collation); accepts the
    -- legacy PascalCase names and the new snake_case names
    v_sort_col := CASE LOWER(REPLACE(p_sort_column, '_', ''))
                      WHEN 'price'       THEN 'price'
                      WHEN 'productname' THEN 'product_name'
                      WHEN 'createdat'   THEN 'created_at'
                      WHEN 'sku'         THEN 'sku'
                      ELSE 'price'
                  END;
    v_sort_dir := CASE WHEN UPPER(p_sort_dir) IN ('ASC', 'DESC') THEN UPPER(p_sort_dir) ELSE 'ASC' END;

    v_sql := $q$
        SELECT p.product_id,
               p.product_name,
               p.sku,
               p.price,
               p.category_id,
               cat.category_name,
               -- CHARINDEX(ISNULL(@srch, ''), p.ProductName): '' → 0, case-insensitive
               CASE WHEN COALESCE($4, '') = '' THEN 0
                    ELSE STRPOS(LOWER(p.product_name), LOWER($4)) END,
               (CURRENT_DATE - p.created_at::DATE)
        FROM   public.products   p
        JOIN   public.categories cat ON cat.category_id = p.category_id
        WHERE  p.is_active = TRUE
    $q$;

    IF p_category    IS NOT NULL THEN v_sql := v_sql || ' AND cat.category_name = $1'; END IF;
    IF p_min_price   IS NOT NULL THEN v_sql := v_sql || ' AND p.price >= $2';           END IF;
    IF p_max_price   IS NOT NULL THEN v_sql := v_sql || ' AND p.price <= $3';           END IF;
    IF p_search_text IS NOT NULL THEN v_sql := v_sql || $q$ AND p.product_name ILIKE '%' || $4 || '%'$q$; END IF;

    -- QUOTENAME(@SortColumn) → %I (quote_ident); direction comes from the whitelist
    v_sql := v_sql || format(' ORDER BY p.%I %s LIMIT $6 OFFSET $5', v_sort_col, v_sort_dir);

    RETURN QUERY EXECUTE v_sql
        USING p_category,      -- $1  @cat
              p_min_price,     -- $2  @minP
              p_max_price,     -- $3  @maxP
              p_search_text,   -- $4  @srch
              v_offset,        -- $5  @off
              p_page_size;     -- $6  @ps
END;
$$;

-- Usage:
-- SELECT * FROM public.search_products_dynamic(p_category => 'Widgets', p_sort_column => 'ProductName');


-- ============================================================
-- 7. calculate_shipping
--    Converted from: usp_CalculateShipping
-- ============================================================
CREATE OR REPLACE FUNCTION public.calculate_shipping(
    p_order_id      INTEGER,
    p_ship_to_zip   VARCHAR(10),
    p_is_expedited  BOOLEAN DEFAULT FALSE,
    p_tracking_ref  UUID    DEFAULT NULL
)
RETURNS TABLE(
    order_id            INTEGER,
    tracking_number     TEXT,
    total_weight_lbs    NUMERIC(10,3),
    shipping_cost       NUMERIC(19,4),
    is_expedited        BOOLEAN,
    estimated_delivery  DATE,
    calculated_at       TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tracking_ref    UUID          := COALESCE(p_tracking_ref, gen_random_uuid());   -- NEWID()
    v_weight          NUMERIC(10,3);
    v_order_total     NUMERIC(19,4);
    v_base_rate       NUMERIC(19,4);
    v_expedite_adder  NUMERIC(19,4) := 0;
    v_free_threshold  NUMERIC(19,4) := 50.00;
    v_shipping_cost   NUMERIC(19,4);
    v_zip_prefix      VARCHAR(3);
BEGIN
    SELECT o.total_amount, SUM(p.weight_lbs * ol.quantity)
    INTO   v_order_total, v_weight
    FROM   public.orders      o
    JOIN   public.order_lines ol ON ol.order_id  = o.order_id
    JOIN   public.products    p  ON p.product_id = ol.product_id
    WHERE  o.order_id = p_order_id
    GROUP  BY o.total_amount;

    IF v_order_total IS NULL THEN
        RAISE EXCEPTION 'Order % not found.', p_order_id
            USING ERRCODE = 'P0001';
    END IF;

    v_zip_prefix := LEFT(p_ship_to_zip, 3);

    v_base_rate := CASE
        WHEN v_zip_prefix BETWEEN '100' AND '199' THEN ROUND(v_weight * 0.85, 2)   -- Northeast
        WHEN v_zip_prefix BETWEEN '300' AND '399' THEN ROUND(v_weight * 1.05, 2)   -- Southeast
        WHEN v_zip_prefix BETWEEN '600' AND '699' THEN ROUND(v_weight * 1.20, 2)   -- Midwest
        WHEN v_zip_prefix BETWEEN '900' AND '999' THEN ROUND(v_weight * 1.45, 2)   -- West Coast
        ELSE                                           ROUND(v_weight * 1.10, 2)
    END;

    IF p_is_expedited THEN
        v_expedite_adder := v_base_rate * 0.5;            -- 50% surcharge
    END IF;

    v_shipping_cost := CASE
        WHEN v_order_total >= v_free_threshold THEN 0
        ELSE v_base_rate + v_expedite_adder
    END;

    RETURN QUERY SELECT
        p_order_id,
        LOWER(REPLACE(v_tracking_ref::TEXT, '-', '')),
        v_weight,
        v_shipping_cost,
        p_is_expedited,
        CASE WHEN p_is_expedited THEN CURRENT_DATE + 1 ELSE CURRENT_DATE + 5 END,
        TO_CHAR(LOCALTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS');   -- FORMAT 'yyyy-MM-ddTHH:mm:ss'
END;
$$;

-- Usage:
-- SELECT * FROM public.calculate_shipping(6, '10001', FALSE);
-- SELECT * FROM public.calculate_shipping(6, '90210', TRUE);
