-- Worked example 07 — PostgreSQL conversion of 07_get_org_chart.sqlserver.sql
-- Key decisions:
--   * WITH → WITH RECURSIVE (mandatory in PostgreSQL).
--   * OPTION (MAXRECURSION n) has no equivalent; the ot.lvl < p_max_depth
--     predicate is the real guard. PostgreSQL never stops a runaway
--     recursion by itself — keep or add a depth predicate.
--   * The anchor and recursive members must produce identical column types
--     (0 and lvl + 1 are both INTEGER; employee_name is VARCHAR(200) on both
--     sides). Cast explicitly when they differ.
--   * CTE columns get names that differ from the RETURNS TABLE columns
--     (lvl, emp_id, ...) so nothing collides with the output variables.
--   * REPLICATE → REPEAT; string + → || (NULL-propagating, like +).
--   * Result ordering by a text column follows the database collation, which
--     may differ from SQL Server's case-insensitive collation.
CREATE OR REPLACE FUNCTION public.get_org_chart(
    p_root_employee_id  INTEGER,
    p_max_depth         INTEGER DEFAULT 10
)
RETURNS TABLE(
    employee_id    INTEGER,
    manager_id     INTEGER,
    employee_name  VARCHAR(200),
    title          VARCHAR(100),
    level          INTEGER,
    indented_name  TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        WITH RECURSIVE org_tree AS (
            SELECT e.employee_id AS emp_id, e.manager_id AS mgr_id,
                   e.employee_name AS emp_name, e.title AS emp_title, 0 AS lvl
            FROM   public.employees e
            WHERE  e.employee_id = p_root_employee_id

            UNION ALL

            SELECT e.employee_id, e.manager_id, e.employee_name, e.title, ot.lvl + 1
            FROM   public.employees e
            JOIN   org_tree ot ON e.manager_id = ot.emp_id
            WHERE  ot.lvl < p_max_depth
        )
        SELECT ot.emp_id,
               ot.mgr_id,
               ot.emp_name,
               ot.emp_title,
               ot.lvl,
               REPEAT('  ', ot.lvl) || ot.emp_name
        FROM   org_tree ot
        ORDER  BY ot.lvl, ot.emp_name;
END;
$$;

-- Usage:
-- SELECT * FROM public.get_org_chart(1);
