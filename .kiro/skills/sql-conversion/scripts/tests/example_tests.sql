-- ============================================================
-- sql-conversion skill — tests for the worked examples
-- (references/examples/NN_*.postgres.sql) against the sample schema and
-- scripts/fixtures/sample_seed.sql. Read-only suites first, then suites
-- that change data. Tags: [Hn] hard rule, [Pn] parity rule, [CC-nn] corner case.
-- ============================================================

\echo '--- examples: catalog'
DO $$
DECLARE
    s TEXT := 'examples_catalog';
    v_expected TEXT[] := ARRAY[
        'upsert_product', 'recalc_order_totals', 'generate_monthly_invoices', 'dynamic_search',
        'apply_price_list', 'bulk_update_prices', 'get_org_chart', 'format_customer_report',
        'transfer_stock', 'business_days_between', 'get_customer_dashboard',
        'get_customer_dashboard_orders', 'sync_category_prices', 'get_discounted_price',
        'import_staged_prices', 'get_order_stats', 'top_customers', 'trg_orders_status_audit_fn'];
    v_missing TEXT;
BEGIN
    SELECT string_agg(e, ', ') INTO v_missing FROM unnest(v_expected) e
    WHERE  to_regproc('public.' || e) IS NULL;
    PERFORM test_assert_true(s, 'EX-CAT-01 all 18 example routines loaded', v_missing IS NULL, 'missing: ' || v_missing);
    PERFORM test_assert_true(s, 'EX-CAT-02 statement trigger with transition tables exists [CC-86]',
        EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname = 'trg_orders_status_audit'
                AND t.tgoldtable = 'deleted' AND t.tgnewtable = 'inserted'));
    PERFORM test_assert_true(s, 'EX-CAT-03 preserved source bug carries a TODO flag [H1] [H16]',
        (SELECT prosrc FROM pg_proc WHERE oid = 'public.get_discounted_price'::regproc)
            LIKE '%TODO: MANUAL REVIEW REQUIRED%');
    PERFORM test_assert_equal(s, 'EX-CAT-04 inline TVF converted to LANGUAGE sql [CC-85]',
        (SELECT l.lanname::TEXT FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
         WHERE p.oid = 'public.top_customers'::regproc), 'sql');
    PERFORM test_assert_equal(s, 'EX-CAT-05 OUTPUT params → INOUT (4 of them incl. return code) [CC-84]',
        (SELECT COUNT(*) FROM pg_proc p, unnest(p.proargmodes) m
         WHERE p.oid = 'public.get_order_stats'::regproc AND m = 'b'), 4::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;


-- ============================================================
-- READ-ONLY
-- ============================================================

\echo '--- 04 dynamic_search'
DO $$
DECLARE s TEXT := 'ex04_dynamic_search';
BEGIN
    PERFORM test_assert_equal(s, 'EX04-01 all customers match',
        (SELECT COUNT(*) FROM public.dynamic_search('customers', 'email', '%@example.com', 'customer_id')), 5::BIGINT);
    PERFORM test_assert_equal(s, 'EX04-02 rows come back as JSONB',
        (SELECT r ->> 'first_name' FROM public.dynamic_search('customers', 'email', '%@example.com', 'customer_id') r LIMIT 1), 'Alice');
    PERFORM test_assert_equal(s, 'EX04-03 OFFSET/FETCH paging',
        (SELECT r ->> 'first_name' FROM public.dynamic_search('customers', 'email', '%', 'customer_id', 2, 2) r LIMIT 1), 'Carol');
    PERFORM test_assert_equal(s, 'EX04-04 LIKE on a non-text column needs ::TEXT',
        (SELECT COUNT(*) FROM public.dynamic_search('orders', 'customer_id', '1', 'order_id')), 3::BIGINT);
    PERFORM test_assert_raises(s, 'EX04-05 injected table name is quoted, never executed [H14] [CC-79]',
        $q$SELECT * FROM public.dynamic_search('customers; DROP TABLE public.orders', 'email', '%', 'customer_id')$q$,
        '%does not exist%');
    PERFORM test_assert_equal(s, 'EX04-06 injected value is bound, not concatenated [H14] [CC-79]',
        (SELECT COUNT(*) FROM public.dynamic_search('customers', 'email', $v$' OR 1=1 --$v$, 'customer_id')), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 07 get_org_chart'
DO $$
DECLARE s TEXT := 'ex07_get_org_chart';
BEGIN
    PERFORM test_assert_equal(s, 'EX07-01 whole tree', (SELECT COUNT(*) FROM public.get_org_chart(1)), 4::BIGINT);
    PERFORM test_assert_equal(s, 'EX07-02 root first', (SELECT o.employee_name FROM public.get_org_chart(1) o LIMIT 1), 'Ada'::VARCHAR);
    PERFORM test_assert_equal(s, 'EX07-03 REPLICATE indent at level 2',
        (SELECT o.indented_name FROM public.get_org_chart(1) o WHERE o.level = 2), '    Cy');
    PERFORM test_assert_equal(s, 'EX07-04 depth guard honoured [CC-76]', (SELECT COUNT(*) FROM public.get_org_chart(1, 1)), 3::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 08 format_customer_report'
DO $$
DECLARE s TEXT := 'ex08_format_customer_report'; v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.format_customer_report(1);
    PERFORM test_assert_equal(s, 'EX08-01 first name capitalised', v_row.formatted_first_name, 'Alice');
    PERFORM test_assert_equal(s, 'EX08-02 DATEDIFF(year) = year difference [P4] [CC-44]', v_row.age, EXTRACT(YEAR FROM CURRENT_DATE)::INT - 1990);
    PERFORM test_assert_equal(s, 'EX08-03 FORMAT MMM dd, yyyy', v_row.join_date, 'Jan 10, 2024');
    PERFORM test_assert_equal(s, 'EX08-04 CHARINDEX → STRPOS (args swap)', v_row.at_position, 6);
    PERFORM test_assert_equal(s, 'EX08-05 masked phone', v_row.masked_phone, '*******0101');
    PERFORM test_assert_equal(s, 'EX08-06 CONVERT(..., 101) + 30 days', v_row.trial_expiry, TO_CHAR(CURRENT_DATE + 30, 'MM/DD/YYYY'));
    SELECT * INTO v_row FROM public.format_customer_report(5);
    PERFORM test_assert_equal(s, 'EX08-07 lower-case name capitalised', v_row.formatted_first_name, 'Erin');
    PERFORM test_assert_equal(s, 'EX08-08 REPLICATE(n < 0) → NULL [P6] [CC-08]', v_row.masked_phone, NULL::TEXT);
    PERFORM test_assert_equal(s, 'EX08-09 NULL phone → NULL', (SELECT r.masked_phone FROM public.format_customer_report(3) r), NULL::TEXT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 10 business_days_between'
DO $$
DECLARE s TEXT := 'ex10_business_days_between';
BEGIN
    PERFORM test_assert_equal(s, 'EX10-01 Fri → next Fri = 5', public.business_days_between('2026-09-04', '2026-09-11'), 5);
    PERFORM test_assert_equal(s, 'EX10-02 Sat → Mon = 1 (DATEPART weekday, DATEFIRST 7) [P11] [CC-50]',
        public.business_days_between('2026-09-05', '2026-09-07'), 1);
    PERFORM test_assert_equal(s, 'EX10-03 same day = 0', public.business_days_between('2026-09-07', '2026-09-07'), 0);
    PERFORM test_assert_equal(s, 'EX10-04 NULL in → NULL out', public.business_days_between(NULL, '2026-09-07'), NULL::INTEGER);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 11 customer_dashboard (two result sets)'
DO $$
DECLARE s TEXT := 'ex11_customer_dashboard'; v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.get_customer_dashboard(1);
    PERFORM test_assert_equal(s, 'EX11-01 result set 1: profile row [H8] [CC-83]', v_row.customer_name, 'Alice Smith');
    PERFORM test_assert_equal(s, 'EX11-02 COUNT(*) cast to INTEGER [H12]', v_row.order_count, 3);
    PERFORM test_assert_equal(s, 'EX11-03 result set 2 is its own function [H8] [CC-83]',
        (SELECT COUNT(*) FROM public.get_customer_dashboard_orders(1)), 3::BIGINT);
    PERFORM test_assert_equal(s, 'EX11-04 newest order first',
        (SELECT d.order_id FROM public.get_customer_dashboard_orders(1) d LIMIT 1), 3);
    PERFORM test_assert_equal(s, 'EX11-05 unknown customer → empty',
        (SELECT COUNT(*) FROM public.get_customer_dashboard(999)), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 13 discounted_price (SELECT @v semantics)'
DO $$
DECLARE s TEXT := 'ex13_discounted_price'; v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM public.get_discounted_price(1, 'SAVE10');
    PERFORM test_assert_equal(s, 'EX13-01 valid coupon applied', v_row.discount_pct, 10.00::NUMERIC);
    PERFORM test_assert_equal(s, 'EX13-02 CAST(… AS MONEY) → 4 decimals', v_row.final_price, 26.991::NUMERIC);
    PERFORM test_assert_equal(s, 'EX13-03 multi-row SELECT @v keeps the LAST row [P1] [CC-62]', v_row.latest_coupon, 'SAVE10'::VARCHAR);
    SELECT * INTO v_row FROM public.get_discounted_price(1, 'OLD5');
    PERFORM test_assert_equal(s, 'EX13-04 expired coupon: no row keeps @Discount = 0 [P1] [CC-61]', v_row.discount_pct, 0::NUMERIC);
    PERFORM test_assert_equal(s, 'EX13-05 source bug preserved: full price, no error [H1]', v_row.final_price, 29.99::NUMERIC);
    PERFORM test_assert_equal(s, 'EX13-06 no coupon → 0 discount',
        (SELECT d.discount_pct FROM public.get_discounted_price(1) d), 0::NUMERIC);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 15 order_stats (OUTPUT parameters + return code)'
DO $$
DECLARE
    s TEXT := 'ex15_order_stats';
    v_n INTEGER; v_total NUMERIC(19,4); v_avg NUMERIC(19,4); v_rc INTEGER;
BEGIN
    CALL public.get_order_stats(1, v_n, v_total, v_avg, v_rc);
    PERFORM test_assert_equal(s, 'EX15-01 return code 0 [CC-84]', v_rc, 0);
    PERFORM test_assert_equal(s, 'EX15-02 @OrderCount OUTPUT [CC-84]', v_n, 3);
    PERFORM test_assert_equal(s, 'EX15-03 @TotalSpent OUTPUT', v_total, 4299.99::NUMERIC);
    PERFORM test_assert_equal(s, 'EX15-04 MONEY / INT rounded to 4 places', v_avg, 1433.33::NUMERIC);
    v_n := NULL; v_total := NULL; v_avg := NULL; v_rc := NULL;
    CALL public.get_order_stats(999, v_n, v_total, v_avg, v_rc);
    PERFORM test_assert_equal(s, 'EX15-05 RETURN 1 for an unknown customer [CC-84]', v_rc, 1);
    PERFORM test_assert_equal(s, 'EX15-06 early RETURN leaves outputs as passed', v_n, NULL::INTEGER);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 16 top_customers (inline TVF)'
DO $$
DECLARE s TEXT := 'ex16_top_customers';
BEGIN
    PERFORM test_assert_equal(s, 'EX16-01 TOP (1) WITH TIES, no tie → 1 row [CC-40] [CC-85]',
        (SELECT COUNT(*) FROM public.top_customers(1, 1)), 1::BIGINT);
    PERFORM test_assert_equal(s, 'EX16-02 TOP (2) WITH TIES pulls in every tied row [CC-40]',
        (SELECT COUNT(*) FROM public.top_customers(1, 2)), 5::BIGINT);
    PERFORM test_assert_equal(s, 'EX16-03 HAVING filter', (SELECT COUNT(*) FROM public.top_customers(2, 10)), 1::BIGINT);
    PERFORM test_assert_equal(s, 'EX16-04 cancelled orders excluded from the sum',
        (SELECT t.total_spent FROM public.top_customers(1, 10) t WHERE t.customer_id = 2), 199.99::NUMERIC);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;


-- ============================================================
-- SUITES THAT CHANGE DATA
-- ============================================================

\echo '--- 01 upsert_product'
DO $$
DECLARE s TEXT := 'ex01_upsert_product'; v_new RECORD; v_row RECORD;
BEGIN
    SELECT * INTO v_new FROM public.upsert_product(
        p_product_name => 'Mega Widget', p_sku => 'MW-010', p_price => 59.99, p_category_id => 1);
    PERFORM test_assert_true (s, 'EX01-01 SCOPE_IDENTITY → RETURNING the new key [H2]', v_new.product_id IS NOT NULL);
    PERFORM test_assert_equal(s, 'EX01-02 BIT default 1 → TRUE', v_new.is_active, TRUE);
    SELECT * INTO v_row FROM public.upsert_product(v_new.product_id, 'Mega Widget v2', 'MW-010', 64.99, FALSE, 1);
    PERFORM test_assert_equal(s, 'EX01-03 update path via positional call', v_row.product_name, 'Mega Widget v2'::VARCHAR);
    PERFORM test_assert_equal(s, 'EX01-04 price updated', v_row.price, 64.99::NUMERIC);
    PERFORM test_assert_raises(s, 'EX01-05 missing required parameter raises (defaults-ordering rule) [CC-75]',
        'SELECT * FROM public.upsert_product(p_sku => ''X-1'')', 'upsert_product expects%');
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 02 recalc_order_totals'
DO $$
DECLARE s TEXT := 'ex02_recalc_order_totals';
BEGIN
    CALL public.recalc_order_totals('2024-03-15 00:00:00', '2024-03-15 23:59:59');
    PERFORM test_assert_equal(s, 'EX02-01 cursor → FOR loop: total = SUM(qty × price)',
        (SELECT o.total_amount FROM public.orders o WHERE o.order_id = 1), 59.98::NUMERIC);
    PERFORM test_assert_equal(s, 'EX02-02 orders outside the range untouched',
        (SELECT o.total_amount FROM public.orders o WHERE o.order_id = 2), 2500.00::NUMERIC);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 03 generate_monthly_invoices'
DO $$
DECLARE s TEXT := 'ex03_generate_monthly_invoices';
BEGIN
    CALL public.generate_monthly_invoices('2025-06-01');
    PERFORM test_assert_equal(s, 'EX03-01 one invoice per customer', (SELECT COUNT(*) FROM public.invoices), 2::BIGINT);
    PERFORM test_assert_equal(s, 'EX03-02 invoice total = SUM of the month',
        (SELECT i.total_amount FROM public.invoices i WHERE i.customer_id = 2), 289.97::NUMERIC);
    PERFORM test_assert_equal(s, 'EX03-03 OUTPUT INTO + UPDATE FROM linked the orders',
        (SELECT COUNT(*) FROM public.orders o JOIN public.invoices i
           ON i.invoice_id = o.invoice_id AND i.customer_id = o.customer_id), 3::BIGINT);
    CALL public.generate_monthly_invoices('2025-06-01');
    PERFORM test_assert_equal(s, 'EX03-04 re-run: temp table reused, nothing new [H10] [CC-70]',
        (SELECT COUNT(*) FROM public.invoices), 2::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 05 apply_price_list'
DO $$
DECLARE s TEXT := 'ex05_apply_price_list';
BEGIN
    INSERT INTO public.product_staging (sku, product_name, price, category_id, is_active, effective_date) VALUES
        ('WP-001', 'Widget Pro',     32.49, 1,    TRUE,  '2026-10-01'),
        ('NW-777', 'Night Widget',   19.99, 1,    TRUE,  '2026-10-01'),
        ('ZZ-000', 'Inactive Thing',  1.00, NULL, FALSE, '2026-10-01');
    PERFORM test_assert_equal(s, 'EX05-01 @@ROWCOUNT after upsert = inserted + updated [CC-64]',
        (SELECT a.rows_affected FROM public.apply_price_list('2026-10-01') a), 2);
    PERFORM test_assert_equal(s, 'EX05-02 matched row updated', (SELECT p.price FROM public.products p WHERE p.sku = 'WP-001'), 32.49::NUMERIC);
    PERFORM test_assert_equal(s, 'EX05-03 new row inserted', (SELECT COUNT(*) FROM public.products p WHERE p.sku = 'NW-777'), 1::BIGINT);
    PERFORM test_assert_equal(s, 'EX05-04 inactive staging row ignored', (SELECT COUNT(*) FROM public.products p WHERE p.sku = 'ZZ-000'), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 06 bulk_update_prices'
DO $$
DECLARE s TEXT := 'ex06_bulk_update_prices';
BEGIN
    PERFORM test_assert_equal(s, 'EX06-01 active Gadgets updated', (SELECT b.products_updated FROM public.bulk_update_prices(10.00, 2) b), 2);
    PERFORM test_assert_equal(s, 'EX06-02 price × 1.10 at 4 decimals', (SELECT p.price FROM public.products p WHERE p.sku = 'GP-002'), 54.989::NUMERIC);
    PERFORM test_assert_equal(s, 'EX06-03 OUTPUT DELETED.Price → old value via locked CTE [CC-78]',
        (SELECT pa.old_price FROM public.price_audit pa JOIN public.products p USING (product_id) WHERE p.sku = 'GP-002'), 49.99::NUMERIC);
    PERFORM test_assert_equal(s, 'EX06-04 OUTPUT INSERTED.Price → new value [CC-78]',
        (SELECT pa.new_price FROM public.price_audit pa JOIN public.products p USING (product_id) WHERE p.sku = 'PG-004'), 109.989::NUMERIC);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 09 transfer_stock'
DO $$
DECLARE s TEXT := 'ex09_transfer_stock'; v_row RECORD; v_from INTEGER; v_to INTEGER;
BEGIN
    SELECT i.quantity_on_hand INTO v_from FROM public.inventory i WHERE i.product_id = 1 AND i.warehouse_id = 1;
    SELECT i.quantity_on_hand INTO v_to   FROM public.inventory i WHERE i.product_id = 1 AND i.warehouse_id = 2;
    SELECT * INTO v_row FROM public.transfer_stock(1, 2, 1, 5, 'tester');
    PERFORM test_assert_equal(s, 'EX09-01 status OK', v_row.status, 'OK'::VARCHAR);
    PERFORM test_assert_equal(s, 'EX09-02 source decremented',
        (SELECT i.quantity_on_hand FROM public.inventory i WHERE i.product_id = 1 AND i.warehouse_id = 1), v_from - 5);
    PERFORM test_assert_equal(s, 'EX09-03 destination incremented (ON CONFLICT ON CONSTRAINT)',
        (SELECT i.quantity_on_hand FROM public.inventory i WHERE i.product_id = 1 AND i.warehouse_id = 2), v_to + 5);
    PERFORM public.transfer_stock(1, 2, 4, 2, 'tester');
    PERFORM test_assert_equal(s, 'EX09-04 destination row created when missing',
        (SELECT i.quantity_on_hand FROM public.inventory i WHERE i.product_id = 4 AND i.warehouse_id = 2), 2);
    PERFORM test_assert_raises(s, 'EX09-05 THROW 50001 → RAISE EXCEPTION (P0001) [CC-69]',
        'SELECT * FROM public.transfer_stock(1, 2, 5, 999, ''tester'')', 'Insufficient stock or invalid warehouse/product.');
    PERFORM test_assert_equal(s, 'EX09-06 failed call fully rolled back (XACT_ABORT parity) [H9]',
        (SELECT COUNT(*) FROM public.stock_transfers), 2::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

-- 14 is a PROCEDURE that COMMITs and then raises on purpose: it must be
-- CALLed at top level, and its error is the expected outcome.
\echo '--- 14 import_staged_prices (log, continue, commit, re-throw)'
INSERT INTO public.product_staging (sku, product_name, price, category_id, is_active, effective_date) VALUES
    ('WP-001', 'Widget Pro',  33.33, 1, TRUE, '2026-12-01'),
    ('GP-002', 'Gadget Plus',  0.00, 2, TRUE, '2026-12-01'),
    ('NOPE-1', 'Nope',         5.00, 1, TRUE, '2026-12-01');
\set ON_ERROR_STOP off
CALL public.import_staged_prices('2026-12-01');
\if :ERROR
    SELECT public.test_record('ex14_import_staged_prices',
        'EX14-01 final THROW reaches the caller [CC-65] [CC-66]',
        CASE WHEN :'LAST_ERROR_MESSAGE' LIKE 'Some staged prices failed%' THEN 'PASS' ELSE 'FAIL' END,
        :'LAST_ERROR_MESSAGE');
\else
    SELECT public.test_record('ex14_import_staged_prices',
        'EX14-01 final THROW reaches the caller [CC-65] [CC-66]', 'FAIL', 'no error raised');
\endif
\set ON_ERROR_STOP on
DO $$
DECLARE s TEXT := 'ex14_import_staged_prices';
BEGIN
    PERFORM test_assert_equal(s, 'EX14-02 good row committed despite the final error [P9] [CC-65]',
        (SELECT p.price FROM public.products p WHERE p.sku = 'WP-001'), 33.33::NUMERIC);
    PERFORM test_assert_equal(s, 'EX14-03 both failures logged and committed [CC-65] [CC-66]',
        (SELECT COUNT(*) FROM public.processing_errors e
         WHERE e.error_message IN ('GP-002: Price must be positive', 'NOPE-1: Unknown SKU')), 2::BIGINT);
    PERFORM test_assert_equal(s, 'EX14-04 failed row left unchanged',
        (SELECT p.price FROM public.products p WHERE p.sku = 'GP-002'), 54.989::NUMERIC);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 17 order_status_audit trigger'
DO $$
DECLARE s TEXT := 'ex17_order_status_audit'; v_before BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_before FROM public.order_status_audit;
    UPDATE public.orders o SET status = 'Shipped' WHERE o.order_id = 7;
    PERFORM test_assert_equal(s, 'EX17-01 status change audited via transition tables [CC-86]',
        (SELECT COUNT(*) FROM public.order_status_audit a
         WHERE a.order_id = 7 AND a.old_status = 'Completed' AND a.new_status = 'Shipped'), 1::BIGINT);
    UPDATE public.orders o SET total_amount = o.total_amount WHERE o.order_id = 7;
    UPDATE public.orders o SET status = o.status WHERE o.order_id = 1;
    PERFORM test_assert_equal(s, 'EX17-02 no audit row when status is unchanged (IF NOT UPDATE + WHERE)',
        (SELECT COUNT(*) FROM public.order_status_audit) - v_before, 1::BIGINT);
    UPDATE public.orders o SET status = 'Archived' WHERE o.customer_id = 2;
    PERFORM test_assert_equal(s, 'EX17-03 multi-row UPDATE → one audit row per row (statement trigger) [CC-86]',
        (SELECT COUNT(*) FROM public.order_status_audit) - v_before, 3::BIGINT);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- 12 sync_category_prices (PG 17 MERGE)'
DO $$
DECLARE s TEXT := 'ex12_sync_category_prices';
BEGIN
    INSERT INTO public.product_staging (sku, product_name, price, category_id, is_active, effective_date) VALUES
        ('GP-002', 'Gadget Plus', 51.99, 2, TRUE, '2026-11-01'),
        ('GX-100', 'Gadget X',    15.00, 2, TRUE, '2026-11-01');
    CREATE TEMP TABLE ex12_result ON COMMIT DROP AS SELECT * FROM public.sync_category_prices(2, '2026-11-01');
    PERFORM test_assert_equal(s, 'EX12-01 one row per changed product',
        (SELECT COUNT(*) FROM ex12_result), 3::BIGINT);
    PERFORM test_assert_equal(s, 'EX12-02 $action order by SKU',
        (SELECT string_agg(r.action || ':' || r.sku, ',' ORDER BY r.sku) FROM ex12_result r),
        'UPDATE:GP-002,INSERT:GX-100,UPDATE:PG-004');
    PERFORM test_assert_equal(s, 'EX12-03 NOT MATCHED BY SOURCE → UPDATE (deactivated) [CC-77]',
        (SELECT p.is_active FROM public.products p WHERE p.sku = 'PG-004'), FALSE);
    PERFORM test_assert_equal(s, 'EX12-04 other categories untouched by BY SOURCE condition',
        (SELECT p.is_active FROM public.products p WHERE p.sku = 'WP-001'), TRUE);
EXCEPTION WHEN OTHERS THEN
    PERFORM test_error(s, SQLERRM);
END $$;
