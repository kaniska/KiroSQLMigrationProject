-- ============================================================
-- Converted from: source/usp_SalesReporting.sql
-- Conversion date: 2026-09-10
-- Converter: sql-conversion skill v2
-- Target: Aurora PostgreSQL 17 (PostgreSQL 15+ compatible)
-- Schema: generated/schema.sql
-- Notes:
--   USE [SalesDB], GO, SET NOCOUNT ON, WITH (NOLOCK) removed
--   YEAR()/MONTH() → EXTRACT(...)::INTEGER; DATEFROMPARTS → make_date
--   EOMONTH(d) → (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE
--   DATEDIFF(month, a, b) → month-BOUNDARY count (not AGE(), which counts
--     completed months): (y(b)-y(a))*12 + (m(b)-m(a))
--   FORMAT(d, 'yyyy-MM-dd') → TO_CHAR(d, 'YYYY-MM-DD')
--   MONEY aggregates cast to NUMERIC(19,4): RETURN QUERY does not apply
--     the RETURNS TABLE typmod, so AVG() would otherwise return 16+ decimals
--   usp_GetCustomerLifetimeValue returns TWO result sets → split into
--     get_customer_lifetime_value            (result set 1: stats)
--     get_customer_lifetime_value_referrals  (result set 2: only when
--                                             @IncludeReferrals = 1)
--     The caller replaces @IncludeReferrals by deciding whether to call #2.
--   WITH (recursive CTE) → WITH RECURSIVE
--   sp_executesql → RETURN QUERY EXECUTE ... USING
--   DATEADD(week, DATEDIFF(week, 0, d), 0) → DATE_TRUNC('week', d + 1 day):
--     SQL Server maps Sunday to the FOLLOWING Monday; plain
--     DATE_TRUNC('week') would map it to the previous Monday
--   SOURCE BEHAVIOUR PRESERVED (flagged for review, see migration_log.json):
--     BETWEEN <start> AND <end date at 00:00> excludes rows after midnight
--     on the last day, in both get_monthly_sales_summary and
--     get_product_performance. Kept identical so old and new reports reconcile.
-- ============================================================


-- ============================================================
-- 1. get_monthly_sales_summary
--    Converted from: usp_GetMonthlySalesSummary
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_monthly_sales_summary(
    p_year   INTEGER DEFAULT NULL,
    p_month  INTEGER DEFAULT NULL
)
RETURNS TABLE(
    category           VARCHAR(100),
    product_name       VARCHAR(200),
    units_sold         BIGINT,
    revenue            NUMERIC(19,4),
    avg_selling_price  NUMERIC(19,4),
    order_count        BIGINT,
    category_revenue   NUMERIC(19,4),
    rank_in_category   BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_year        INTEGER;
    v_month       INTEGER;
    v_start_date  TIMESTAMP(3);   -- DATETIME
    v_end_date    TIMESTAMP(3);   -- DATETIME
BEGIN
    v_year  := COALESCE(p_year,  EXTRACT(YEAR  FROM LOCALTIMESTAMP)::INTEGER);
    v_month := COALESCE(p_month, EXTRACT(MONTH FROM LOCALTIMESTAMP)::INTEGER);

    v_start_date := make_date(v_year, v_month, 1);                       -- DATEFROMPARTS
    v_end_date   := (DATE_TRUNC('month', v_start_date)
                     + INTERVAL '1 month - 1 day')::DATE;                -- EOMONTH → midnight

    RETURN QUERY
        SELECT
            p.category,
            p.product_name,
            SUM(ol.quantity)::BIGINT                                    AS units_sold,
            SUM(ol.quantity * ol.unit_price)::NUMERIC(19,4)             AS revenue,
            AVG(ol.unit_price)::NUMERIC(19,4)                           AS avg_selling_price,
            COUNT(DISTINCT o.order_id)::BIGINT                          AS order_count,
            SUM(SUM(ol.quantity * ol.unit_price))
                OVER (PARTITION BY p.category)::NUMERIC(19,4)           AS category_revenue,
            RANK() OVER (PARTITION BY p.category
                         ORDER BY SUM(ol.quantity * ol.unit_price) DESC) AS rank_in_category
        FROM   public.order_lines ol
        JOIN   public.orders      o ON o.order_id   = ol.order_id
        JOIN   public.products    p ON p.product_id = ol.product_id
        -- SOURCE BEHAVIOUR PRESERVED: end bound is 00:00 on the last day
        WHERE  o.created_at BETWEEN v_start_date AND v_end_date
          AND  o.status <> 'Cancelled'
        GROUP  BY p.category, p.product_id, p.product_name
        ORDER  BY 7 DESC, 8 ASC;          -- CategoryRevenue DESC, RankInCategory ASC
END;
$$;

-- Usage:
-- SELECT * FROM public.get_monthly_sales_summary();
-- SELECT * FROM public.get_monthly_sales_summary(2026, 8);


-- ============================================================
-- 2a. get_customer_lifetime_value
--     Converted from: usp_GetCustomerLifetimeValue (result set 1)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_customer_lifetime_value(
    p_customer_id  INTEGER
)
RETURNS TABLE(
    customer_id       INTEGER,
    customer_name     TEXT,
    email             VARCHAR(255),
    lifetime_revenue  NUMERIC(19,4),
    total_orders      INTEGER,
    avg_order_value   NUMERIC(19,4),
    tenure_months     INTEGER,
    first_order_date  TEXT,
    last_order_date   TEXT,
    tier              TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total_revenue    NUMERIC(19,4);
    v_order_count      INTEGER;
    v_first_order_date TIMESTAMP(3);
    v_last_order_date  TIMESTAMP(3);
    v_avg_order_value  NUMERIC(19,4);
    v_tenure_months    INTEGER;
BEGIN
    SELECT SUM(o.total_amount), COUNT(*), MIN(o.created_at), MAX(o.created_at)
    INTO   v_total_revenue, v_order_count, v_first_order_date, v_last_order_date
    FROM   public.orders o
    WHERE  o.customer_id = p_customer_id
      AND  o.status <> 'Cancelled';

    v_avg_order_value := CASE WHEN v_order_count > 0
                              THEN v_total_revenue / v_order_count
                              ELSE 0 END;

    -- DATEDIFF(month, first, GETDATE()) counts month boundaries crossed
    v_tenure_months :=
          (EXTRACT(YEAR  FROM LOCALTIMESTAMP) - EXTRACT(YEAR  FROM v_first_order_date)) * 12
        + (EXTRACT(MONTH FROM LOCALTIMESTAMP) - EXTRACT(MONTH FROM v_first_order_date));

    RETURN QUERY
        SELECT
            c.customer_id,
            c.first_name || ' ' || c.last_name          AS customer_name,
            c.email,
            v_total_revenue,
            v_order_count,
            v_avg_order_value,
            v_tenure_months,
            TO_CHAR(v_first_order_date, 'YYYY-MM-DD'),
            TO_CHAR(v_last_order_date,  'YYYY-MM-DD'),
            CASE
                WHEN v_total_revenue >= 10000 THEN 'Platinum'
                WHEN v_total_revenue >= 5000  THEN 'Gold'
                WHEN v_total_revenue >= 1000  THEN 'Silver'
                ELSE 'Bronze'
            END
        FROM   public.customers c
        WHERE  c.customer_id = p_customer_id;
END;
$$;


-- ============================================================
-- 2b. get_customer_lifetime_value_referrals
--     Converted from: usp_GetCustomerLifetimeValue (result set 2,
--     returned only when @IncludeReferrals = 1)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_customer_lifetime_value_referrals(
    p_customer_id  INTEGER
)
RETURNS TABLE(
    customer_id       INTEGER,
    customer_name     TEXT,
    referral_level    INTEGER,
    referral_revenue  NUMERIC(19,4)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        WITH RECURSIVE referral_tree AS (
            -- Anchor: direct referrals by this customer
            SELECT c.customer_id                       AS ref_customer_id,
                   c.first_name || ' ' || c.last_name  AS ref_name,
                   c.referred_by,
                   1                                   AS lvl
            FROM   public.customers c
            WHERE  c.referred_by = p_customer_id

            UNION ALL

            -- Recursive: referrals of referrals (max 5 levels, as in the source)
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
        ORDER  BY rt.lvl, 4 DESC;         -- Level, ReferralRevenue DESC
END;
$$;

-- Usage (replaces EXEC usp_GetCustomerLifetimeValue @CustomerId = 42, @IncludeReferrals = 1):
-- SELECT * FROM public.get_customer_lifetime_value(42);
-- SELECT * FROM public.get_customer_lifetime_value_referrals(42);


-- ============================================================
-- 3. get_product_performance
--    Converted from: usp_GetProductPerformance
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_product_performance(
    p_start_date  DATE,
    p_end_date    DATE,
    p_group_by    VARCHAR(10) DEFAULT 'month'   -- 'month' | 'week' | 'quarter'
)
RETURNS TABLE(
    product_id           INTEGER,
    product_name         VARCHAR(200),
    category             VARCHAR(100),
    period_start         DATE,
    units_sold           BIGINT,
    revenue              NUMERIC(19,4),
    order_count          BIGINT,
    avg_units_per_order  DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sql         TEXT;
    v_date_trunc  TEXT;
BEGIN
    -- Fixed, whitelisted fragments only (as in the source) — safe to concatenate
    v_date_trunc := CASE p_group_by
        WHEN 'week'    THEN $q$DATE_TRUNC('week', o.created_at + INTERVAL '1 day')::DATE$q$
        WHEN 'quarter' THEN $q$DATE_TRUNC('quarter', o.created_at)::DATE$q$
        ELSE                $q$DATE_TRUNC('month', o.created_at)::DATE$q$
    END;

    v_sql := format($q$
        SELECT p.product_id,
               p.product_name,
               p.category,
               %1$s                                      AS period_start,
               SUM(ol.quantity)::BIGINT                  AS units_sold,
               SUM(ol.quantity * ol.unit_price)::NUMERIC(19,4) AS revenue,
               COUNT(DISTINCT o.order_id)::BIGINT        AS order_count,
               AVG(ol.quantity::DOUBLE PRECISION)        AS avg_units_per_order
        FROM   public.order_lines ol
        JOIN   public.orders      o ON o.order_id   = ol.order_id
        JOIN   public.products    p ON p.product_id = ol.product_id
        WHERE  o.created_at BETWEEN $1 AND $2
          AND  o.status <> 'Cancelled'
        GROUP  BY p.product_id, p.product_name, p.category, %1$s
        ORDER  BY period_start, revenue DESC
    $q$, v_date_trunc);

    -- SOURCE BEHAVIOUR PRESERVED: DATE parameters compare as 00:00, so rows
    -- after midnight on p_end_date are excluded (same as SQL Server)
    RETURN QUERY EXECUTE v_sql
        USING p_start_date::TIMESTAMP,   -- $1
              p_end_date::TIMESTAMP;     -- $2
END;
$$;

-- Usage:
-- SELECT * FROM public.get_product_performance('2026-01-01', '2026-09-10', 'month');
-- SELECT * FROM public.get_product_performance('2026-01-01', '2026-09-10', 'quarter');
