-- Worked example 13 — PostgreSQL conversion of 13_discounted_price.sqlserver.sql
-- Key decisions:
--   * (a) SELECT … INTO sets the variable to NULL when no row matches, whereas
--     T-SQL keeps the old value [P1, CC-61]. Select into a scratch variable
--     and assign only IF FOUND.
--   * (b) SELECT … INTO takes the FIRST row; T-SQL keeps the LAST [CC-62].
--     Reverse the ORDER BY and add LIMIT 1.
--   * The source's "invalid coupon" check is dead code (see (a)). It is
--     converted as-is and flagged, never silently fixed (hard rule H1).
--   * CAST(x AS MONEY) → ::NUMERIC(19,4) (rounds to 4 places, like MONEY).
CREATE OR REPLACE FUNCTION public.get_discounted_price(
    p_product_id   INTEGER,
    p_coupon_code  VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE(list_price NUMERIC(19,4), discount_pct NUMERIC(5,2),
              final_price NUMERIC(19,4), latest_coupon VARCHAR(50))
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_price          NUMERIC(19,4);
    v_discount       NUMERIC(5,2) := 0;
    v_found_discount NUMERIC(5,2);
    v_latest_coupon  VARCHAR(50);
BEGIN
    SELECT p.price INTO v_price FROM public.products p WHERE p.product_id = p_product_id;

    IF p_coupon_code IS NOT NULL THEN
        SELECT c.discount_pct
        INTO   v_found_discount
        FROM   public.coupons c
        WHERE  c.code = p_coupon_code AND c.is_active AND c.expires_at > LOCALTIMESTAMP;

        IF FOUND THEN                         -- (a) keep 0 when no coupon matched
            v_discount := v_found_discount;
        END IF;
    END IF;

    -- TODO: MANUAL REVIEW REQUIRED — source bug preserved: v_discount can never
    -- be NULL here, so an unknown/expired coupon is accepted at full price.
    IF v_discount IS NULL THEN
        RAISE EXCEPTION 'Invalid coupon' USING ERRCODE = 'P0001';
    END IF;

    -- (b) last row of "ORDER BY ExpiresAt" = first row of "ORDER BY expires_at DESC"
    SELECT c.code
    INTO   v_latest_coupon
    FROM   public.coupons c
    WHERE  c.is_active
    ORDER  BY c.expires_at DESC
    LIMIT  1;

    RETURN QUERY
        SELECT v_price,
               v_discount,
               (v_price * (1 - v_discount / 100.0))::NUMERIC(19,4),
               v_latest_coupon;
END;
$$;

-- Usage:
-- SELECT * FROM public.get_discounted_price(1, 'SAVE10');
