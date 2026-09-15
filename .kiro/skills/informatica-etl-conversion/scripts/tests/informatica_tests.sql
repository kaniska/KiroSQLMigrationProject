-- ============================================================
-- informatica-etl-conversion skill — PostgreSQL tests
-- Runs the SQL that lives in the converted example XML files (rendered by
-- infa_sql_tool.py render into .generated/*.rendered.sql: exNN_<id> views,
-- pg_temp.exNN_<id>() functions) against the sample schema + ETL fixtures.
-- Tags: [IC-nn] corner cases (references/corner-cases.md).
-- ============================================================

\echo '--- example 01: incremental staging load'
DO $$
DECLARE s TEXT := 'infa01_orders_incremental'; r RECORD;
BEGIN
    PERFORM test_assert_equal(s, 'TOP (batch param) → LIMIT, params from the .prm: 6 changed orders since the last run [IC-24] [IC-02]',
        (SELECT COUNT(*) FROM ex01_01), 6::BIGINT);
    SELECT * INTO r FROM ex01_01 v WHERE v.order_id = 2;
    PERFORM test_assert_equal(s, 'ISNULL + N'''' concatenation → COALESCE || [IC-30] [IC-11]', r.customer_name, 'Alice Smith');
    PERFORM test_assert_equal(s, 'CONVERT(DATETIME, CONVERT(VARCHAR(10), d, 120)) → date_trunc(day) [IC-11]', r.order_date, '2025-06-10 00:00:00'::TIMESTAMP);
    PERFORM test_assert_equal(s, 'Source Filter fragment renders against the associated sources: 7 orders × 5 customers [IC-05] [IC-32]',
        (SELECT row_count FROM ex01_02), 35::BIGINT);
    PERFORM test_assert_equal(s, 'Pre SQL (SET NOCOUNT dropped, TRUNCATE kept) ran inline: staging empty [IC-10] [IC-11]',
        (SELECT COUNT(*) FROM public.stg_orders), 0::BIGINT);
    PERFORM pg_temp.ex01_04();
    PERFORM test_assert_equal(s, 'Post SQL: UPDATE STATISTICS → ANALYZE, EXEC proc → SELECT fn(): load 42 logged [IC-11] [IC-13]',
        (SELECT l.load_id FROM public.etl_load_log l WHERE l.table_name = 'Stg_Orders'), 42);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- example 02: customer dimension'
DO $$
DECLARE s TEXT := 'infa02_customer_dim';
BEGIN
    PERFORM test_assert_equal(s, 'User Defined Join in { } syntax renders as a join: 8 rows [IC-06]', (SELECT row_count FROM ex02_01), 8::BIGINT);
    PERFORM test_assert_equal(s, 'Source Filter LIKE under a CI collation → ILIKE keeps all 8 rows [IC-25] [IC-05]', (SELECT row_count FROM ex02_02), 8::BIGINT);
    PERFORM test_assert_equal(s, 'naive case-sensitive LIKE would match nothing [IC-25]',
        (SELECT COUNT(*) FROM public.customers c WHERE c.email LIKE '%@EXAMPLE.COM'), 0::BIGINT);
    PERFORM test_assert_equal(s, 'Lookup override: aliases = lookup ports, LTRIM(RTRIM()) → TRIM, ORDER BY + -- kept [IC-07] [IC-08]',
        (SELECT v.email FROM ex02_03 v), 'alice@example.com'::TEXT);
    PERFORM test_assert_equal(s, 'Pre SQL T-SQL batch → function: dimension not empty, so no unknown row added [IC-10] [IC-11]',
        (SELECT COUNT(*) FROM public.dim_customer), 1::BIGINT);
    PERFORM test_assert_equal(s, 'Update Override with :TU. bindings updates exactly 1 row [IC-12]', pg_temp.ex02_05(), 1::BIGINT);
    PERFORM test_assert_equal(s, 'GETDATE() → LOCALTIMESTAMP; bound email written [IC-12] [IC-11]',
        (SELECT d.email FROM public.dim_customer d WHERE d.customer_key = 1), 'alice.updated@example.com'::VARCHAR);
    PERFORM pg_temp.ex02_07();
    PERFORM test_assert_equal(s, 'Post SQL MERGE (PG 15+) upserted from staging: 2 rows, email restored [IC-11] [IC-10]',
        (SELECT COUNT(*)::TEXT || '/' || (SELECT d.email FROM public.dim_customer d WHERE d.customer_id = 1) FROM public.dim_customer),
        '2/alice@example.com');
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- example 03: stored procedures'
DO $$
DECLARE s TEXT := 'infa03_shipping_procs';
BEGIN
    PERFORM test_assert_equal(s, 'Source Filter with N'''' literals → 5 completed/processed orders [IC-05] [IC-30]', (SELECT row_count FROM ex03_01), 5::BIGINT);
    PERFORM test_assert_equal(s, 'Source Pre Load stored procedure → SELECT fn(archive-days param): archived the 1 old cancelled order [IC-13] [IC-02]',
        (SELECT archive_old_orders FROM ex03_02), 1);
    PERFORM test_assert_equal(s, 'Connected stored procedure → SQL transformation calling the function with ?port? bindings [IC-13] [IC-14]',
        (SELECT shipping_cost FROM ex03_04), 0.0000::NUMERIC);
    PERFORM test_assert_equal(s, 'SQL transformation: TOP 1 → LIMIT 1, ?CustomerId? bound, <> from &lt;&gt; [IC-24] [IC-14] [IC-01]',
        (SELECT v.order_id::TEXT || '/' || v.total_amount FROM ex03_05 v), '3/299.9900');
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- example 04: session override, reusable lookup, temp table'
DO $$
DECLARE s TEXT := 'infa04_product_sales';
BEGIN
    PERFORM test_assert_equal(s, 'reusable lookup override ([dbo].[Products] → public.products): 4 active products [IC-16] [IC-20] [IC-07]',
        (SELECT COUNT(*) FROM ex04_01), 4::BIGINT);
    PERFORM test_assert_equal(s, 'mapping-level override: 8 product-months, DATEFROMPARTS → date_trunc, & in literal [IC-15] [IC-27] [IC-11]',
        (SELECT COUNT(*) FROM ex04_03), 8::BIGINT);
    PERFORM test_assert_equal(s, 'yyyymmdd parameter value parses as a date: first period 2024-03 [IC-26]',
        (SELECT MIN(v.period_start) FROM ex04_03 v), '2024-03-01'::TIMESTAMP);
    PERFORM test_assert_equal(s, 'session-level override (wins over mapping-level) joins the temp table created by Pre SQL: 8 rows [IC-15] [IC-22]',
        (SELECT COUNT(*) FROM ex04_06), 8::BIGINT);
    PERFORM test_assert_equal(s, 'HAVING with a mapping parameter and the region join keep the right units [IC-02] [IC-23]',
        (SELECT v.units_sold FROM ex04_06 v WHERE v.product_id = 4 AND v.period_start = '2026-06-01'), 4::BIGINT);
    PERFORM pg_temp.ex04_07();
    PERFORM test_assert_equal(s, 'Post SQL: TABLOCK/OPTION hints dropped, DBCC removed with a TODO; audit row written [IC-23] [IC-11]',
        (SELECT a.load_name || ':' || a.row_count FROM public.audit_load a), 'Product Sales:0');
    PERFORM test_assert_sqlstate(s, 'Post SQL DROP of the temp table: in this harness the override views depend on it (2BP01) — a real session has no such views [IC-22]',
        'SELECT pg_temp.ex04_05()', '2BP01');
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- example 05: real export format (Windows-1252, CRLF), full SQL Server ETL job'
DO $$
DECLARE s TEXT := 'infa05_customer_summary';
BEGIN
    PERFORM test_assert_equal(s, 'CTE + ROW_NUMBER + OUTER APPLY override returns one row per customer with orders: 5 rows, 7 columns in port order [IC-04] [IC-11]',
        (SELECT COUNT(*) FROM ex05_01), 5::BIGINT);
    PERFORM test_assert_equal(s, 'customer 1: 3 orders incl. 18:45 on the as-of day (DATEADD(DAY,1,CONVERT(DATE,yyyymmdd,112)) boundary) [IC-26] [IC-02]',
        (SELECT v.order_count FROM ex05_01 v WHERE v.customer_id = 1), 3);
    PERFORM test_assert_equal(s, 'CAST(SUM(money) AS DECIMAL(19,4)) → NUMERIC(19,4); ROW_NUMBER picks the latest order amount [IC-11]',
        (SELECT v.lifetime_amount::TEXT || '/' || v.last_order_amount::TEXT FROM ex05_01 v WHERE v.customer_id = 1), '4299.9900/299.9900');
    PERFORM test_assert_equal(s, 'DATEDIFF(DAY, ts, date) counts day boundaries: 0 for 18:45 on the as-of day, 373 and 41 days for customers 2 and 5 [IC-11]',
        (SELECT string_agg(v.days_since_last_order::TEXT, ',' ORDER BY v.customer_id) FROM ex05_01 v WHERE v.customer_id IN (1, 2, 5)), '0,373,41');
    PERFORM test_assert_equal(s, 'N''Cancelled'' filter: customer 2 keeps only the processed order [IC-30] [IC-20]',
        (SELECT v.lifetime_amount FROM ex05_01 v WHERE v.customer_id = 2), 199.9900::NUMERIC(19,4));
    PERFORM test_assert_equal(s, 'LTRIM(RTRIM()) + N'' '' + ISNULL() → TRIM() || '' '' || COALESCE() [IC-30] [IC-11]',
        (SELECT v.customer_name FROM ex05_01 v WHERE v.customer_id = 5), 'erin Stone');
    PERFORM test_assert_equal(s, 'OUTER APPLY STRING_AGG … WITHIN GROUP → LEFT JOIN LATERAL string_agg(… ORDER BY) of distinct SKUs [IC-11]',
        (SELECT string_agg(v.purchased_skus, ' | ' ORDER BY v.customer_id) FROM ex05_01 v), 'GP-002,WP-001 | BW-003,PG-004 | GP-002,WP-001 | BW-003 | PG-004');
    PERFORM test_assert_equal(s, 'Lookup Procedure override: IsActive = 1 → boolean, aliases = ports, ORDER BY … -- kept; 3 active segments [IC-07] [IC-40]',
        (SELECT string_agg(v.segmentcode, ',') FROM ex05_02 v), 'BRONZE,SILVER,GOLD');
    PERFORM test_assert_equal(s, 'lookup condition MinLifetimeAmount <= IN_LifetimeAmount with "Use Last Value" gives GOLD for customer 1 [IC-07]',
        (SELECT v.segmentcode FROM ex05_02 v WHERE v.minlifetimeamount <= (SELECT o.lifetime_amount FROM ex05_01 o WHERE o.customer_id = 1)
         ORDER BY v.minlifetimeamount DESC LIMIT 1), 'GOLD'::VARCHAR);
    PERFORM test_assert_equal(s, 'Pre SQL: SET NOCOUNT dropped, IF OBJECT_ID … TRUNCATE → TRUNCATE (leftover row removed), EXEC → SELECT fn(load-id parameter) [IC-10] [IC-11] [IC-13]',
        (SELECT COUNT(*)::TEXT FROM public.stg_customer_summary) || '/' ||
        (SELECT string_agg(l.job_name || ':' || l.load_id || ':' || (l.ended_at IS NULL), ',') FROM public.etl_run_log l),
        '0/wf_Load_Customer_Summary:42:true');
    INSERT INTO public.stg_customer_summary (customer_id, customer_name, order_count, lifetime_amount, last_order_amount, days_since_last_order, purchased_skus, load_id)
    SELECT v.customer_id, v.customer_name, v.order_count, v.lifetime_amount, v.last_order_amount, v.days_since_last_order, v.purchased_skus, 42 FROM ex05_01 v;
    PERFORM test_assert_equal(s, 'Update Override: :TU. ports renamed with the columns map, SYSDATETIME() → LOCALTIMESTAMP; exactly 1 row [IC-12] [IC-21]',
        pg_temp.ex05_04(), 1::BIGINT);
    PERFORM test_assert_equal(s, 'Update Override wrote the bound values [IC-12]',
        (SELECT c.order_count || '/' || c.lifetime_amount || '/' || c.segment_code || '/' || (c.updated_at IS NOT NULL) FROM public.stg_customer_summary c WHERE c.customer_id = 1),
        '9/9999.5000/GOLD/true');
    PERFORM pg_temp.ex05_06();
    PERFORM test_assert_equal(s, 'Post SQL: UPDATE STATISTICS … WITH FULLSCAN → ANALYZE; \; in a literal is a semicolon after Informatica splits the list [IC-10] [IC-11]',
        (SELECT l.rows_loaded || '/' || l.note || '/' || (l.ended_at IS NOT NULL) FROM public.etl_run_log l WHERE l.load_id = 42), '5/loaded; see summary/true');
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;
