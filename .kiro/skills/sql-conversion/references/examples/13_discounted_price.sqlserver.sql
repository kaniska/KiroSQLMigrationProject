-- Worked example 13 — SQL Server source
-- Patterns: SELECT @var = col … semantics that differ from PostgreSQL:
--           (a) no matching row → @var keeps its previous value,
--           (b) several rows → @var ends with the LAST row's value;
--           a latent source bug that must be preserved, MONEY arithmetic.
-- Converted: 13_discounted_price.postgres.sql
CREATE PROCEDURE dbo.usp_GetDiscountedPrice
    @ProductId  INT,
    @CouponCode NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Price        MONEY;
    DECLARE @Discount     DECIMAL(5,2) = 0;
    DECLARE @LatestCoupon NVARCHAR(50);

    SELECT @Price = Price FROM dbo.Products WHERE ProductId = @ProductId;

    -- (a) unknown or expired coupon: no row, so @Discount silently stays 0
    IF @CouponCode IS NOT NULL
        SELECT @Discount = DiscountPct
        FROM   dbo.Coupons
        WHERE  Code = @CouponCode AND IsActive = 1 AND ExpiresAt > GETDATE();

    -- Intended as "reject invalid coupons" but can never fire (bug)
    IF @Discount IS NULL
    BEGIN
        RAISERROR('Invalid coupon', 16, 1);
        RETURN;
    END

    -- (b) several rows: the last one wins → the latest-expiring active coupon
    SELECT @LatestCoupon = Code FROM dbo.Coupons WHERE IsActive = 1 ORDER BY ExpiresAt;

    SELECT @Price                                     AS ListPrice,
           @Discount                                  AS DiscountPct,
           CAST(@Price * (1 - @Discount / 100.0) AS MONEY) AS FinalPrice,
           @LatestCoupon                              AS LatestCoupon;
END
GO
