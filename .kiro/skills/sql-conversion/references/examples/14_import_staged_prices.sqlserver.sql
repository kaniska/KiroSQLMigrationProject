-- Worked example 14 — SQL Server source
-- Patterns: cursor with per-row TRY/CATCH that LOGS AND CONTINUES, no explicit
--           transaction (every statement autocommits), THROW inside TRY,
--           @@ROWCOUNT, a final THROW after the loop — the error reaches the
--           caller but the log rows and the good updates are already committed.
-- Converted: 14_import_staged_prices.postgres.sql
CREATE PROCEDURE dbo.usp_ImportStagedPrices
    @EffectiveDate DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StagingId INT, @SKU VARCHAR(50), @Price MONEY, @Failed INT = 0;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT StagingId, SKU, Price
        FROM   dbo.ProductStaging
        WHERE  EffectiveDate = @EffectiveDate
        ORDER  BY StagingId;

    OPEN cur;
    FETCH NEXT FROM cur INTO @StagingId, @SKU, @Price;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            IF @Price <= 0
                THROW 50010, 'Price must be positive', 1;

            UPDATE dbo.Products SET Price = @Price, UpdatedAt = GETDATE() WHERE SKU = @SKU;

            IF @@ROWCOUNT = 0
                THROW 50011, 'Unknown SKU', 1;
        END TRY
        BEGIN CATCH
            SET @Failed += 1;
            INSERT INTO dbo.ProcessingErrors (OrderId, ErrorMessage, OccurredAt)
            VALUES (NULL, CONCAT(@SKU, ': ', ERROR_MESSAGE()), GETDATE());
        END CATCH

        FETCH NEXT FROM cur INTO @StagingId, @SKU, @Price;
    END

    CLOSE cur;
    DEALLOCATE cur;

    IF @Failed > 0
        THROW 50012, 'Some staged prices failed; see ProcessingErrors.', 1;
END
GO
