-- Worked example 06 — SQL Server source
-- Patterns: UPDATE ... OUTPUT DELETED.col, INSERTED.col INTO @table
--           (old AND new values), table variable, COUNT(*) result set.
-- Converted: 06_bulk_update_prices.postgres.sql
CREATE PROCEDURE dbo.usp_BulkUpdatePrices
    @PctChange  DECIMAL(5,2),
    @CategoryId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AuditLog TABLE (
        ProductId  INT,
        OldPrice   MONEY,
        NewPrice   MONEY,
        ChangedAt  DATETIME
    );

    UPDATE dbo.Products
    SET    Price     = Price * (1 + @PctChange / 100.0),
           UpdatedAt = GETDATE()
    OUTPUT DELETED.ProductId, DELETED.Price, INSERTED.Price, GETDATE()
    INTO   @AuditLog (ProductId, OldPrice, NewPrice, ChangedAt)
    WHERE  CategoryId = @CategoryId
      AND  IsActive = 1;

    INSERT INTO dbo.PriceAudit (ProductId, OldPrice, NewPrice, ChangedAt)
    SELECT ProductId, OldPrice, NewPrice, ChangedAt FROM @AuditLog;

    SELECT COUNT(*) AS ProductsUpdated FROM @AuditLog;
END
GO
