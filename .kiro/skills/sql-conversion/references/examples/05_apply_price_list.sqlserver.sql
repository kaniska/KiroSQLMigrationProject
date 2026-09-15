-- Worked example 05 — SQL Server source
-- Patterns: MERGE upsert on a unique key (MATCHED / NOT MATCHED only),
--           @@ROWCOUNT after MERGE returned as a one-row result set.
-- Converted: 05_apply_price_list.postgres.sql
CREATE PROCEDURE dbo.usp_ApplyPriceList
    @EffectiveDate DATE
AS
BEGIN
    SET NOCOUNT ON;

    MERGE dbo.Products AS tgt
    USING (
        SELECT SKU, ProductName, Price, CategoryId
        FROM   dbo.ProductStaging
        WHERE  EffectiveDate = @EffectiveDate
          AND  IsActive = 1
    ) AS src
    ON tgt.SKU = src.SKU
    WHEN MATCHED THEN
        UPDATE SET ProductName = src.ProductName,
                   Price       = src.Price,
                   UpdatedAt   = GETDATE()
    WHEN NOT MATCHED THEN
        INSERT (SKU, ProductName, Price, CategoryId, IsActive, CreatedAt)
        VALUES (src.SKU, src.ProductName, src.Price, src.CategoryId, 1, GETDATE());

    SELECT @@ROWCOUNT AS RowsAffected;
END
GO
