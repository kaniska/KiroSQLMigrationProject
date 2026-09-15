-- ============================================================
-- File: tests/test_cases.sql
-- Description: Project test suites (generated/ + examples/). Sourced by
--              tests/test_runner.sql after the schema, seed data
--              (tests/seed_data.sql) and all converted objects are loaded.
-- Order matters: read-only suites run first, then suites that change data.
-- Each suite is one DO block; an unexpected error is recorded as ERROR for
-- that suite and the run continues.
-- ============================================================


-- ============================================================
-- CATALOG — every converted routine loaded (static rules: lib/static_checks.sql)
-- ============================================================
\echo '--- catalog'
DO $$
DECLARE
    v_expected TEXT[] := ARRAY[
        -- generated/
        'adjust_stock', 'get_low_stock_alerts', 'process_reorders',
        'get_monthly_sales_summary', 'get_customer_lifetime_value',
        'get_customer_lifetime_value_referrals', 'get_product_performance',
        'create_customer_order', 'get_order_history', 'process_refund',
        'get_customer_summary', 'get_customer_summary_referrals',
        'sync_product_catalog', 'search_products_dynamic', 'calculate_shipping',
        -- examples/
        'create_order', 'process_pending_orders', 'upsert_customer', 'search_orders'];
    v_missing TEXT;
BEGIN
    SELECT string_agg(e, ', ') INTO v_missing
    FROM   unnest(v_expected) e
    WHERE  to_regproc('public.' || e) IS NULL;
    PERFORM test_assert_true('catalog', 'TC-CAT-01 all 19 converted routines exist [H8]',
                             v_missing IS NULL, 'missing: ' || v_missing);
    -- Duplicate names, volatility, leftover T-SQL syntax: see suite static_checks
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error('catalog', SQLERRM);
END;
$$;


-- ============================================================
-- READ-ONLY SUITES
-- ============================================================

-- get_low_stock_alerts (generated/manage_inventory.sql)
\echo '--- get_low_stock_alerts'
DO $$
DECLARE
    s TEXT := 'get_low_stock_alerts';
    v_row RECORD;
BEGIN
    PERFORM test_assert_equal(s, 'TC-LO-01 three low-stock rows',
        (SELECT COUNT(*) FROM public.get_low_stock_alerts()), 3::BIGINT);
    PERFORM test_assert_equal(s, 'TC-LO-02 largest shortfall first (BW-003)',
        (SELECT a.sku FROM public.get_low_stock_alerts() a LIMIT 1), 'BW-003'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-LO-03 well-stocked WP-001 excluded',
        (SELECT COUNT(*) FROM public.get_low_stock_alerts() a WHERE a.sku = 'WP-001'), 0::BIGINT);
    PERFORM test_assert_equal(s, 'TC-LO-04 inactive DI-999 excluded',
        (SELECT COUNT(*) FROM public.get_low_stock_alerts() a WHERE a.sku = 'DI-999'), 0::BIGINT);

    SELECT * INTO v_row FROM public.get_low_stock_alerts() a WHERE a.sku = 'GP-002';
    PERFORM test_assert_equal(s, 'TC-LO-05 shortfall = reorder_point - stock', v_row.shortfall_qty, 2);
    PERFORM test_assert_equal(s, 'TC-LO-06 DATEDIFF(day) → days_since_restock', v_row.days_since_restock, 60);
    PERFORM test_assert_equal(s, 'TC-LO-07 CONVERT(..., 101) → MM/DD/YYYY',
        v_row.last_restocked_formatted, TO_CHAR(CURRENT_DATE - 60, 'MM/DD/YYYY'));

    PERFORM test_assert_equal(s, 'TC-LO-08 warehouse filter (2) → none',
        (SELECT COUNT(*) FROM public.get_low_stock_alerts(p_warehouse_id => 2)), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- get_monthly_sales_summary (generated/sales_reporting.sql)
\echo '--- get_monthly_sales_summary'
DO $$
DECLARE
    s TEXT := 'get_monthly_sales_summary';
    v_row RECORD;
BEGIN
    PERFORM test_assert_equal(s, 'TC-MS-01 June 2025 → 4 product rows',
        (SELECT COUNT(*) FROM public.get_monthly_sales_summary(2025, 6)), 4::BIGINT);

    SELECT * INTO v_row FROM public.get_monthly_sales_summary(2025, 6) LIMIT 1;
    PERFORM test_assert_equal(s, 'TC-MS-02 first row = top category leader', v_row.product_name, 'Premium Gadget'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-MS-03 category_revenue window SUM', v_row.category_revenue, 149.98::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-MS-04 cancelled order excluded (units = 1)', v_row.units_sold, 1::BIGINT);

    SELECT * INTO v_row FROM public.get_monthly_sales_summary(2025, 6) m WHERE m.product_name = 'Budget Widget';
    PERFORM test_assert_equal(s, 'TC-MS-05 RANK within category', v_row.rank_in_category, 2::BIGINT);
    PERFORM test_assert_equal(s, 'TC-MS-06 units_sold', v_row.units_sold, 3::BIGINT);

    SELECT * INTO v_row FROM public.get_monthly_sales_summary(2025, 6) m WHERE m.product_name = 'Widget Pro';
    PERFORM test_assert_equal(s, 'TC-MS-07 AVG(money) cast back to 4 decimals', scale(v_row.avg_selling_price), 4);

    -- Preserved source behaviour: EOMONTH end bound is 00:00 on June 30
    PERFORM test_assert_equal(s, 'TC-MS-08 order at 18:45 on the last day excluded (source parity) [H1] [P10]',
        (SELECT m.units_sold FROM public.get_monthly_sales_summary(2026, 6) m WHERE m.product_name = 'Widget Pro'), 2::BIGINT);
    PERFORM test_assert_equal(s, 'TC-MS-09 order at 00:00 on the last day included',
        (SELECT m.units_sold FROM public.get_monthly_sales_summary(2026, 6) m WHERE m.product_name = 'Budget Widget'), 4::BIGINT);
    PERFORM test_assert_equal(s, 'TC-MS-10 month with no orders → empty',
        (SELECT COUNT(*) FROM public.get_monthly_sales_summary(2020, 1)), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- get_customer_lifetime_value + _referrals (generated/sales_reporting.sql)
\echo '--- get_customer_lifetime_value'
DO $$
DECLARE
    s TEXT := 'get_customer_lifetime_value';
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.get_customer_lifetime_value(1);
    PERFORM test_assert_equal(s, 'TC-LTV-01 customer_name', v_row.customer_name, 'Alice Smith');
    PERFORM test_assert_equal(s, 'TC-LTV-02 lifetime_revenue (non-cancelled)', v_row.lifetime_revenue, 4299.99::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-LTV-03 total_orders', v_row.total_orders, 3);
    PERFORM test_assert_equal(s, 'TC-LTV-04 avg_order_value rounded like MONEY', v_row.avg_order_value, 1433.33::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-LTV-05 tier', v_row.tier, 'Silver');
    PERFORM test_assert_equal(s, 'TC-LTV-06 FORMAT yyyy-MM-dd', v_row.first_order_date, '2024-03-15');
    PERFORM test_assert_equal(s, 'TC-LTV-07 DATEDIFF(month) counts boundaries [P4]',
        v_row.tenure_months,
        ((EXTRACT(YEAR FROM CURRENT_DATE)::INT - 2024) * 12 + EXTRACT(MONTH FROM CURRENT_DATE)::INT - 3));
    PERFORM test_assert_equal(s, 'TC-LTV-08 unknown customer → no row',
        (SELECT COUNT(*) FROM public.get_customer_lifetime_value(999)), 0::BIGINT);
    PERFORM test_assert_equal(s, 'TC-LTV-09 Bronze tier',
        (SELECT l.tier FROM public.get_customer_lifetime_value(2) l), 'Bronze');
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;

\echo '--- get_customer_lifetime_value_referrals'
DO $$
DECLARE
    s TEXT := 'get_customer_lifetime_value_referrals';
    v_row RECORD;
BEGIN
    PERFORM test_assert_equal(s, 'TC-REF-01 Alice has 3 referrals in the tree',
        (SELECT COUNT(*) FROM public.get_customer_lifetime_value_referrals(1)), 3::BIGINT);
    SELECT * INTO v_row FROM public.get_customer_lifetime_value_referrals(1) LIMIT 1;
    PERFORM test_assert_equal(s, 'TC-REF-02 level 1, highest revenue first', v_row.customer_name, 'Bob Jones');
    PERFORM test_assert_equal(s, 'TC-REF-03 cancelled orders excluded', v_row.referral_revenue, 199.99::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-REF-04 recursion reaches level 2',
        (SELECT r.referral_level FROM public.get_customer_lifetime_value_referrals(1) r
         WHERE r.customer_name = 'Carol Wilson'), 2);
    PERFORM test_assert_equal(s, 'TC-REF-05 leaf customer → empty',
        (SELECT COUNT(*) FROM public.get_customer_lifetime_value_referrals(3)), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- get_product_performance (generated/sales_reporting.sql)
\echo '--- get_product_performance'
DO $$
DECLARE
    s TEXT := 'get_product_performance';
BEGIN
    PERFORM test_assert_equal(s, 'TC-PP-01 month grouping: 4 products in June 2025',
        (SELECT COUNT(*) FROM public.get_product_performance('2025-06-01', '2025-06-30', 'month')), 4::BIGINT);
    PERFORM test_assert_equal(s, 'TC-PP-02 month period_start',
        (SELECT MIN(p.period_start) FROM public.get_product_performance('2025-06-01', '2025-06-30', 'month') p),
        '2025-06-01'::DATE);
    PERFORM test_assert_equal(s, 'TC-PP-03 quarter period_start',
        (SELECT MAX(p.period_start) FROM public.get_product_performance('2025-06-01', '2025-06-30', 'quarter') p),
        '2025-04-01'::DATE);
    PERFORM test_assert_equal(s, 'TC-PP-04 week: Tuesday → that Monday',
        (SELECT p.period_start FROM public.get_product_performance('2025-06-01', '2025-06-30', 'week') p
         WHERE p.product_name = 'Gadget Plus'), '2025-06-09'::DATE);
    PERFORM test_assert_equal(s, 'TC-PP-05 week: Sunday → FOLLOWING Monday (SQL Server parity) [P11]',
        (SELECT p.period_start FROM public.get_product_performance('2025-06-01', '2025-06-30', 'week') p
         WHERE p.product_name = 'Premium Gadget'), '2025-06-23'::DATE);
    PERFORM test_assert_equal(s, 'TC-PP-06 cancelled order excluded',
        (SELECT p.units_sold FROM public.get_product_performance('2025-06-01', '2025-06-30', 'month') p
         WHERE p.product_name = 'Premium Gadget'), 1::BIGINT);
    PERFORM test_assert_equal(s, 'TC-PP-07 revenue DESC within period',
        (SELECT p.product_name FROM public.get_product_performance('2025-06-01', '2025-06-30', 'month') p LIMIT 1),
        'Premium Gadget'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-PP-08 DATE end bound excludes later that day (source parity)',
        (SELECT p.units_sold FROM public.get_product_performance('2026-06-01', '2026-06-30', 'month') p
         WHERE p.product_name = 'Widget Pro'), 2::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- get_order_history (generated/customer_orders.sql)
\echo '--- get_order_history'
DO $$
DECLARE
    s TEXT := 'get_order_history';
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.get_order_history(p_date_from => '2025-01-01', p_date_to => '2026-12-31') LIMIT 1;
    PERFORM test_assert_equal(s, 'TC-OH-01 COUNT(*) OVER () total', v_row.total_count, 7::BIGINT);
    PERFORM test_assert_equal(s, 'TC-OH-02 newest first', v_row.order_id, 3);
    PERFORM test_assert_equal(s, 'TC-OH-03 ROW_NUMBER starts at 1', v_row.row_num, 1::BIGINT);

    SELECT * INTO v_row FROM public.get_order_history(p_date_from => '2025-01-01', p_date_to => '2026-12-31') h
    WHERE h.order_id = 2;
    PERFORM test_assert_equal(s, 'TC-OH-04 value tier', v_row.value_tier, 'High Value');
    PERFORM test_assert_equal(s, 'TC-OH-05 REPLICATE → REPEAT', v_row.star_rating, '★★★');
    PERFORM test_assert_equal(s, 'TC-OH-06 CONVERT(EOMONTH, 101)', v_row.month_end, '06/30/2025');
    PERFORM test_assert_equal(s, 'TC-OH-07 FORMAT MMM d, yyyy', v_row.order_date_display, 'Jun 10, 2025');
    PERFORM test_assert_equal(s, 'TC-OH-08 DATEDIFF(day)', v_row.days_ago, (CURRENT_DATE - DATE '2025-06-10'));

    PERFORM test_assert_equal(s, 'TC-OH-09 LIKE → ILIKE (case-insensitive search) [P2]',
        (SELECT COUNT(*) FROM public.get_order_history(p_date_from => '2025-01-01', p_date_to => '2026-12-31',
                                                       p_search_text => 'CAROL')), 1::BIGINT);
    PERFORM test_assert_equal(s, 'TC-OH-10 OFFSET/FETCH → LIMIT/OFFSET (page 2 starts at row 4)',
        (SELECT MIN(h.row_num) FROM public.get_order_history(p_date_from => '2025-01-01', p_date_to => '2026-12-31',
                                                             p_page_number => 2, p_page_size => 3) h), 4::BIGINT);
    PERFORM test_assert_equal(s, 'TC-OH-11 status filter',
        (SELECT COUNT(*) FROM public.get_order_history(p_status_filter => 'Cancelled',
                                                       p_date_from => '2025-01-01', p_date_to => '2026-12-31')), 1::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- get_customer_summary + _referrals (generated/customer_orders.sql)
\echo '--- get_customer_summary'
DO $$
DECLARE
    s TEXT := 'get_customer_summary';
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.get_customer_summary(1);
    PERFORM test_assert_equal(s, 'TC-CS-01 masked email', v_row.masked_email, 'a****@example.com');
    PERFORM test_assert_equal(s, 'TC-CS-02 DATEDIFF(year) = year difference [P4]',
        v_row.age, EXTRACT(YEAR FROM CURRENT_DATE)::INT - 1990);
    PERFORM test_assert_equal(s, 'TC-CS-03 order_count', v_row.order_count, 3);
    PERFORM test_assert_equal(s, 'TC-CS-04 tier', v_row.tier, 'Silver'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-CS-05 CONVERT(VARCHAR(10), ..., 120) keeps date only [P6]',
        v_row.estimated_next_order, '2026-07-30');

    SELECT * INTO v_row FROM public.get_customer_summary(4);
    PERFORM test_assert_equal(s, 'TC-CS-06 year boundaries, not true age (born Dec 31)',
        v_row.age, EXTRACT(YEAR FROM CURRENT_DATE)::INT - 1999);

    SELECT * INTO v_row FROM public.get_customer_summary(3);
    PERFORM test_assert_equal(s, 'TC-CS-07 NULL birth date → NULL age', v_row.age, NULL::INTEGER);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;

\echo '--- get_customer_summary_referrals'
DO $$
DECLARE
    s TEXT := 'get_customer_summary_referrals';
    v_row RECORD;
BEGIN
    PERFORM test_assert_equal(s, 'TC-CSR-01 three referrals',
        (SELECT COUNT(*) FROM public.get_customer_summary_referrals(1)), 3::BIGINT);
    SELECT * INTO v_row FROM public.get_customer_summary_referrals(1) LIMIT 1;
    PERFORM test_assert_equal(s, 'TC-CSR-02 first row', v_row.name, 'Bob Jones');
    PERFORM test_assert_equal(s, 'TC-CSR-03 level', v_row.level, 1);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- search_products_dynamic (generated/customer_orders.sql)
\echo '--- search_products_dynamic'
DO $$
DECLARE
    s TEXT := 'search_products_dynamic';
BEGIN
    PERFORM test_assert_equal(s, 'TC-SP-01 active products only',
        (SELECT COUNT(*) FROM public.search_products_dynamic()), 4::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SP-02 default sort = price ASC',
        (SELECT p.product_name FROM public.search_products_dynamic() p LIMIT 1), 'Budget Widget'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-SP-03 category filter',
        (SELECT COUNT(*) FROM public.search_products_dynamic(p_category => 'Widgets')), 2::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SP-04 legacy sort name + lower-case direction',
        (SELECT p.product_name FROM public.search_products_dynamic(p_sort_column => 'ProductName', p_sort_dir => 'desc') p LIMIT 1),
        'Widget Pro'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-SP-05 search is case-insensitive',
        (SELECT COUNT(*) FROM public.search_products_dynamic(p_search_text => 'widget')), 2::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SP-06 CHARINDEX position',
        (SELECT p.match_position FROM public.search_products_dynamic(p_search_text => 'widget') p
         WHERE p.sku = 'BW-003'), 8);
    PERFORM test_assert_equal(s, 'TC-SP-07 CHARINDEX('''', x) = 0 when no search text',
        (SELECT MAX(p.match_position) FROM public.search_products_dynamic() p), 0);
    PERFORM test_assert_equal(s, 'TC-SP-08 price range',
        (SELECT COUNT(*) FROM public.search_products_dynamic(p_min_price => 20, p_max_price => 60)), 2::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SP-09 paging',
        (SELECT COUNT(*) FROM public.search_products_dynamic(p_page => 2, p_page_size => 3)), 1::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SP-10 injection in sort column falls back to price [H14]',
        (SELECT COUNT(*) FROM public.search_products_dynamic(p_sort_column => 'price; DROP TABLE public.orders')), 4::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SP-11 DATEDIFF(day) age',
        (SELECT MAX(p.age_days) FROM public.search_products_dynamic() p), 100);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- calculate_shipping (generated/customer_orders.sql)
\echo '--- calculate_shipping'
DO $$
DECLARE
    s TEXT := 'calculate_shipping';
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.calculate_shipping(6, '10001', FALSE);
    PERFORM test_assert_equal(s, 'TC-SH-01 weight = SUM(weight × qty)', v_row.total_weight_lbs, 5.000::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-SH-02 free over threshold', v_row.shipping_cost, 0::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-SH-03 standard delivery +5 days', v_row.estimated_delivery, CURRENT_DATE + 5);
    PERFORM test_assert_true (s, 'TC-SH-04 NEWID() → 32 hex chars', v_row.tracking_number ~ '^[0-9a-f]{32}$', v_row.tracking_number);
    PERFORM test_assert_true (s, 'TC-SH-05 FORMAT yyyy-MM-ddTHH:mm:ss',
        v_row.calculated_at ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$', v_row.calculated_at);

    SELECT * INTO v_row FROM public.calculate_shipping(7, '90210', TRUE);
    PERFORM test_assert_equal(s, 'TC-SH-06 west-coast expedited = 4.35 × 1.5', v_row.shipping_cost, 6.525::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-SH-07 expedited delivery +1 day', v_row.estimated_delivery, CURRENT_DATE + 1);
    PERFORM test_assert_equal(s, 'TC-SH-08 northeast standard',
        (SELECT c.shipping_cost FROM public.calculate_shipping(7, '10001') c), 2.55::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-SH-09 supplied tracking ref, dashes removed',
        (SELECT c.tracking_number FROM public.calculate_shipping(7, '10001', FALSE,
                                   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11') c),
        'a0eebc999c0b4ef8bb6d6bb9bd380a11');
    PERFORM test_assert_raises(s, 'TC-SH-10 unknown order raises',
        'SELECT * FROM public.calculate_shipping(999, ''10001'')', 'Order 999 not found.');
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- search_orders (examples/converted_example.sql)
\echo '--- search_orders'
DO $$
DECLARE
    s TEXT := 'search_orders';
BEGIN
    PERFORM test_assert_equal(s, 'TC-SO-01 status filter',
        (SELECT COUNT(*) FROM public.search_orders(p_status => 'Processed',
                                                   p_date_from => '2025-01-01', p_date_to => '2026-12-31')), 2::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SO-02 newest first',
        (SELECT o.order_id FROM public.search_orders(p_status => 'Processed',
                                                     p_date_from => '2025-01-01', p_date_to => '2026-12-31') o LIMIT 1), 5);
    PERFORM test_assert_equal(s, 'TC-SO-03 case-insensitive search',
        (SELECT COUNT(*) FROM public.search_orders(p_search_text => 'ALI',
                                                   p_date_from => '2025-01-01', p_date_to => '2026-12-31')), 2::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SO-04 FORMAT yyyy-MM-dd',
        (SELECT o.order_date FROM public.search_orders(p_customer_id => 1,
                                                       p_date_from => '2025-06-01', p_date_to => '2025-06-30') o),
        '2025-06-10');
    PERFORM test_assert_equal(s, 'TC-SO-05 page size',
        (SELECT COUNT(*) FROM public.search_orders(p_date_from => '2025-01-01', p_date_to => '2026-12-31',
                                                   p_page_size => 2)), 2::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- ============================================================
-- SUITES THAT CHANGE DATA
-- ============================================================

-- adjust_stock (generated/manage_inventory.sql)
\echo '--- adjust_stock'
DO $$
DECLARE
    s TEXT := 'adjust_stock';
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.adjust_stock(2, 1, 10, 'Cycle count', 'tester');
    PERFORM test_assert_equal(s, 'TC-AS-01 previous stock', v_row.previous_stock, 3);
    PERFORM test_assert_equal(s, 'TC-AS-02 new stock', v_row.new_stock, 13);
    PERFORM test_assert_true (s, 'TC-AS-03 SCOPE_IDENTITY → RETURNING audit_id', v_row.adjustment_id IS NOT NULL);
    PERFORM test_assert_equal(s, 'TC-AS-04 audit row written',
        (SELECT a.new_qty FROM public.inventory_audit a WHERE a.audit_id = v_row.adjustment_id), 13);

    PERFORM test_assert_raises(s, 'TC-AS-05 over-withdrawal raises the source message',
        'SELECT * FROM public.adjust_stock(2, 1, -100, ''Oops'', ''tester'')',
        'Insufficient stock. Current: 13, Requested: 100');
    PERFORM test_assert_equal(s, 'TC-AS-06 failed call rolled back [H9]',
        (SELECT i.quantity_on_hand FROM public.inventory i WHERE i.product_id = 2 AND i.warehouse_id = 1), 13);

    SELECT * INTO v_row FROM public.adjust_stock(5, 2, 5, 'First stock', 'tester');
    PERFORM test_assert_equal(s, 'TC-AS-07 missing inventory row initialised at 0', v_row.previous_stock, 0);

    PERFORM public.adjust_stock(2, 1, -10, 'Restore', 'tester');   -- back to 3 for later suites
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- process_reorders (generated/manage_inventory.sql)
\echo '--- process_reorders'
DO $$
DECLARE
    s TEXT := 'process_reorders';
    v_row RECORD;
BEGIN
    PERFORM test_assert_equal(s, 'TC-RO-01 one PO per low-stock product',
        (SELECT COUNT(*) FROM public.process_reorders('test_user', 50)), 3::BIGINT);
    SELECT * INTO v_row FROM public.purchase_orders po WHERE po.product_id = 5;
    PERFORM test_assert_equal(s, 'TC-RO-02 reorder_quantity used', v_row.quantity, 25);
    PERFORM test_assert_equal(s, 'TC-RO-03 Draft status', v_row.status, 'Draft'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-RO-04 created_by', v_row.created_by, 'test_user'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-RO-05 open POs block duplicates',
        (SELECT COUNT(*) FROM public.process_reorders('test_user', 50)), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- create_customer_order (generated/customer_orders.sql)
\echo '--- create_customer_order'
DO $$
DECLARE
    s TEXT := 'create_customer_order';
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.create_customer_order(3, 1, 2::SMALLINT, 'Gift', 'SAVE10');
    PERFORM test_assert_equal(s, 'TC-CO-01 10% coupon applied', v_row.total_amount, 53.982::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-CO-02 discount recorded', v_row.discount_pct, 10.00::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-CO-03 customer name joined', v_row.customer_name, 'Carol Wilson');
    PERFORM test_assert_true (s, 'TC-CO-04 FORMAT yyyy-MM-dd HH:mm:ss',
        v_row.created_at_formatted ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$', v_row.created_at_formatted);
    PERFORM test_assert_equal(s, 'TC-CO-05 line_total stored',
        (SELECT ol.line_total FROM public.order_lines ol WHERE ol.order_id = v_row.order_id), 53.982::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-CO-06 coupon use_count incremented',
        (SELECT c.use_count FROM public.coupons c WHERE c.code = 'SAVE10'), 1);

    -- Source parity: an expired/unknown coupon is silently ignored (flagged TODO in the code)
    SELECT * INTO v_row FROM public.create_customer_order(4, 2, 1::SMALLINT, NULL, 'OLD5');
    PERFORM test_assert_equal(s, 'TC-CO-07 expired coupon → full price (source parity) [H1] [P1]', v_row.total_amount, 49.99::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-CO-08 expired coupon → 0 discount', v_row.discount_pct, 0::NUMERIC);
    SELECT * INTO v_row FROM public.create_customer_order(1, 4, 1::SMALLINT, NULL, 'NOPE');
    PERFORM test_assert_equal(s, 'TC-CO-09 unknown coupon → full price (source parity)', v_row.total_amount, 9.99::NUMERIC);

    PERFORM test_assert_raises(s, 'TC-CO-10 inactive product raises',
        'SELECT * FROM public.create_customer_order(1, 3, 1::SMALLINT)', 'Product 3 is not available.');
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- process_refund (generated/customer_orders.sql)
\echo '--- process_refund'
DO $$
DECLARE
    s TEXT := 'process_refund';
    v_row RECORD;
    v_wp_before INTEGER;
    v_gp_before INTEGER;
BEGIN
    SELECT i.quantity_on_hand INTO v_wp_before FROM public.inventory i WHERE i.product_id = 1 AND i.warehouse_id = 1;
    SELECT i.quantity_on_hand INTO v_gp_before FROM public.inventory i WHERE i.product_id = 2 AND i.warehouse_id = 1;

    SELECT * INTO v_row FROM public.process_refund(6, 'Damaged in transit', 'agent_7');
    PERFORM test_assert_equal(s, 'TC-RF-01 refund amount = order total', v_row.refund_amount, 120.00::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-RF-02 status', v_row.status, 'Completed'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-RF-03 order marked Refunded',
        (SELECT o.status FROM public.orders o WHERE o.order_id = 6), 'Refunded'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-RF-04 cursor loop restocked WP-001 × 2',
        (SELECT i.quantity_on_hand FROM public.inventory i WHERE i.product_id = 1 AND i.warehouse_id = 1), v_wp_before + 2);
    PERFORM test_assert_equal(s, 'TC-RF-05 cursor loop restocked GP-002 × 1',
        (SELECT i.quantity_on_hand FROM public.inventory i WHERE i.product_id = 2 AND i.warehouse_id = 1), v_gp_before + 1);
    PERFORM test_assert_equal(s, 'TC-RF-06 refund row Completed',
        (SELECT r.status FROM public.refunds r WHERE r.refund_id = v_row.refund_id), 'Completed'::VARCHAR);

    PERFORM test_assert_raises(s, 'TC-RF-07 second refund rejected',
        'SELECT * FROM public.process_refund(6, ''again'', ''agent_7'')', 'Order 6 is not eligible for refund.');
    PERFORM test_assert_equal(s, 'TC-RF-08 rejected call left no refund row',
        (SELECT COUNT(*) FROM public.refunds r WHERE r.order_id = 6), 1::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- create_order (examples/converted_example.sql)
\echo '--- create_order'
DO $$
DECLARE
    s TEXT := 'create_order';
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.create_order(1, 2, 2::SMALLINT, 'Example order');
    PERFORM test_assert_equal(s, 'TC-EO-01 total = price × qty', v_row.total_amount, 99.98::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-EO-02 order line inserted',
        (SELECT COUNT(*) FROM public.order_lines ol WHERE ol.order_id = v_row.order_id), 1::BIGINT);
    PERFORM test_assert_raises(s, 'TC-EO-03 inactive product raises',
        'SELECT * FROM public.create_order(1, 3, 1::SMALLINT)', 'Product 3 not found or inactive.');
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- upsert_customer (examples/converted_example.sql)
\echo '--- upsert_customer'
DO $$
DECLARE
    s TEXT := 'upsert_customer';
    v_first RECORD;
    v_row   RECORD;
BEGIN
    SELECT * INTO v_first FROM public.upsert_customer(
        'ffffffff-ffff-ffff-ffff-ffffffffffff', 'Test', 'User', 'testuser@example.com', NULL, '1990-01-01');
    PERFORM test_assert_equal(s, 'TC-UC-01 new external_id → INSERT', v_first.action, 'INSERT'::VARCHAR);

    SELECT * INTO v_row FROM public.upsert_customer(
        'ffffffff-ffff-ffff-ffff-ffffffffffff', 'Test', 'Updated', 'testuser@example.com');
    PERFORM test_assert_equal(s, 'TC-UC-02 same external_id → UPDATE', v_row.action, 'UPDATE'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-UC-03 same customer_id', v_row.customer_id, v_first.customer_id);
    PERFORM test_assert_equal(s, 'TC-UC-04 last name updated',
        (SELECT c.last_name FROM public.customers c WHERE c.customer_id = v_row.customer_id), 'Updated'::VARCHAR);
    PERFORM test_assert_equal(s, 'TC-UC-05 birth_date not touched by WHEN MATCHED',
        (SELECT c.birth_date FROM public.customers c WHERE c.customer_id = v_row.customer_id), '1990-01-01'::DATE);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- process_pending_orders (examples/converted_example.sql)
-- A PROCEDURE that COMMITs must be CALLed at top level (not inside a block
-- with an exception handler), so the CALL runs outside a DO block.
\echo '--- process_pending_orders'
\set ON_ERROR_STOP off
CALL public.process_pending_orders(100);
\if :ERROR
    SELECT public.test_record('process_pending_orders', 'CALL process_pending_orders(100)', 'ERROR', :'LAST_ERROR_MESSAGE');
\endif
CALL public.process_pending_orders(100);    -- nothing left: must just notice and return
\if :ERROR
    SELECT public.test_record('process_pending_orders', 'second CALL with no pending orders', 'ERROR', :'LAST_ERROR_MESSAGE');
\endif
\set ON_ERROR_STOP on
DO $$
DECLARE
    s TEXT := 'process_pending_orders';
BEGIN
    PERFORM test_assert_equal(s, 'TC-PPO-01 no Pending orders left',
        (SELECT COUNT(*) FROM public.orders o WHERE o.status = 'Pending'), 0::BIGINT);
    PERFORM test_assert_equal(s, 'TC-PPO-02 > 1000 flagged for approval',
        (SELECT o.requires_approval FROM public.orders o WHERE o.order_id = 8), TRUE);
    PERFORM test_assert_equal(s, 'TC-PPO-03 small order not flagged',
        (SELECT o.requires_approval FROM public.orders o WHERE o.order_id = 3), FALSE);
    PERFORM test_assert_true (s, 'TC-PPO-04 processed_at stamped',
        (SELECT o.processed_at IS NOT NULL FROM public.orders o WHERE o.order_id = 8));
    PERFORM test_assert_equal(s, 'TC-PPO-05 no processing errors logged',
        (SELECT COUNT(*) FROM public.processing_errors), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;


-- sync_product_catalog (generated/customer_orders.sql) — LAST: it deactivates
-- every product that is not in the staging window.
\echo '--- sync_product_catalog'
DO $$
DECLARE
    s TEXT := 'sync_product_catalog';
    v_expected_updates INTEGER;
    v_row RECORD;
BEGIN
    INSERT INTO public.product_staging (sku, product_name, price, category_id, is_active, effective_date, expires_date) VALUES
        ('WP-001', 'Widget Pro',     31.99,  1,    TRUE,  '2026-01-01', NULL),          -- price change → UPDATE
        ('GP-002', 'Gadget Plus',    49.99,  2,    TRUE,  '2026-01-01', NULL),          -- identical → no action
        ('BW-003', 'Budget Widget',   9.99,  1,    FALSE, '2026-01-01', NULL),          -- matched + inactive → UPDATE
        ('NW-005', 'New Widget',     19.99,  1,    TRUE,  '2026-01-01', NULL),          -- new → INSERT
        ('XX-006', 'Ghost',           5.00,  NULL, FALSE, '2026-01-01', NULL),          -- new but inactive → nothing
        ('PG-004', 'Premium Gadget', 99.99,  2,    TRUE,  '2026-01-01', '2026-01-02');  -- expired → NOT MATCHED BY SOURCE

    -- WP-001 + BW-003, plus every product whose SKU is outside the staging window
    SELECT 2 + COUNT(*) INTO v_expected_updates
    FROM   public.products p
    WHERE  p.sku NOT IN ('WP-001', 'GP-002', 'BW-003', 'NW-005', 'XX-006');

    CREATE TEMP TABLE tmp_sync_result ON COMMIT DROP AS
        SELECT * FROM public.sync_product_catalog('2026-09-10');

    SELECT * INTO v_row FROM tmp_sync_result r WHERE r.action = 'INSERT';
    PERFORM test_assert_equal(s, 'TC-SY-01 one INSERT', v_row.count, 1);
    SELECT * INTO v_row FROM tmp_sync_result r WHERE r.action = 'UPDATE';
    PERFORM test_assert_equal(s, 'TC-SY-02 UPDATE count incl. NOT MATCHED BY SOURCE [CC-77]', v_row.updated, v_expected_updates);
    PERFORM test_assert_equal(s, 'TC-SY-03 $action never DELETE here',
        (SELECT SUM(r.deleted) FROM tmp_sync_result r), 0::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SY-04 result ordered by action',
        (SELECT r.action FROM tmp_sync_result r LIMIT 1), 'INSERT'::VARCHAR);

    PERFORM test_assert_equal(s, 'TC-SY-05 price updated',
        (SELECT p.price FROM public.products p WHERE p.sku = 'WP-001'), 31.99::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-SY-06 matched + inactive → deactivated',
        (SELECT p.is_active FROM public.products p WHERE p.sku = 'BW-003'), FALSE);
    PERFORM test_assert_equal(s, 'TC-SY-07 NOT MATCHED BY SOURCE → deactivated',
        (SELECT p.is_active FROM public.products p WHERE p.sku = 'PG-004'), FALSE);
    PERFORM test_assert_equal(s, 'TC-SY-08 inserted with category',
        (SELECT p.category_id FROM public.products p WHERE p.sku = 'NW-005' AND p.is_active), 1);
    PERFORM test_assert_equal(s, 'TC-SY-09 inactive new row not inserted',
        (SELECT COUNT(*) FROM public.products p WHERE p.sku = 'XX-006'), 0::BIGINT);
    PERFORM test_assert_equal(s, 'TC-SY-10 identical row left alone',
        (SELECT p.price FROM public.products p WHERE p.sku = 'GP-002'), 49.99::NUMERIC);
    PERFORM test_assert_equal(s, 'TC-SY-11 second run inserts nothing',
        (SELECT COUNT(*) FROM public.sync_product_catalog('2026-09-10') r WHERE r.action = 'INSERT'), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END;
$$;
