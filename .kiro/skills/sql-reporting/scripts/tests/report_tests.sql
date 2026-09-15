-- ============================================================
-- sql-reporting skill — tests
-- Expected values were computed independently in Python from the seed data
-- (sql-conversion sample seed + scripts/fixtures/reporting_seed.sql), never
-- copied from query output. Tags: [RQ-nn] query rules, [RP-nn] patterns
-- (references/patterns.md). Revenue = orders not Cancelled/Refunded.
-- ============================================================

\echo '--- report catalog'
DO $$
DECLARE s TEXT := 'rp_catalog'; v_bad TEXT;
BEGIN
    SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM   pg_proc p JOIN pg_language l ON l.oid = p.prolang
    WHERE  p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'report\_%'
      AND  NOT (l.lanname = 'sql' AND p.provolatile = 's');
    PERFORM test_assert_true(s, 'RQ-21 every report_* function is LANGUAGE sql STABLE [RQ-21]', v_bad IS NULL, 'offenders: ' || v_bad);
    PERFORM test_assert_equal(s, 'RQ-21 all 15 example reports loaded [RQ-21]',
        (SELECT COUNT(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'report\_%'), 15::BIGINT);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-01 revenue by month'
DO $$
DECLARE s TEXT := 'rp01_revenue_by_month'; r RECORD;
BEGIN
    PERFORM test_assert_equal(s, 'RP-01 twelve rows for 2025 incl. the empty July [RP-01] [RQ-05]',
        (SELECT COUNT(*) FROM public.report_revenue_by_month('2025-01-01', '2026-01-01')), 12::BIGINT);
    SELECT * INTO r FROM public.report_revenue_by_month('2025-01-01', '2026-01-01') m WHERE m.period_start = '2025-07-01';
    PERFORM test_assert_equal(s, 'RP-01 empty month → 0 orders, 0 revenue (COALESCE) [RQ-03]', r.order_count * 1000 + r.revenue::INTEGER, 0);
    SELECT * INTO r FROM public.report_revenue_by_month('2025-01-01', '2026-01-01') m WHERE m.period_start = '2025-06-01';
    PERFORM test_assert_equal(s, 'RP-01 June 2025 revenue [RP-01]', r.revenue, 2729.98::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-01 June 2025 order count [RP-01]', r.order_count, 3);
    PERFORM test_assert_equal(s, 'RP-01 2025 total = 4999.37 over 15 orders [RQ-14]',
        (SELECT SUM(m.revenue)::TEXT || '/' || SUM(m.order_count)::TEXT FROM public.report_revenue_by_month('2025-01-01', '2026-01-01') m),
        '4999.3700/15');
    PERFORM test_assert_equal(s, 'RP-01 Dec 31 23:59:59 order counted in December [RQ-05]',
        (SELECT m.revenue FROM public.report_revenue_by_month('2025-12-01', '2026-01-01') m), 589.92::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-01 half-open end: p_to itself is excluded [RQ-05]',
        (SELECT SUM(m.order_count) FROM public.report_revenue_by_month('2025-03-01', '2025-04-01') m), 1::BIGINT);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-02 category revenue'
DO $$
DECLARE s TEXT := 'rp02_category_revenue'; r RECORD;
BEGIN
    SELECT * INTO r FROM public.report_category_revenue('2025-01-01', '2026-01-01') c WHERE c.category = 'Gadgets';
    PERFORM test_assert_equal(s, 'RP-02 Gadgets line revenue [RP-02]', r.revenue, 1849.74::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-02 Gadgets share 73.71% [RQ-04]', r.share_pct, 73.71::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-02 COUNT(DISTINCT order) not lines [RQ-01]', r.order_count, 9);
    PERFORM test_assert_equal(s, 'RP-02 shares sum to 100 [RQ-04]',
        (SELECT SUM(c.share_pct) FROM public.report_category_revenue('2025-01-01', '2026-01-01') c), 100.00::NUMERIC);
    -- The naive way: join orders to lines and SUM(total_amount) → every multi-line order counted twice
    PERFORM test_assert_equal(s, 'RQ-01 naive join fan-out inflates 4999.37 to 8309.10 [RQ-01]',
        (SELECT SUM(o.total_amount) FROM public.orders o JOIN public.order_lines ol ON ol.order_id = o.order_id
         WHERE o.created_at >= '2025-01-01' AND o.created_at < '2026-01-01' AND o.status NOT IN ('Cancelled','Refunded')),
        8309.10::NUMERIC);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-03 running revenue'
DO $$
DECLARE s TEXT := 'rp03_running_revenue'; r RECORD;
BEGIN
    SELECT * INTO r FROM public.report_running_revenue(2025) x WHERE x.period_start = '2025-12-01';
    PERFORM test_assert_equal(s, 'RP-03 running total reaches the year total [RP-03] [RQ-08]', r.running_total, 4999.37::NUMERIC);
    SELECT * INTO r FROM public.report_running_revenue(2025) x WHERE x.period_start = '2025-03-01';
    PERFORM test_assert_equal(s, 'RP-03 3-month average Mar [RP-03]', r.avg_3m, 166.60::NUMERIC);
    SELECT * INTO r FROM public.report_running_revenue(2025) x WHERE x.period_start = '2025-07-01';
    PERFORM test_assert_equal(s, 'RP-03 3-month average includes the gap-filled July zero [RQ-05] [RQ-08]', r.avg_3m, 993.31::NUMERIC);
    SELECT * INTO r FROM public.report_running_revenue(2025) x WHERE x.period_start = '2025-01-01';
    PERFORM test_assert_equal(s, 'RP-03 partial window at the edge = the single month [RQ-08]', r.avg_3m, 299.90::NUMERIC);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-04 growth'
DO $$
DECLARE s TEXT := 'rp04_revenue_growth'; r RECORD;
BEGIN
    SELECT * INTO r FROM public.report_revenue_growth(2025) g WHERE g.period_start = '2025-06-01';
    PERFORM test_assert_equal(s, 'RP-04 June MoM +992.21% [RP-04]', r.mom_pct, 992.21::NUMERIC);
    SELECT * INTO r FROM public.report_revenue_growth(2025) g WHERE g.period_start = '2025-08-01';
    PERFORM test_assert_equal(s, 'RP-04 August prior month is the gap-filled July (0) [RQ-11]', r.prior_month, 0::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-04 growth from 0 is NULL, not an error [RQ-03] [RQ-11]', r.mom_pct, NULL::NUMERIC);
    SELECT * INTO r FROM public.report_revenue_growth(2025) g WHERE g.period_start = '2025-03-01';
    PERFORM test_assert_equal(s, 'RP-04 March YoY vs 1500 in 2024 = -96.67% [RP-04]', r.yoy_pct, -96.67::NUMERIC);
    SELECT * INTO r FROM public.report_revenue_growth(2025) g WHERE g.period_start = '2025-01-01';
    PERFORM test_assert_equal(s, 'RP-04 no prior-year data → NULL YoY [RQ-11]', r.yoy_pct, NULL::NUMERIC);
    -- naive LAG over months that exist only: August's "prior" would be June
    PERFORM test_assert_equal(s, 'RQ-11 naive LAG without gap filling gives June as August''s prior [RQ-11]',
        (SELECT prior FROM (SELECT m, LAG(m) OVER (ORDER BY m) AS prior
                            FROM (SELECT DISTINCT date_trunc('month', o.created_at)::DATE AS m FROM public.orders o
                                  WHERE o.created_at >= '2025-01-01' AND o.created_at < '2026-01-01'
                                    AND o.status NOT IN ('Cancelled','Refunded')) t) x WHERE x.m = '2025-08-01'),
        '2025-06-01'::DATE);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-05 top-N per category'
DO $$
DECLARE s TEXT := 'rp05_top_products';
BEGIN
    PERFORM test_assert_equal(s, 'RP-05 top 1 per category [RP-05]',
        (SELECT string_agg(t.category || ':' || t.sku || '=' || t.units, ',' ORDER BY t.category)
         FROM public.report_top_products_per_category('2025-01-01', '2026-01-01', 1) t),
        'Gadgets:GP-002=15,Widgets:BW-003=30');
    PERFORM test_assert_equal(s, 'RP-05 top 2 per category → 4 rows [RP-05]',
        (SELECT COUNT(*) FROM public.report_top_products_per_category('2025-01-01', '2026-01-01', 2)), 4::BIGINT);
    PERFORM test_assert_equal(s, 'RQ-09 DENSE_RANK keeps both tied rows at rank 1 (RANK would too, ROW_NUMBER not) [RQ-09]',
        (SELECT string_agg(rk::TEXT, ',' ORDER BY k) FROM (SELECT k, DENSE_RANK() OVER (ORDER BY v DESC) rk
              FROM (VALUES ('a', 10), ('b', 10), ('c', 5)) t(k, v)) x), '1,1,2');
    PERFORM test_assert_equal(s, 'RQ-09 RANK leaves a gap after a tie [RQ-09]',
        (SELECT string_agg(rk::TEXT, ',' ORDER BY k) FROM (SELECT k, RANK() OVER (ORDER BY v DESC) rk
              FROM (VALUES ('a', 10), ('b', 10), ('c', 5)) t(k, v)) x), '1,1,3');
    PERFORM test_assert_equal(s, 'RQ-09 FETCH FIRST 1 ROWS WITH TIES returns both tied rows [RQ-09]',
        (SELECT COUNT(*) FROM (SELECT v FROM (VALUES (10), (10), (5)) t(v) ORDER BY v DESC FETCH FIRST 1 ROWS WITH TIES) x), 2::BIGINT);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-06 pareto'
DO $$
DECLARE s TEXT := 'rp06_pareto'; r RECORD;
BEGIN
    SELECT * INTO r FROM public.report_customer_pareto() p WHERE p.rnk = 1;
    PERFORM test_assert_equal(s, 'RP-06 top customer share 62.69% [RP-06]', r.customer_name || ' ' || r.share_pct, 'Alice Smith 62.69');
    SELECT * INTO r FROM public.report_customer_pareto() p WHERE p.rnk = 2;
    PERFORM test_assert_equal(s, 'RP-06 cumulative share after two customers 85.21% [RP-06] [RQ-08]', r.cumulative_share_pct, 85.21::NUMERIC);
    SELECT * INTO r FROM public.report_customer_pareto() p WHERE p.rnk = 5;
    PERFORM test_assert_equal(s, 'RP-06 last cumulative share is 100 [RP-06]', r.cumulative_share_pct, 100.00::NUMERIC);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-07 distribution stats'
DO $$
DECLARE s TEXT := 'rp07_order_value_stats'; r RECORD;
BEGIN
    SELECT * INTO r FROM public.report_order_value_stats('2025-01-01', '2026-01-01');
    PERFORM test_assert_equal(s, 'RP-07 n = 15 [RP-07]', r.order_count, 15);
    PERFORM test_assert_equal(s, 'RP-07 mean 333.29 = SUM/COUNT [RQ-23]', r.avg_order_value, 333.29::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-07 median 159.94 [RQ-10]', r.median_order_value, 159.94::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-07 p90 continuous interpolates → 459.95 [RQ-10]', r.p90_order_value, 459.95::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-07 p90 discrete is a real order value → 499.95 [RQ-10]', r.p90_discrete, 499.95::NUMERIC);
    PERFORM test_assert_equal(s, 'RQ-23 average of monthly averages is 248.59, not the mean [RQ-23]',
        (SELECT ROUND(AVG(a), 2) FROM (SELECT AVG(o.total_amount) a FROM public.orders o
              WHERE o.created_at >= '2025-01-01' AND o.created_at < '2026-01-01' AND o.status NOT IN ('Cancelled','Refunded')
              GROUP BY date_trunc('month', o.created_at)) m), 248.59::NUMERIC);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-08 pivot'
DO $$
DECLARE s TEXT := 'rp08_pivot'; r RECORD;
BEGIN
    SELECT * INTO r FROM public.report_orders_by_month_status(2025) p WHERE p.period_start = '2025-06-01';
    PERFORM test_assert_equal(s, 'RP-08 June: 1 completed, 2 processed, 1 cancelled, total 4 [RP-08] [RQ-12]',
        format('%s/%s/%s/%s', r.completed, r.processed, r.cancelled, r.total), '1/2/1/4');
    SELECT * INTO r FROM public.report_orders_by_month_status(2025) p WHERE p.period_start = '2025-07-01';
    PERFORM test_assert_equal(s, 'RP-08 July: only the refunded order [RP-08]', r.refunded * 10 + r.total, 11);
    PERFORM test_assert_equal(s, 'RP-08 columns reconcile with total in every row [RQ-12]',
        (SELECT COUNT(*) FROM public.report_orders_by_month_status(2025) p
         WHERE p.completed + p.processed + p.pending + p.cancelled + p.refunded + p.other <> p.total), 0::BIGINT);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-09 cohorts'
DO $$
DECLARE s TEXT := 'rp09_cohorts';
BEGIN
    PERFORM test_assert_equal(s, 'RP-09 Carol''s cohort (2025-02) is active in months 0, 6, 7, 16 [RP-09] [RQ-17]',
        (SELECT string_agg(c.months_since::TEXT, ',' ORDER BY c.months_since) FROM public.report_cohort_retention() c
         WHERE c.cohort_month = '2025-02-01'), '0,6,7,16');
    PERFORM test_assert_equal(s, 'RP-09 19 cohort cells in total [RP-09]', (SELECT COUNT(*) FROM public.report_cohort_retention()), 19::BIGINT);
    PERFORM test_assert_equal(s, 'RP-09 Alice''s cohort is 2024-03 (her first revenue order) [RQ-17]',
        (SELECT MIN(c.cohort_month) FROM public.report_cohort_retention() c), '2024-03-01'::DATE);
    PERFORM test_assert_equal(s, 'RP-09 retention_pct uses the cohort size as denominator [RQ-17]',
        (SELECT c.retention_pct FROM public.report_cohort_retention() c WHERE c.cohort_month = '2025-01-01' AND c.months_since = 5), 100.00::NUMERIC);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-10 semi-additive stock'
DO $$
DECLARE s TEXT := 'rp10_stock_as_of';
BEGIN
    PERFORM test_assert_equal(s, 'RP-10 June month-end stock = 50 + 3 [RP-10] [RQ-13]',
        (SELECT SUM(x.quantity_on_hand) FROM public.report_stock_as_of('2025-06-30') x), 53::BIGINT);
    PERFORM test_assert_equal(s, 'RP-10 as of mid-month picks the latest earlier snapshot [RQ-13]',
        (SELECT SUM(x.quantity_on_hand) FROM public.report_stock_as_of('2025-06-16') x), 60::BIGINT);
    PERFORM test_assert_equal(s, 'RQ-13 naive SUM of June snapshots = 153 (wrong) [RQ-13]',
        (SELECT SUM(quantity_on_hand) FROM public.inventory_snapshots WHERE snapshot_date >= '2025-06-01' AND snapshot_date < '2025-07-01'), 153::BIGINT);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-11 funnel'
DO $$
DECLARE s TEXT := 'rp11_funnel';
BEGIN
    PERFORM test_assert_equal(s, 'RP-11 users per step 5,4,3,2 (distinct users, not 7 view events) [RP-11] [RQ-18]',
        (SELECT string_agg(f.users::TEXT, ',' ORDER BY f.step) FROM public.report_funnel('2025-06-01', '2025-07-01') f), '5,4,3,2');
    PERFORM test_assert_equal(s, 'RP-11 step conversion 80/75/66.67 [RP-11]',
        (SELECT string_agg(COALESCE(f.pct_of_previous::TEXT, 'NULL'), ',' ORDER BY f.step) FROM public.report_funnel('2025-06-01', '2025-07-01') f),
        'NULL,80.00,75.00,66.67');
    PERFORM test_assert_equal(s, 'RP-11 overall conversion 40% [RP-11]',
        (SELECT f.pct_of_first FROM public.report_funnel('2025-06-01', '2025-07-01') f WHERE f.step = 4), 40.00::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-11 empty window still lists every step with 0 users [RQ-18] [RQ-03]',
        (SELECT string_agg(f.users::TEXT, ',' ORDER BY f.step) FROM public.report_funnel('2020-01-01', '2020-02-01') f), '0,0,0,0');
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-12 gaps and islands'
DO $$
DECLARE s TEXT := 'rp12_streaks';
BEGIN
    PERFORM test_assert_equal(s, 'RP-12 Alice has 5 activity streaks [RP-12]', (SELECT COUNT(*) FROM public.report_customer_activity_streaks(1)), 5::BIGINT);
    PERFORM test_assert_equal(s, 'RP-12 longest streak May–Jun 2025 (2 months) [RP-12]',
        (SELECT x.streak_start::TEXT || '..' || x.streak_end::TEXT || ':' || x.months FROM public.report_customer_activity_streaks(1) x
         ORDER BY x.months DESC, x.streak_start LIMIT 1), '2025-05-01..2025-06-01:2');
    PERFORM test_assert_equal(s, 'RP-12 December → January counts as consecutive [RP-12] [RQ-05]',
        (SELECT COUNT(DISTINCT g) FROM (SELECT m, (EXTRACT(YEAR FROM m) * 12 + EXTRACT(MONTH FROM m))::INTEGER - ROW_NUMBER() OVER (ORDER BY m) AS g
              FROM (VALUES ('2024-12-01'::DATE), ('2025-01-01'::DATE)) t(m)) x), 1::BIGINT);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-13 rollup'
DO $$
DECLARE s TEXT := 'rp13_rollup';
BEGIN
    PERFORM test_assert_equal(s, 'RP-13 8 detail + 2 category + 1 grand total rows [RP-13]', (SELECT COUNT(*) FROM public.report_revenue_rollup(2025)), 11::BIGINT);
    PERFORM test_assert_equal(s, 'RP-13 Gadgets Q2 [RP-13]',
        (SELECT r.revenue FROM public.report_revenue_rollup(2025) r WHERE r.category = 'Gadgets' AND r.quarter = 2), 799.89::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-13 category subtotal flagged by GROUPING(), not by a NULL check [RQ-15]',
        (SELECT r.revenue FROM public.report_revenue_rollup(2025) r WHERE r.category = 'Gadgets' AND r.is_category_total), 1849.74::NUMERIC);
    PERFORM test_assert_equal(s, 'RP-13 grand total [RP-13]', (SELECT r.revenue FROM public.report_revenue_rollup(2025) r WHERE r.is_grand_total), 2509.32::NUMERIC);
    PERFORM test_assert_equal(s, 'RQ-15 a NULL dimension value is not a subtotal [RQ-15]',
        (SELECT string_agg(COALESCE(k, 'NULL') || ':' || g, ',' ORDER BY g, k) FROM (SELECT k, GROUPING(k) g FROM (VALUES (NULL::TEXT, 1), ('a', 2)) t(k, v)
              GROUP BY ROLLUP (k)) x), 'a:0,NULL:0,NULL:1');
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-14 first/last per group'
DO $$
DECLARE s TEXT := 'rp14_first_last'; r RECORD;
BEGIN
    SELECT * INTO r FROM public.report_customer_first_last_order() f WHERE f.customer_id = 2;
    PERFORM test_assert_equal(s, 'RP-14 Bob first order (cancelled one skipped) [RP-14] [RQ-14]', r.first_order_at::TEXT || ' ' || r.first_amount, '2025-01-20 17:40:00 199.9600');
    PERFORM test_assert_equal(s, 'RP-14 Bob last order (refunded one skipped) [RP-14]', r.last_order_at::TEXT || ' ' || r.last_amount, '2025-06-30 18:30:00 29.9900');
    PERFORM test_assert_equal(s, 'RQ-16 tie-breaker makes DISTINCT ON deterministic [RQ-16]',
        (SELECT id FROM (SELECT DISTINCT ON (g) g, id FROM (VALUES (1, 7, '2025-01-01'::TIMESTAMP), (1, 3, '2025-01-01'::TIMESTAMP)) t(g, id, ts)
              ORDER BY g, ts, id) x), 3);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

\echo '--- RP-15 histogram'
DO $$
DECLARE s TEXT := 'rp15_histogram';
BEGIN
    PERFORM test_assert_equal(s, 'RP-15 buckets of 100 [RP-15]',
        (SELECT string_agg(h.bucket_start::INTEGER || ':' || h.order_count, ',' ORDER BY h.bucket_start)
         FROM public.report_order_value_histogram('2025-01-01', '2026-01-01', 100) h), '0:6,100:5,200:1,300:1,400:1,2500:1');
    PERFORM test_assert_equal(s, 'RP-15 bucket edges are half-open (199.99 stays in [100,200)) [RQ-05]',
        (SELECT h.order_count FROM public.report_order_value_histogram('2025-01-01', '2026-01-01', 100) h WHERE h.bucket_start = 100), 5);
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;

-- ============================================================
-- RULE TESTS (mechanics that silently corrupt a report)
-- ============================================================
\echo '--- query rules'
DO $$
DECLARE s TEXT := 'rq_rules'; v_a NUMERIC; v_b NUMERIC;
BEGIN
    -- RQ-03 NULL arithmetic
    PERFORM test_assert_equal(s, 'RQ-03 SUM over no rows is NULL, COALESCE makes it 0 [RQ-03]',
        (SELECT COALESCE(SUM(v), 0) FROM (VALUES (1)) t(v) WHERE FALSE), 0::BIGINT);
    PERFORM test_assert_sqlstate(s, 'RQ-03 x / 0 raises 22012 … [RQ-03]', 'SELECT 1 / 0', '22012');
    PERFORM test_assert_equal(s, 'RQ-03 … x / NULLIF(0, 0) is NULL [RQ-03]', 1 / NULLIF(0, 0), NULL::INTEGER);
    -- RQ-04 integer division and rounding
    PERFORM test_assert_equal(s, 'RQ-04 7 / 2 = 3 in integer arithmetic [RQ-04]', 7 / 2, 3);
    PERFORM test_assert_equal(s, 'RQ-04 7 / 2.0 = 3.5 [RQ-04]', 7 / 2.0, 3.5::NUMERIC);
    PERFORM test_assert_equal(s, 'RQ-04 ratio × 100 before ROUND, not after [RQ-04]', ROUND(1 * 100.0 / 3, 2), 33.33::NUMERIC);
    SELECT SUM(ROUND(v, 2)), ROUND(SUM(v), 2) INTO v_a, v_b FROM (VALUES (0.005), (0.005), (0.005)) t(v);
    PERFORM test_assert_true(s, 'RQ-19 sum of rounded values ≠ rounded sum (round last) [RQ-19] [RQ-04]', v_a <> v_b, format('%s vs %s', v_a, v_b));
    PERFORM test_assert_equal(s, 'RQ-19 money in NUMERIC: 0.1 + 0.2 = 0.3 [RQ-19]', 0.1::NUMERIC + 0.2::NUMERIC = 0.3::NUMERIC, TRUE);
    PERFORM test_assert_equal(s, 'RQ-19 … but not in double precision [RQ-19]', 0.1::FLOAT8 + 0.2::FLOAT8 = 0.3::FLOAT8, FALSE);
    -- RQ-05 time ranges
    PERFORM test_assert_equal(s, 'RQ-05 BETWEEN … AND ''2025-06-30'' drops 18:30 on the last day [RQ-05]',
        '2025-06-30 18:30'::TIMESTAMP BETWEEN '2025-06-01'::DATE AND '2025-06-30'::DATE, FALSE);
    PERFORM test_assert_equal(s, 'RQ-05 half-open [2025-06-01, 2025-07-01) keeps it [RQ-05]',
        '2025-06-30 18:30'::TIMESTAMP >= '2025-06-01'::DATE AND '2025-06-30 18:30'::TIMESTAMP < '2025-07-01'::DATE, TRUE);
    -- RQ-06 time zones
    PERFORM test_assert_equal(s, 'RQ-06 02:30 UTC on 1 July is still 30 June in New York [RQ-06]',
        (('2025-07-01 02:30:00+00'::TIMESTAMPTZ AT TIME ZONE 'America/New_York')::DATE), '2025-06-30'::DATE);
    PERFORM test_assert_equal(s, 'RQ-06 DST: 1 day after 2025-03-09 00:00 NY is 23 hours later [RQ-06]',
        EXTRACT(EPOCH FROM (('2025-03-10 00:00'::TIMESTAMP AT TIME ZONE 'America/New_York')
                          - ('2025-03-09 00:00'::TIMESTAMP AT TIME ZONE 'America/New_York')))::INTEGER, 23 * 3600);
    -- RQ-07 week definition
    PERFORM test_assert_equal(s, 'RQ-07 date_trunc(week) is ISO (Monday): Sun 2025-03-30 → 2025-03-24 [RQ-07]',
        date_trunc('week', '2025-03-30'::DATE::TIMESTAMP)::DATE, '2025-03-24'::DATE);
    PERFORM test_assert_equal(s, 'RQ-07 Sunday-start week: d - EXTRACT(DOW) → 2025-03-30 [RQ-07]',
        ('2025-03-30'::DATE - EXTRACT(DOW FROM '2025-03-30'::DATE)::INTEGER), '2025-03-30'::DATE);
    -- RQ-08 window frames
    PERFORM test_assert_equal(s, 'RQ-08 default RANGE frame: duplicate ORDER BY keys are peers → 20,20,30 [RQ-08]',
        (SELECT string_agg(rt::TEXT, ',' ORDER BY d, v) FROM (SELECT d, v, SUM(v) OVER (ORDER BY d) rt
              FROM (VALUES ('2025-01-01'::DATE, 10), ('2025-01-01'::DATE, 10), ('2025-01-02'::DATE, 10)) t(d, v)) x), '20,20,30');
    PERFORM test_assert_equal(s, 'RQ-08 ROWS frame with a tie-breaker gives a true running total → 10,20,30 [RQ-08] [RQ-16]',
        (SELECT string_agg(rt::TEXT, ',' ORDER BY d, id) FROM (SELECT d, id, SUM(v) OVER (ORDER BY d, id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) rt
              FROM (VALUES ('2025-01-01'::DATE, 1, 10), ('2025-01-01'::DATE, 2, 10), ('2025-01-02'::DATE, 3, 10)) t(d, id, v)) x), '10,20,30');
    -- RQ-10 percentiles on an even count
    PERFORM test_assert_equal(s, 'RQ-10 percentile_cont(0.5) of 1,2,3,4 = 2.5; percentile_disc = 2 [RQ-10]',
        (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)::TEXT || '/' || percentile_disc(0.5) WITHIN GROUP (ORDER BY v)::TEXT
         FROM (VALUES (1), (2), (3), (4)) t(v)), '2.5/2');
    -- RQ-14 revenue definition
    PERFORM test_assert_equal(s, 'RQ-14 2025 has 18 orders but 15 revenue orders [RQ-14]',
        (SELECT COUNT(*)::TEXT || '/' || COUNT(*) FILTER (WHERE status NOT IN ('Cancelled','Refunded'))::TEXT
         FROM public.orders WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01'), '18/15');
    -- RQ-22 text dimensions
    PERFORM test_assert_equal(s, 'RQ-22 GROUP BY raw text splits '' Widgets'', ''widgets'' and ''Widgets'' [RQ-22]',
        (SELECT COUNT(*) FROM (SELECT k FROM (VALUES (' Widgets'), ('widgets'), ('Widgets')) t(k) GROUP BY k) x), 3::BIGINT);
    PERFORM test_assert_equal(s, 'RQ-22 GROUP BY lower(trim(k)) → one group [RQ-22]',
        (SELECT COUNT(*) FROM (SELECT lower(trim(k)) FROM (VALUES (' Widgets'), ('widgets'), ('Widgets')) t(k) GROUP BY 1) x), 1::BIGINT);
    -- RQ-24 counts
    PERFORM test_assert_equal(s, 'RQ-24 COUNT(*) = 4, COUNT(col) = 3, COUNT(DISTINCT col) = 2 [RQ-24]',
        (SELECT COUNT(*)::TEXT || '/' || COUNT(v)::TEXT || '/' || COUNT(DISTINCT v)::TEXT FROM (VALUES (1), (1), (2), (NULL)) t(v)), '4/3/2');
    -- RQ-02 the two report entry points agree on the revenue order count
    PERFORM test_assert_equal(s, 'RQ-02 monthly report and stats report count the same 15 orders [RQ-02]',
        (SELECT SUM(m.order_count) FROM public.report_revenue_by_month('2025-01-01', '2026-01-01') m)::INTEGER,
        (SELECT x.order_count FROM public.report_order_value_stats('2025-01-01', '2026-01-01') x));
EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);
END $$;
