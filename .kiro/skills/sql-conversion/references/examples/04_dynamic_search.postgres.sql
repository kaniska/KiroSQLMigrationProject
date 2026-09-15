-- Worked example 04 — PostgreSQL conversion of 04_dynamic_search.sqlserver.sql
-- Key decisions:
--   * The result shape depends on a caller-chosen table, so RETURNS TABLE is
--     impossible. RETURNS SETOF JSONB (one object per row) keeps the function
--     callable without a column-definition list. (Alternatives: SETOF RECORD —
--     caller must spell out the columns — or a refcursor.)
--   * QUOTENAME(x) → format('%I', x). Identifier arguments must be the
--     PostgreSQL (snake_case) names; add a mapping if legacy callers pass
--     SQL Server names like 'Email'.
--   * sp_executesql @params → EXECUTE ... USING; values are bound, never
--     concatenated. $n numbers follow the USING order.
--   * The source's pattern is used verbatim as a LIKE pattern; LIKE under a
--     case-insensitive collation → ILIKE. Non-text columns need ::TEXT
--     (SQL Server converted implicitly).
--   * SYSNAME → VARCHAR(128); dbo. → public.
CREATE OR REPLACE FUNCTION public.dynamic_search(
    p_table_name  VARCHAR(128),
    p_filter_col  VARCHAR(128),
    p_filter_val  VARCHAR(500),
    p_order_col   VARCHAR(128),
    p_page_num    INTEGER DEFAULT 1,
    p_page_size   INTEGER DEFAULT 20
)
RETURNS SETOF JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sql     TEXT;
    v_offset  INTEGER := (p_page_num - 1) * p_page_size;
BEGIN
    v_sql := format(
        'SELECT to_jsonb(t) FROM public.%I AS t
          WHERE t.%I::TEXT ILIKE $1
          ORDER BY t.%I
          LIMIT $3 OFFSET $2',
        p_table_name, p_filter_col, p_order_col);

    RETURN QUERY EXECUTE v_sql
        USING p_filter_val,   -- $1  @val
              v_offset,       -- $2  @off
              p_page_size;    -- $3  @ps
END;
$$;

-- Usage:
-- SELECT r ->> 'email' FROM public.dynamic_search('customers', 'email', '%@example.com', 'customer_id') AS r;
