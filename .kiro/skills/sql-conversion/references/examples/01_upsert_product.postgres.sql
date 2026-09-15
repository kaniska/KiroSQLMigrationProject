-- Worked example 01 — PostgreSQL conversion of 01_upsert_product.sqlserver.sql
-- Key decisions:
--   * Proc ends in a SELECT → FUNCTION ... RETURNS TABLE.
--   * PostgreSQL requires every parameter after a defaulted one to have a
--     default too. Keep the source order (positional callers still work) and
--     give the later required parameters DEFAULT NULL + an explicit check that
--     reproduces SQL Server's "expects parameter ... which was not supplied".
--   * SCOPE_IDENTITY() → RETURNING <alias>.product_id INTO v_product_id.
--   * RETURNS TABLE columns are variables: product_id/sku/price would clash
--     with the table's columns, so every column reference is alias-qualified.
CREATE OR REPLACE FUNCTION public.upsert_product(
    p_product_id    INTEGER        DEFAULT NULL,
    p_product_name  VARCHAR(200)   DEFAULT NULL,   -- required in the source
    p_sku           VARCHAR(50)    DEFAULT NULL,   -- required in the source
    p_price         NUMERIC(19,4)  DEFAULT NULL,   -- required in the source
    p_is_active     BOOLEAN        DEFAULT TRUE,
    p_category_id   INTEGER        DEFAULT NULL    -- required in the source
)
RETURNS TABLE(
    product_id    INTEGER,
    product_name  VARCHAR(200),
    sku           VARCHAR(50),
    price         NUMERIC(19,4),
    is_active     BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_product_id  INTEGER := p_product_id;
BEGIN
    IF p_product_name IS NULL OR p_sku IS NULL OR p_price IS NULL OR p_category_id IS NULL THEN
        RAISE EXCEPTION 'upsert_product expects p_product_name, p_sku, p_price and p_category_id'
            USING ERRCODE = '22023';   -- invalid_parameter_value
    END IF;

    IF v_product_id IS NULL THEN
        INSERT INTO public.products AS p (product_name, sku, price, is_active, category_id, created_at)
        VALUES (p_product_name, p_sku, p_price, p_is_active, p_category_id, LOCALTIMESTAMP)
        RETURNING p.product_id INTO v_product_id;                -- SCOPE_IDENTITY()
    ELSE
        UPDATE public.products p
        SET    product_name = p_product_name,
               sku          = p_sku,
               price        = p_price,
               is_active    = p_is_active,
               category_id  = p_category_id,
               updated_at   = LOCALTIMESTAMP
        WHERE  p.product_id = v_product_id;
    END IF;

    RETURN QUERY
        SELECT p.product_id, p.product_name, p.sku, p.price, p.is_active
        FROM   public.products p
        WHERE  p.product_id = v_product_id;
END;
$$;

-- Usage (named notation mirrors EXEC ... @Param = value):
-- SELECT * FROM public.upsert_product(p_product_name => 'Mega Widget', p_sku => 'MW-010',
--                                     p_price => 59.99, p_category_id => 1);
