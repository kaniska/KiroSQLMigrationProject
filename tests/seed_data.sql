-- ============================================================
-- File: tests/seed_data.sql
-- Description: Deterministic test data for generated/schema.sql.
--              Tables are recreated before seeding, so identity values
--              start at 1 and the IDs below are stable.
--              Order dates are FIXED (not relative to today) so report
--              results never depend on the day the suite runs.
-- Loaded by: tests/test_runner.sql
-- ============================================================

INSERT INTO public.warehouses (warehouse_name) VALUES
    ('Main Warehouse'),                -- 1
    ('East Distribution Center');      -- 2

INSERT INTO public.categories (category_name) VALUES
    ('Widgets'),                       -- 1
    ('Gadgets'),                       -- 2
    ('Other');                         -- 3

-- Products are created 100 days ago so age-in-days assertions are exact
INSERT INTO public.products
    (sku, product_name, category, category_id, price, weight_lbs, is_active,
     reorder_point, reorder_quantity, default_warehouse_id, created_at)
VALUES
    ('WP-001', 'Widget Pro',        'Widgets', 1, 29.99, 1.500, TRUE,  10, 100, 1,    LOCALTIMESTAMP - INTERVAL '100 days'),  -- 1
    ('GP-002', 'Gadget Plus',       'Gadgets', 2, 49.99, 2.000, TRUE,   5,  50, 1,    LOCALTIMESTAMP - INTERVAL '100 days'),  -- 2
    ('DI-999', 'Discontinued Item', 'Other',   3,  9.99, 0.500, FALSE,  0,   0, NULL, LOCALTIMESTAMP - INTERVAL '100 days'),  -- 3
    ('BW-003', 'Budget Widget',     'Widgets', 1,  9.99, 0.750, TRUE,  15,  75, 1,    LOCALTIMESTAMP - INTERVAL '100 days'),  -- 4
    ('PG-004', 'Premium Gadget',    'Gadgets', 2, 99.99, 3.250, TRUE,   3,  25, 2,    LOCALTIMESTAMP - INTERVAL '100 days');  -- 5

-- Referral tree: Alice ← Bob ← Carol, Alice ← Dan. Erin stands alone.
INSERT INTO public.customers
    (external_id, first_name, last_name, email, phone, birth_date, referred_by, created_at)
VALUES
    ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Alice', 'Smith',  'alice@example.com', '+1-555-0101', '1990-06-15', NULL, '2024-01-10 09:00'),  -- 1
    ('b1eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', 'Bob',   'Jones',  'bob@example.com',   '555-0102',    '1985-02-20', 1,    '2024-02-11 09:00'),  -- 2
    (NULL,                                   'Carol', 'Wilson', 'carol@example.com', NULL,          NULL,         2,    '2024-03-12 09:00'),  -- 3
    (NULL,                                   'Dan',   'Brown',  'dan@example.com',   '555-0104',    '1999-12-31', 1,    '2024-04-13 09:00'),  -- 4
    (NULL,                                   'erin',  'Stone',  'erin@example.com',  '12',          '2001-01-01', NULL, '2024-05-14 09:00');  -- 5

-- Inventory. Low stock at warehouse 1: GP-002 (3 ≤ 5), BW-003 (8 ≤ 15), PG-004 (2 ≤ 3).
-- DI-999 would qualify (0 ≤ 0) but is inactive.
INSERT INTO public.inventory (product_id, warehouse_id, quantity_on_hand, last_restocked) VALUES
    (1, 1, 50, CURRENT_DATE - 30),
    (2, 1,  3, CURRENT_DATE - 60),
    (3, 1,  0, CURRENT_DATE - 200),
    (4, 1,  8, CURRENT_DATE - 45),
    (5, 1,  2, CURRENT_DATE - 90),
    (1, 2, 20, CURRENT_DATE - 15),
    (2, 2, 10, CURRENT_DATE - 20);

-- Orders (fixed dates)
--   3: 18:45 on the LAST day of June 2026 → excluded by the preserved
--      "BETWEEN start AND EOMONTH-midnight" behaviour
--   5: 2025-06-22 is a SUNDAY → SQL Server week grouping maps it to Mon 2025-06-23
--   7: exactly 00:00 on the last day of June 2026 → included
INSERT INTO public.orders (customer_id, total_amount, status, created_at) VALUES
    (1, 1500.00, 'Processed', '2024-03-15 10:00:00'),   -- 1
    (1, 2500.00, 'Processed', '2025-06-10 14:30:00'),   -- 2
    (1,  299.99, 'Pending',   '2026-06-30 18:45:00'),   -- 3
    (2,   89.98, 'Cancelled', '2025-06-12 09:00:00'),   -- 4
    (2,  199.99, 'Processed', '2025-06-22 11:00:00'),   -- 5
    (3,  120.00, 'Completed', '2026-06-05 08:00:00'),   -- 6
    (4,   45.00, 'Completed', '2026-06-30 00:00:00'),   -- 7
    (5, 1250.00, 'Pending',   '2026-05-20 10:00:00');   -- 8

INSERT INTO public.order_lines (order_id, product_id, quantity, unit_price) VALUES
    (1, 1,  2, 29.99),
    (2, 2,  1, 49.99),
    (2, 1,  1, 29.99),
    (3, 1, 10, 29.99),
    (4, 5,  1, 99.99),
    (5, 4,  3,  9.99),
    (5, 5,  1, 99.99),
    (6, 1,  2, 29.99),   -- order 6 weight: 2 × 1.500 + 1 × 2.000 = 5.000 lbs
    (6, 2,  1, 49.99),
    (7, 4,  4,  9.99),   -- order 7 weight: 4 × 0.750 = 3.000 lbs
    (8, 5, 12, 99.99);

INSERT INTO public.coupons (code, discount_pct, is_active, expires_at) VALUES
    ('SAVE10', 10.00, TRUE, LOCALTIMESTAMP + INTERVAL '30 days'),
    ('OLD5',    5.00, TRUE, LOCALTIMESTAMP - INTERVAL '1 day');

INSERT INTO public.employees (manager_id, employee_name, title) VALUES
    (NULL, 'Ada', 'CEO'),        -- 1
    (1,    'Ben', 'CTO'),        -- 2
    (2,    'Cy',  'Engineer'),   -- 3
    (1,    'Di',  'CFO');        -- 4
