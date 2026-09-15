-- ============================================================
-- Source: SQL Server Stored Procedure
-- File: source/usp_ManageInventory.sql
-- Description: Inventory management procedures covering
--              stock adjustments, low-stock alerts, and
--              batch reorder processing
-- Schema: source/schema/sales_db_schema.sql
-- ============================================================

USE [InventoryDB]
GO

-- ============================================================
-- 1. Adjust inventory stock with audit trail
-- ============================================================
CREATE PROCEDURE [dbo].[usp_AdjustStock]
    @ProductId     INT,
    @WarehouseId   INT,
    @Quantity      INT,         -- positive = add, negative = remove
    @Reason        NVARCHAR(200),
    @AdjustedBy    NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentStock   INT;
    DECLARE @NewStock       INT;
    DECLARE @AdjustmentId   INT;
    DECLARE @AdjustedAt     DATETIME2 = SYSDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Get current stock with row lock
        SELECT @CurrentStock = QuantityOnHand
        FROM   dbo.Inventory WITH (UPDLOCK, ROWLOCK)
        WHERE  ProductId   = @ProductId
          AND  WarehouseId = @WarehouseId;

        IF @CurrentStock IS NULL
        BEGIN
            -- Initialize record if not exists
            INSERT INTO dbo.Inventory (ProductId, WarehouseId, QuantityOnHand, LastUpdated)
            VALUES (@ProductId, @WarehouseId, 0, @AdjustedAt);
            SET @CurrentStock = 0;
        END

        SET @NewStock = @CurrentStock + @Quantity;

        IF @NewStock < 0
        BEGIN
            RAISERROR('Insufficient stock. Current: %d, Requested: %d', 16, 1,
                      @CurrentStock, ABS(@Quantity));
            ROLLBACK TRANSACTION;
            RETURN;
        END

        UPDATE dbo.Inventory
        SET    QuantityOnHand = @NewStock,
               LastUpdated    = @AdjustedAt
        WHERE  ProductId   = @ProductId
          AND  WarehouseId = @WarehouseId;

        -- Audit log
        INSERT INTO dbo.InventoryAudit
            (ProductId, WarehouseId, PreviousQty, Adjustment, NewQty,
             Reason, AdjustedBy, AdjustedAt)
        VALUES
            (@ProductId, @WarehouseId, @CurrentStock, @Quantity, @NewStock,
             @Reason, @AdjustedBy, @AdjustedAt);

        SET @AdjustmentId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;

        SELECT @AdjustmentId AS AdjustmentId,
               @CurrentStock AS PreviousStock,
               @NewStock     AS NewStock;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @Msg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @Sev INT            = ERROR_SEVERITY();
        RAISERROR(@Msg, @Sev, 1);
    END CATCH
END
GO

-- ============================================================
-- 2. Get low-stock products using table variable
-- ============================================================
CREATE PROCEDURE [dbo].[usp_GetLowStockAlerts]
    @ReorderThreshold   INT = 10,
    @WarehouseId        INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Alerts TABLE (
        ProductId       INT,
        ProductName     NVARCHAR(200),
        SKU             VARCHAR(50),
        WarehouseId     INT,
        WarehouseName   NVARCHAR(100),
        CurrentStock    INT,
        ReorderPoint    INT,
        LastRestocked   DATETIME,
        DaysSinceRestock INT
    );

    INSERT INTO @Alerts
    SELECT
        p.ProductId,
        p.ProductName,
        p.SKU,
        w.WarehouseId,
        w.WarehouseName,
        i.QuantityOnHand                             AS CurrentStock,
        ISNULL(p.ReorderPoint, @ReorderThreshold)    AS ReorderPoint,
        i.LastRestocked,
        DATEDIFF(day, i.LastRestocked, GETDATE())    AS DaysSinceRestock
    FROM   dbo.Inventory   i WITH (NOLOCK)
    JOIN   dbo.Products    p WITH (NOLOCK) ON p.ProductId   = i.ProductId
    JOIN   dbo.Warehouses  w WITH (NOLOCK) ON w.WarehouseId = i.WarehouseId
    WHERE  i.QuantityOnHand <= ISNULL(p.ReorderPoint, @ReorderThreshold)
      AND  p.IsActive = 1
      AND  (@WarehouseId IS NULL OR i.WarehouseId = @WarehouseId);

    IF @@ROWCOUNT = 0
    BEGIN
        PRINT 'No low-stock alerts found.';
        RETURN;
    END

    SELECT  ProductId,
            ProductName,
            SKU,
            WarehouseId,
            WarehouseName,
            CurrentStock,
            ReorderPoint,
            ReorderPoint - CurrentStock AS ShortfallQty,
            CONVERT(VARCHAR, LastRestocked, 101) AS LastRestockedFormatted,
            DaysSinceRestock
    FROM    @Alerts
    ORDER   BY ShortfallQty DESC, DaysSinceRestock DESC;
END
GO

-- ============================================================
-- 3. Batch reorder processing with OUTPUT into staging table
-- ============================================================
CREATE PROCEDURE [dbo].[usp_ProcessReorders]
    @CreatedBy  NVARCHAR(100),
    @MaxOrders  INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #ReorderQueue (
        ProductId    INT,
        WarehouseId  INT,
        CurrentStock INT,
        ReorderQty   INT
    );

    -- Fill the reorder queue
    INSERT INTO #ReorderQueue (ProductId, WarehouseId, CurrentStock, ReorderQty)
    SELECT TOP (@MaxOrders)
           i.ProductId,
           i.WarehouseId,
           i.QuantityOnHand,
           p.ReorderQuantity
    FROM   dbo.Inventory i WITH (NOLOCK)
    JOIN   dbo.Products  p WITH (NOLOCK) ON p.ProductId = i.ProductId
    WHERE  i.QuantityOnHand <= ISNULL(p.ReorderPoint, 10)
      AND  p.IsActive = 1
      AND  NOT EXISTS (
               SELECT 1
               FROM   dbo.PurchaseOrders po WITH (NOLOCK)
               WHERE  po.ProductId   = i.ProductId
                 AND  po.WarehouseId = i.WarehouseId
                 AND  po.Status      IN ('Draft', 'Submitted', 'InTransit')
           )
    ORDER  BY i.QuantityOnHand ASC;

    DECLARE @CreatedOrders TABLE (
        PurchaseOrderId  INT,
        ProductId        INT,
        ReorderQty       INT
    );

    -- Create purchase orders, capturing IDs
    INSERT INTO dbo.PurchaseOrders
        (ProductId, WarehouseId, Quantity, Status, CreatedBy, CreatedAt)
    OUTPUT
        INSERTED.PurchaseOrderId,
        INSERTED.ProductId,
        INSERTED.Quantity
    INTO @CreatedOrders
    SELECT
        ProductId,
        WarehouseId,
        ReorderQty,
        'Draft',
        @CreatedBy,
        GETDATE()
    FROM #ReorderQueue;

    -- Return summary
    SELECT
        co.PurchaseOrderId,
        co.ProductId,
        p.ProductName,
        co.ReorderQty,
        rq.CurrentStock
    FROM   @CreatedOrders co
    JOIN   #ReorderQueue  rq ON rq.ProductId = co.ProductId
    JOIN   dbo.Products   p  ON p.ProductId  = co.ProductId
    ORDER  BY co.PurchaseOrderId;

    DROP TABLE #ReorderQueue;
END
GO
