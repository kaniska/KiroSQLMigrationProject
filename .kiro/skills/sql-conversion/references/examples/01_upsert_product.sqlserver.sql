-- Worked example 01 — SQL Server source
-- Patterns: IF/ELSE, SCOPE_IDENTITY(), a defaulted parameter FOLLOWED by
--           required ones, BIT parameter, procedure ending in a SELECT.
-- Converted: 01_upsert_product.postgres.sql
CREATE PROCEDURE dbo.usp_UpsertProduct
    @ProductId   INT = NULL,
    @ProductName NVARCHAR(200),
    @SKU         VARCHAR(50),
    @Price       MONEY,
    @IsActive    BIT = 1,
    @CategoryId  INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ProductId IS NULL
    BEGIN
        INSERT INTO dbo.Products (ProductName, SKU, Price, IsActive, CategoryId, CreatedAt)
        VALUES (@ProductName, @SKU, @Price, @IsActive, @CategoryId, GETDATE());

        SET @ProductId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.Products
        SET    ProductName = @ProductName,
               SKU         = @SKU,
               Price       = @Price,
               IsActive    = @IsActive,
               CategoryId  = @CategoryId,
               UpdatedAt   = GETDATE()
        WHERE  ProductId = @ProductId;
    END

    SELECT ProductId, ProductName, SKU, Price, IsActive
    FROM   dbo.Products
    WHERE  ProductId = @ProductId;
END
GO
