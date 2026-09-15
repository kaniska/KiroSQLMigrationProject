-- Worked example 12 — SQL Server source
-- Patterns: MERGE with extra match conditions, WHEN NOT MATCHED BY SOURCE with a
--           scoping condition, OUTPUT $action INTO a table variable, detail
--           result set.
-- Converted: 12_sync_category_prices.postgres.sql
CREATE PROCEDURE dbo.usp_SyncCategoryPrices
    @CategoryId    INT,
    @EffectiveDate DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Changes TABLE (Action NVARCHAR(10), ProductId INT, SKU VARCHAR(50));

    MERGE dbo.Products AS tgt
    USING (
        SELECT SKU, ProductName, Price, CategoryId
        FROM   dbo.ProductStaging
        WHERE  CategoryId = @CategoryId
          AND  EffectiveDate = @EffectiveDate
    ) AS src
    ON tgt.SKU = src.SKU
    WHEN MATCHED AND tgt.Price <> src.Price THEN
        UPDATE SET Price = src.Price, UpdatedAt = GETDATE()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (SKU, ProductName, Price, CategoryId, IsActive, CreatedAt)
        VALUES (src.SKU, src.ProductName, src.Price, src.CategoryId, 1, GETDATE())
    WHEN NOT MATCHED BY SOURCE AND tgt.CategoryId = @CategoryId AND tgt.IsActive = 1 THEN
        UPDATE SET IsActive = 0, UpdatedAt = GETDATE()
    OUTPUT $action, INSERTED.ProductId, INSERTED.SKU
    INTO @Changes (Action, ProductId, SKU);

    SELECT Action, ProductId, SKU FROM @Changes ORDER BY SKU;
END
GO
