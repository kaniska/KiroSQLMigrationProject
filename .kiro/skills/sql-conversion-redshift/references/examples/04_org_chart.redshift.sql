-- Worked example 04 — Amazon Redshift regular view (recursive CTE is not allowed in late-binding views)
-- Ledger: RS-53 WITH RECURSIVE chart(col list) required · RS-57 ROW_NUMBER subquery → QUALIFY
--         RS-14 + → || · RS-11 ISNULL → NVL · RS-19 TRY_CAST → CASE guard · RS-21 NVARCHAR(MAX) → VARCHAR(65535)
CREATE OR REPLACE VIEW hr.v_org_chart AS
WITH RECURSIVE chart(employee_id, manager_id, name, depth, path) AS (
    SELECT e.employee_id, e.manager_id, e.name, 0, CAST(e.name AS VARCHAR(65535))
    FROM   hr.employee e WHERE e.manager_id IS NULL
    UNION ALL
    SELECT e.employee_id, e.manager_id, e.name, c.depth + 1, c.path || ' > ' || e.name
    FROM   hr.employee e JOIN chart c ON e.manager_id = c.employee_id
),
latest_title AS (
    SELECT t.employee_id, t.title
    FROM   hr.employee_title t
    QUALIFY ROW_NUMBER() OVER (PARTITION BY t.employee_id ORDER BY t.effective_from DESC) = 1
)
SELECT c.employee_id, c.manager_id, c.name, c.depth, c.path, NVL(lt.title, 'n/a') AS title,
       CASE WHEN c.name ~ '^[0-9]+$' THEN CAST(c.name AS INTEGER) END AS numeric_name
FROM   chart c LEFT JOIN latest_title lt ON lt.employee_id = c.employee_id;
