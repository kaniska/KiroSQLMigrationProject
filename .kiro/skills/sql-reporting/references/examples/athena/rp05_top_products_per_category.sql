-- Pattern RP-05 (Amazon Athena) — Top-N per group, ties kept
-- Dialect: RD-07 DENSE_RANK in a CTE (Athena has no QUALIFY), RD-14 view + params CTE
-- Rules applied: RQ-09 ties, RQ-01 aggregate first, RQ-16 deterministic order
CREATE OR REPLACE VIEW sales_lake.v_report_top_products_per_category AS
WITH params AS (SELECT DATE '2025-01-01' AS p_from, DATE '2026-01-01' AS p_to, 3 AS p_n),
product_units AS (
    SELECT p.category, p.sku, sum(ol.quantity) AS units
    FROM   sales_lake.order_lines ol
    JOIN   sales_lake.orders   o  ON o.order_id = ol.order_id
    JOIN   sales_lake.products p  ON p.product_id = ol.product_id
    CROSS JOIN params pr
    WHERE  o.created_at >= CAST(pr.p_from AS TIMESTAMP) AND o.created_at < CAST(pr.p_to AS TIMESTAMP)
      AND  o.status NOT IN ('Cancelled', 'Refunded')
    GROUP  BY p.category, p.sku
),
ranked AS (
    SELECT pu.category, pu.sku, pu.units,
           dense_rank() OVER (PARTITION BY pu.category ORDER BY pu.units DESC) AS rnk
    FROM   product_units pu
)
SELECT r.category, r.sku, r.units, r.rnk
FROM   ranked r CROSS JOIN params pr
WHERE  r.rnk <= pr.p_n;
