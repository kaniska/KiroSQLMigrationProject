-- Worked example 09 — SQL Server source
-- Patterns: SET XACT_ABORT ON, BEGIN TRAN in TRY/CATCH, THROW with a user
--           error number, bare THROW re-raise, @@ROWCOUNT-driven
--           update-else-insert, OUTPUT INSERTED.* INTO @table variable.
-- Converted: 09_transfer_stock.postgres.sql
CREATE PROCEDURE dbo.usp_TransferStock
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ProductId       INT,
    @Quantity        INT,
    @TransferredBy   NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Affected TABLE (TransferId INT, Status VARCHAR(20));

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.Inventory
        SET    QuantityOnHand = QuantityOnHand - @Quantity,
               LastUpdated    = SYSDATETIME()
        WHERE  WarehouseId = @FromWarehouseId
          AND  ProductId   = @ProductId
          AND  QuantityOnHand >= @Quantity;

        IF @@ROWCOUNT = 0
            THROW 50001, N'Insufficient stock or invalid warehouse/product.', 1;

        UPDATE dbo.Inventory
        SET    QuantityOnHand = QuantityOnHand + @Quantity,
               LastUpdated    = SYSDATETIME()
        WHERE  WarehouseId = @ToWarehouseId
          AND  ProductId   = @ProductId;

        IF @@ROWCOUNT = 0
            INSERT INTO dbo.Inventory (ProductId, WarehouseId, QuantityOnHand, LastUpdated)
            VALUES (@ProductId, @ToWarehouseId, @Quantity, SYSDATETIME());

        INSERT INTO dbo.StockTransfers
            (FromWarehouseId, ToWarehouseId, ProductId, Quantity, TransferredBy, TransferredAt)
        OUTPUT INSERTED.TransferId, 'OK' INTO @Affected (TransferId, Status)
        VALUES (@FromWarehouseId, @ToWarehouseId, @ProductId, @Quantity, @TransferredBy, SYSDATETIME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT TransferId, Status FROM @Affected;
END
GO
