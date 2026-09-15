-- Worked example 08 — PostgreSQL conversion of 08_format_customer_report.sqlserver.sql
-- Key decisions (each one changes results if done naively):
--   * DATEDIFF(year, a, b) counts YEAR BOUNDARIES: EXTRACT(YEAR FROM b) -
--     EXTRACT(YEAR FROM a). AGE() would give the true age — a different number
--     for anyone whose birthday is still ahead this year.
--   * LEN(s) ignores trailing spaces → char_length(rtrim(s)).
--   * CHARINDEX(needle, hay) → STRPOS(hay, needle) — arguments swap.
--   * REPLICATE(s, n) returns NULL when n < 0; REPEAT returns ''. Guard with
--     CASE so a short phone number still yields NULL, as in SQL Server.
--   * FORMAT(d, 'MMM dd, yyyy') → TO_CHAR(d, 'Mon DD, YYYY').
--   * CONVERT(VARCHAR, d, 101) → TO_CHAR(d, 'MM/DD/YYYY'); DATEADD(day, 30, x)
--     → x + INTERVAL '30 days'; GETDATE() → LOCALTIMESTAMP.
--   * string + → || (NULL in, NULL out — the same as +; CONCAT would not be).
CREATE OR REPLACE FUNCTION public.format_customer_report(
    p_customer_id  INTEGER
)
RETURNS TABLE(
    formatted_first_name  TEXT,
    age                   INTEGER,
    join_date             TEXT,
    at_position           INTEGER,
    masked_phone          TEXT,
    trial_expiry          TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        SELECT
            UPPER(LEFT(c.first_name, 1))
                || LOWER(SUBSTRING(c.first_name, 2, char_length(rtrim(c.first_name)))),
            (EXTRACT(YEAR FROM LOCALTIMESTAMP) - EXTRACT(YEAR FROM c.birth_date))::INTEGER,
            TO_CHAR(c.created_at, 'Mon DD, YYYY'),
            STRPOS(c.email, '@'),
            CASE WHEN char_length(rtrim(c.phone)) - 4 >= 0
                 THEN REPEAT('*', char_length(rtrim(c.phone)) - 4)
            END || RIGHT(c.phone, 4),
            TO_CHAR(LOCALTIMESTAMP + INTERVAL '30 days', 'MM/DD/YYYY')
        FROM   public.customers c
        WHERE  c.customer_id = p_customer_id;
END;
$$;

-- Usage:
-- SELECT * FROM public.format_customer_report(1);
