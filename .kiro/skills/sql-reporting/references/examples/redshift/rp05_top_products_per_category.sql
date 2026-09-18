-- Pattern RP-05 (Amazon Redshift) — Top-N per group, ties kept
-- Dialect: RD-07 DENSE_RANK in a CTE (QUALIFY would also work on Redshift but is not portable), RD-14 view
-- Rules applied: RQ-09 ties, RQ-01 aggregate first, RQ-16 deterministic order
CREATE OR REPLACE VIEW sales.v_report_top_products_per_category AS
WITH params AS (SELECT DATE '2025-01-01' AS p_from, DATE '2026-01-01' AS p_to, 3 AS p_n),
product_units AS (
    SELECT p.category, p.sku, SUM(ol.quantity)::BIGINT AS units
    FROM   sales.order_lines ol
    JOIN   sales.orders   o  ON o.order_id = ol.order_id
    JOIN   sales.products p  ON p.product_id = ol.product_id
    JOIN   params         pr ON o.created_at >= pr.p_from AND o.created_at < pr.p_to
    WHERE  o.status NOT IN ('Cancelled', 'Refunded')
    GROUP  BY p.category, p.sku
),
ranked AS (
    SELECT pu.category, pu.sku, pu.units,
           DENSE_RANK() OVER (PARTITION BY pu.category ORDER BY pu.units DESC) AS rnk
    FROM   product_units pu
)
SELECT r.category, r.sku, r.units, r.rnk
FROM   ranked r JOIN params pr ON r.rnk <= pr.p_n;
