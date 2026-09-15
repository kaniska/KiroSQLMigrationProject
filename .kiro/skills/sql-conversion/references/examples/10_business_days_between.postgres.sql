-- Worked example 10 — PostgreSQL conversion of 10_business_days_between.sqlserver.sql
-- Key decisions:
--   * Scalar UDF → FUNCTION ... RETURNS INTEGER; fn_ prefix dropped.
--     IMMUTABLE: the result depends only on the arguments (lets the planner
--     fold constant calls and allows use in indexes).
--   * DATEPART(weekday, d) under the default DATEFIRST 7 (1 = Sunday) →
--     EXTRACT(DOW FROM d) + 1. If the source ran with another DATEFIRST use
--     ((EXTRACT(DOW FROM d)::INT + 7 - @@DATEFIRST % 7) % 7) + 1.
--   * WHILE ... BEGIN ... END → WHILE ... LOOP ... END LOOP; CONTINUE is the same.
--   * SET @x += 1 → v_x := v_x + 1 (no compound assignment in PL/pgSQL).
--   * DATEADD(day, 1, d) on a DATE → d + 1.
--   * A set-based rewrite (COUNT over generate_series) is faster; the loop is
--     kept to show the mechanical mapping.
CREATE OR REPLACE FUNCTION public.business_days_between(
    p_start_date  DATE,
    p_end_date    DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_days  INTEGER := 0;
    v_d     DATE    := p_start_date;
BEGIN
    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        RETURN NULL;
    END IF;

    WHILE v_d < p_end_date LOOP
        v_d := v_d + 1;                                     -- DATEADD(day, 1, @d)

        IF (EXTRACT(DOW FROM v_d)::INTEGER + 1) IN (1, 7) THEN   -- DATEPART(weekday)
            CONTINUE;
        END IF;

        v_days := v_days + 1;                               -- SET @Days += 1
    END LOOP;

    RETURN v_days;
END;
$$;

-- Usage:
-- SELECT public.business_days_between('2026-09-04', '2026-09-11');   -- 5
