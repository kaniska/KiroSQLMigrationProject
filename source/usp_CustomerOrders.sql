-- ============================================================
-- Source: SQL Server Stored Procedures — Comprehensive Examples
-- File: source/usp_CustomerOrders.sql
-- Database: SalesDB
-- Description: Covers all common T-SQL conversion patterns:
--   - Variable declarations, assignment, SELECT INTO var
--   - IF/ELSE, WHILE, CASE
--   - Temp tables, table variables
--   - Cursors
--   - TRY/CATCH error handling
--   - SCOPE_IDENTITY, @@ROWCOUNT, @@FETCH_STATUS
--   - MERGE / upsert
--   - OUTPUT clause
--   - Dynamic SQL (sp_executesql)
--   - Recursive CTE
--   - String functions: LEN, CHARINDEX, REPLICATE, STUFF, FORMAT
--   - Date functions: GETDATE, DATEADD, DATEDIFF, DATEPART, EOMONTH
--   - Type conversions: MONEY, NVARCHAR, DATETIME, BIT, UNIQUEIDENTIFIER
--   - IDENTITY columns, NOLOCK hints
-- Schema: source/schema/sales_db_schema.sql
-- ============================================================

USE [SalesDB]
GO

-- ============================================================
-- 1. usp_CreateCustomerOrder
--    Simple insert with identity capture and error handling
-- ============================================================
CREATE PROCEDURE [dbo].[usp_CreateCustomerOrder]
    @CustomerId     INT,
    @ProductId      INT,
    @Quantity       SMALLINT,
    @Notes          NVARCHAR(500) = NULL,
    @CouponCode     NVARCHAR(50)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OrderId    INT;
    DECLARE @UnitPrice  MONEY;
    DECLARE @Discount   DECIMAL(5,2) = 0;
    DECLARE @TotalAmt   MONEY;
    DECLARE @CreatedAt  DATETIME2    = SYSDATETIME();

    -- Validate product
    SELECT @UnitPrice = Price
    FROM   dbo.Products WITH (NOLOCK)
    WHERE  ProductId = @ProductId AND IsActive = 1;

    IF @UnitPrice IS NULL
    BEGIN
        RAISERROR(N'Product %d is not available.', 16, 1, @ProductId);
        RETURN;
    END

    -- Apply coupon if provided
    IF @CouponCode IS NOT NULL
    BEGIN
        SELECT @Discount = DiscountPct
        FROM   dbo.Coupons WITH (NOLOCK)
        WHERE  Code = @CouponCode AND IsActive = 1
          AND  ExpiresAt > GETDATE();

        IF @Discount IS NULL
        BEGIN
            RAISERROR(N'Coupon %s is invalid or expired.', 16, 1, @CouponCode);
            RETURN;
        END
    END

    SET @TotalAmt = @UnitPrice * @Quantity * (1 - @Discount / 100.0);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.Orders
            (CustomerId, CreatedAt, TotalAmount, DiscountPct, Notes, Status)
        VALUES
            (@CustomerId, @CreatedAt, @TotalAmt, @Discount, @Notes, N'Pending');

        SET @OrderId = SCOPE_IDENTITY();

        INSERT INTO dbo.OrderLines (OrderId, ProductId, Quantity, UnitPrice, LineTotal)
        VALUES (@OrderId, @ProductId, @Quantity, @UnitPrice, @TotalAmt);

        IF @CouponCode IS NOT NULL
            UPDATE dbo.Coupons SET UseCount = UseCount + 1 WHERE Code = @CouponCode;

        COMMIT TRANSACTION;

        -- Return newly created order
        SELECT
            o.OrderId,
            o.CustomerId,
            c.FirstName + N' ' + c.LastName AS CustomerName,
            o.TotalAmount,
            o.DiscountPct,
            o.Status,
            FORMAT(o.CreatedAt, N'yyyy-MM-dd HH:mm:ss') AS CreatedAtFormatted
        FROM   dbo.Orders    o WITH (NOLOCK)
        JOIN   dbo.Customers c WITH (NOLOCK) ON c.CustomerId = o.CustomerId
        WHERE  o.OrderId = @OrderId;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT            = ERROR_SEVERITY();
        RAISERROR(@ErrMsg, @ErrSev, 1);
    END CATCH
END
GO

-- ============================================================
-- 2. usp_GetOrderHistory
--    Paginated search with date/string manipulation
-- ============================================================
CREATE PROCEDURE [dbo].[usp_GetOrderHistory]
    @CustomerId    INT          = NULL,
    @StatusFilter  VARCHAR(50)  = NULL,
    @DateFrom      DATETIME     = NULL,
    @DateTo        DATETIME     = NULL,
    @SearchText    NVARCHAR(200) = NULL,
    @PageNumber    INT           = 1,
    @PageSize      INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    IF @DateFrom IS NULL SET @DateFrom = DATEADD(month, -6, GETDATE());
    IF @DateTo   IS NULL SET @DateTo   = GETDATE();

    SELECT
        o.OrderId,
        o.CustomerId,
        c.FirstName + N' ' + c.LastName    AS CustomerName,
        c.Email,
        o.TotalAmount,
        o.DiscountPct,
        o.Status,
        DATEDIFF(day, o.CreatedAt, GETDATE()) AS DaysAgo,
        FORMAT(o.CreatedAt, N'MMM d, yyyy')    AS OrderDateDisplay,
        CONVERT(VARCHAR, EOMONTH(o.CreatedAt), 101) AS MonthEnd,
        CASE
            WHEN o.TotalAmount >= 1000 THEN N'High Value'
            WHEN o.TotalAmount >= 100  THEN N'Medium Value'
            ELSE N'Low Value'
        END AS ValueTier,
        REPLICATE(N'★', CASE
            WHEN o.TotalAmount >= 1000 THEN 3
            WHEN o.TotalAmount >= 100  THEN 2
            ELSE 1
        END) AS StarRating,
        ROW_NUMBER() OVER (ORDER BY o.CreatedAt DESC) AS RowNum,
        COUNT(*) OVER ()                               AS TotalCount
    FROM   dbo.Orders    o WITH (NOLOCK)
    JOIN   dbo.Customers c WITH (NOLOCK) ON c.CustomerId = o.CustomerId
    WHERE  o.CreatedAt BETWEEN @DateFrom AND @DateTo
      AND  (@CustomerId   IS NULL OR o.CustomerId = @CustomerId)
      AND  (@StatusFilter IS NULL OR o.Status     = @StatusFilter)
      AND  (@SearchText   IS NULL
            OR c.FirstName LIKE N'%' + @SearchText + N'%'
            OR c.LastName  LIKE N'%' + @SearchText + N'%'
            OR c.Email     LIKE N'%' + @SearchText + N'%')
    ORDER  BY o.CreatedAt DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ============================================================
-- 3. usp_ProcessRefund
--    Cursor, temp table, nested TRY/CATCH, OUTPUT
-- ============================================================
CREATE PROCEDURE [dbo].[usp_ProcessRefund]
    @OrderId        INT,
    @RefundReason   NVARCHAR(500),
    @ProcessedBy    NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RefundId   INT;
    DECLARE @OrderTotal MONEY;
    DECLARE @LineCount  INT;

    -- Table to track which lines were refunded
    DECLARE @RefundedLines TABLE (
        LineId      INT,
        ProductId   INT,
        Quantity    SMALLINT,
        LineTotal   MONEY
    );

    -- Temp table for inventory restocking
    CREATE TABLE #RestockQueue (
        ProductId   INT,
        WarehouseId INT,
        Quantity    SMALLINT
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Validate order is refundable
        SELECT @OrderTotal = TotalAmount, @LineCount = (
            SELECT COUNT(*) FROM dbo.OrderLines WHERE OrderId = @OrderId
        )
        FROM dbo.Orders
        WHERE OrderId = @OrderId AND Status = N'Completed';

        IF @OrderTotal IS NULL
        BEGIN
            RAISERROR(N'Order %d is not eligible for refund.', 16, 1, @OrderId);
            ROLLBACK TRANSACTION;
            DROP TABLE #RestockQueue;
            RETURN;
        END

        -- Create the refund record
        INSERT INTO dbo.Refunds (OrderId, Amount, Reason, ProcessedBy, ProcessedAt, Status)
        OUTPUT INSERTED.RefundId INTO @RefundedLines(LineId)  -- reuse table, LineId = RefundId here
        VALUES (@OrderId, @OrderTotal, @RefundReason, @ProcessedBy, GETDATE(), N'Pending');

        SET @RefundId = SCOPE_IDENTITY();

        -- Update order status
        UPDATE dbo.Orders SET Status = N'Refunded', UpdatedAt = GETDATE() WHERE OrderId = @OrderId;

        -- Cursor to restock each line item
        DECLARE @LineId     INT;
        DECLARE @ProductId  INT;
        DECLARE @Quantity   SMALLINT;
        DECLARE @LineTotal  MONEY;
        DECLARE @WarehouseId INT;

        DECLARE line_cursor CURSOR FOR
            SELECT ol.LineId, ol.ProductId, ol.Quantity, ol.LineTotal
            FROM   dbo.OrderLines ol WITH (NOLOCK)
            WHERE  ol.OrderId = @OrderId;

        OPEN line_cursor;
        FETCH NEXT FROM line_cursor INTO @LineId, @ProductId, @Quantity, @LineTotal;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- Get default warehouse for product
            SELECT @WarehouseId = DefaultWarehouseId
            FROM   dbo.Products WITH (NOLOCK)
            WHERE  ProductId = @ProductId;

            IF @WarehouseId IS NOT NULL
                INSERT INTO #RestockQueue (ProductId, WarehouseId, Quantity)
                VALUES (@ProductId, @WarehouseId, @Quantity);

            FETCH NEXT FROM line_cursor INTO @LineId, @ProductId, @Quantity, @LineTotal;
        END

        CLOSE line_cursor;
        DEALLOCATE line_cursor;

        -- Bulk restock using temp table
        UPDATE i
        SET    i.QuantityOnHand = i.QuantityOnHand + rq.Quantity,
               i.LastUpdated    = GETDATE()
        FROM   dbo.Inventory i
        JOIN   #RestockQueue rq
               ON  rq.ProductId   = i.ProductId
               AND rq.WarehouseId = i.WarehouseId;

        IF @@ROWCOUNT > 0
            PRINT N'Inventory restocked for ' + CAST(@@ROWCOUNT AS VARCHAR) + N' item(s).';

        UPDATE dbo.Refunds SET Status = N'Completed' WHERE RefundId = @RefundId;

        COMMIT TRANSACTION;

        SELECT @RefundId AS RefundId, @OrderTotal AS RefundAmount, N'Completed' AS Status;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DROP TABLE IF EXISTS #RestockQueue;
        DECLARE @Msg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@Msg, 16, 1);
    END CATCH

    DROP TABLE IF EXISTS #RestockQueue;
END
GO

-- ============================================================
-- 4. usp_GetCustomerSummary
--    Scalar aggregates, CASE tiers, string functions, recursive CTE for referrals
-- ============================================================
CREATE PROCEDURE [dbo].[usp_GetCustomerSummary]
    @CustomerId       INT,
    @IncludeReferrals BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Customer stats
    DECLARE @TotalSpend     MONEY;
    DECLARE @OrderCount     INT;
    DECLARE @AvgOrder       MONEY;
    DECLARE @FirstOrder     DATETIME;
    DECLARE @LastOrder      DATETIME;
    DECLARE @TenureMonths   INT;
    DECLARE @Tier           NVARCHAR(20);
    DECLARE @MaskedEmail    NVARCHAR(255);
    DECLARE @Email          NVARCHAR(255);

    SELECT
        @TotalSpend = SUM(TotalAmount),
        @OrderCount = COUNT(*),
        @FirstOrder = MIN(CreatedAt),
        @LastOrder  = MAX(CreatedAt)
    FROM dbo.Orders WITH (NOLOCK)
    WHERE CustomerId = @CustomerId AND Status != N'Cancelled';

    SET @AvgOrder     = CASE WHEN @OrderCount > 0 THEN @TotalSpend / @OrderCount ELSE 0 END;
    SET @TenureMonths = DATEDIFF(month, @FirstOrder, GETDATE());
    SET @Tier = CASE
        WHEN @TotalSpend >= 10000 THEN N'Platinum'
        WHEN @TotalSpend >= 5000  THEN N'Gold'
        WHEN @TotalSpend >= 1000  THEN N'Silver'
        ELSE N'Bronze'
    END;

    -- Mask email: keep first char + domain
    SELECT @Email = Email FROM dbo.Customers WITH (NOLOCK) WHERE CustomerId = @CustomerId;
    SET @MaskedEmail = LEFT(@Email, 1)
        + REPLICATE(N'*', CHARINDEX(N'@', @Email) - 2)
        + SUBSTRING(@Email, CHARINDEX(N'@', @Email), LEN(@Email));

    SELECT
        c.CustomerId,
        c.FirstName + N' ' + c.LastName    AS FullName,
        @MaskedEmail                        AS MaskedEmail,
        DATEDIFF(year, c.BirthDate, GETDATE()) AS Age,
        @TotalSpend                         AS TotalSpend,
        @OrderCount                         AS OrderCount,
        @AvgOrder                           AS AvgOrderValue,
        @Tier                               AS Tier,
        @TenureMonths                       AS TenureMonths,
        FORMAT(@FirstOrder, N'yyyy-MM-dd')  AS FirstOrderDate,
        FORMAT(@LastOrder,  N'yyyy-MM-dd')  AS LastOrderDate,
        CONVERT(VARCHAR(10), DATEADD(day, 30, @LastOrder), 120) AS EstimatedNextOrder
    FROM dbo.Customers c WITH (NOLOCK)
    WHERE c.CustomerId = @CustomerId;

    -- Referral tree (second result set)
    IF @IncludeReferrals = 1
    BEGIN
        WITH ReferralTree AS (
            SELECT CustomerId, FirstName + N' ' + LastName AS Name, ReferredBy, 1 AS Level
            FROM   dbo.Customers WITH (NOLOCK)
            WHERE  ReferredBy = @CustomerId
            UNION ALL
            SELECT c.CustomerId, c.FirstName + N' ' + c.LastName, c.ReferredBy, rt.Level + 1
            FROM   dbo.Customers c WITH (NOLOCK)
            JOIN   ReferralTree rt ON rt.CustomerId = c.ReferredBy
            WHERE  rt.Level < 5
        )
        SELECT rt.CustomerId, rt.Name, rt.Level,
               ISNULL(SUM(o.TotalAmount), 0) AS ReferralRevenue
        FROM   ReferralTree rt
        LEFT   JOIN dbo.Orders o WITH (NOLOCK)
               ON o.CustomerId = rt.CustomerId AND o.Status != N'Cancelled'
        GROUP  BY rt.CustomerId, rt.Name, rt.Level
        ORDER  BY rt.Level, ReferralRevenue DESC;
    END
END
GO

-- ============================================================
-- 5. usp_SyncProductCatalog
--    MERGE with all three clauses, OUTPUT into table variable
-- ============================================================
CREATE PROCEDURE [dbo].[usp_SyncProductCatalog]
    @EffectiveDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @EffectiveDate IS NULL SET @EffectiveDate = CAST(GETDATE() AS DATE);

    DECLARE @SyncResults TABLE (
        Action      NVARCHAR(10),
        ProductId   INT,
        SKU         VARCHAR(50),
        OldPrice    MONEY,
        NewPrice    MONEY
    );

    MERGE dbo.Products AS tgt
    USING (
        SELECT ProductId, SKU, ProductName, Price, CategoryId, IsActive
        FROM   dbo.ProductStaging
        WHERE  EffectiveDate <= @EffectiveDate
          AND  (ExpiresDate IS NULL OR ExpiresDate > @EffectiveDate)
    ) AS src ON tgt.SKU = src.SKU
    WHEN MATCHED AND src.IsActive = 0 THEN
        UPDATE SET tgt.IsActive = 0, tgt.UpdatedAt = GETDATE()
    WHEN MATCHED AND (tgt.Price != src.Price OR tgt.ProductName != src.ProductName) THEN
        UPDATE SET
            tgt.ProductName = src.ProductName,
            tgt.Price       = src.Price,
            tgt.UpdatedAt   = GETDATE()
    WHEN NOT MATCHED BY TARGET AND src.IsActive = 1 THEN
        INSERT (SKU, ProductName, Price, CategoryId, IsActive, CreatedAt)
        VALUES (src.SKU, src.ProductName, src.Price, src.CategoryId, 1, GETDATE())
    WHEN NOT MATCHED BY SOURCE THEN
        UPDATE SET tgt.IsActive = 0, tgt.UpdatedAt = GETDATE()
    OUTPUT
        $action,
        COALESCE(INSERTED.ProductId, DELETED.ProductId),
        COALESCE(INSERTED.SKU, DELETED.SKU),
        DELETED.Price,
        INSERTED.Price
    INTO @SyncResults;

    SELECT
        Action,
        COUNT(*)                                     AS Count,
        SUM(CASE WHEN Action = 'INSERT' THEN 1 ELSE 0 END) AS Inserted,
        SUM(CASE WHEN Action = 'UPDATE' THEN 1 ELSE 0 END) AS Updated,
        SUM(CASE WHEN Action = 'DELETE' THEN 1 ELSE 0 END) AS Deleted
    FROM @SyncResults
    GROUP BY Action
    ORDER BY Action;
END
GO

-- ============================================================
-- 6. usp_SearchProductsDynamic
--    Dynamic SQL with sp_executesql, QUOTENAME, parameterized
-- ============================================================
CREATE PROCEDURE [dbo].[usp_SearchProductsDynamic]
    @Category    NVARCHAR(100) = NULL,
    @MinPrice    MONEY         = NULL,
    @MaxPrice    MONEY         = NULL,
    @SearchText  NVARCHAR(200) = NULL,
    @SortColumn  NVARCHAR(50)  = N'Price',
    @SortDir     VARCHAR(4)    = 'ASC',
    @Page        INT           = 1,
    @PageSize    INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    -- Whitelist sort columns to prevent injection
    IF @SortColumn NOT IN (N'Price', N'ProductName', N'CreatedAt', N'SKU')
        SET @SortColumn = N'Price';
    IF @SortDir NOT IN ('ASC', 'DESC')
        SET @SortDir = 'ASC';

    DECLARE @SQL      NVARCHAR(MAX);
    DECLARE @Params   NVARCHAR(500);
    DECLARE @Offset   INT = (@Page - 1) * @PageSize;

    SET @SQL = N'
    SELECT
        p.ProductId,
        p.ProductName,
        p.SKU,
        p.Price,
        p.CategoryId,
        cat.CategoryName,
        CHARINDEX(ISNULL(@srch, ''''), p.ProductName) AS MatchPosition,
        DATEDIFF(day, p.CreatedAt, GETDATE())  AS AgeDays
    FROM   dbo.Products  p  WITH (NOLOCK)
    JOIN   dbo.Categories cat WITH (NOLOCK) ON cat.CategoryId = p.CategoryId
    WHERE  p.IsActive = 1
    ';

    IF @Category   IS NOT NULL SET @SQL = @SQL + N' AND cat.CategoryName = @cat';
    IF @MinPrice   IS NOT NULL SET @SQL = @SQL + N' AND p.Price >= @minP';
    IF @MaxPrice   IS NOT NULL SET @SQL = @SQL + N' AND p.Price <= @maxP';
    IF @SearchText IS NOT NULL SET @SQL = @SQL + N' AND p.ProductName LIKE N''%'' + @srch + N''%''';

    SET @SQL = @SQL + N'
    ORDER BY p.' + QUOTENAME(@SortColumn) + N' ' + @SortDir + N'
    OFFSET @off ROWS FETCH NEXT @ps ROWS ONLY';

    SET @Params = N'@cat NVARCHAR(100), @minP MONEY, @maxP MONEY, @srch NVARCHAR(200),
                    @off INT, @ps INT';

    EXEC sp_executesql @SQL, @Params,
        @cat  = @Category,
        @minP = @MinPrice,
        @maxP = @MaxPrice,
        @srch = @SearchText,
        @off  = @Offset,
        @ps   = @PageSize;
END
GO

-- ============================================================
-- 7. usp_CalculateShipping
--    Pure computation: math functions, CASE, BIT, UNIQUEIDENTIFIER
-- ============================================================
CREATE PROCEDURE [dbo].[usp_CalculateShipping]
    @OrderId        INT,
    @ShipToZip      VARCHAR(10),
    @IsExpedited    BIT = 0,
    @TrackingRef    UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @TrackingRef IS NULL SET @TrackingRef = NEWID();

    DECLARE @Weight        DECIMAL(10,3);
    DECLARE @OrderTotal    MONEY;
    DECLARE @BaseRate      MONEY;
    DECLARE @ExpediteAdder MONEY = 0;
    DECLARE @FreeThreshold MONEY = 50.00;
    DECLARE @ShippingCost  MONEY;
    DECLARE @ZipPrefix     VARCHAR(3);

    SELECT
        @OrderTotal = o.TotalAmount,
        @Weight     = SUM(p.WeightLbs * ol.Quantity)
    FROM   dbo.Orders     o WITH (NOLOCK)
    JOIN   dbo.OrderLines ol WITH (NOLOCK) ON ol.OrderId   = o.OrderId
    JOIN   dbo.Products   p  WITH (NOLOCK) ON p.ProductId  = ol.ProductId
    WHERE  o.OrderId = @OrderId
    GROUP  BY o.TotalAmount;

    IF @OrderTotal IS NULL
    BEGIN
        RAISERROR(N'Order %d not found.', 16, 1, @OrderId);
        RETURN;
    END

    SET @ZipPrefix = LEFT(@ShipToZip, 3);

    -- Zone-based rate
    SET @BaseRate = CASE
        WHEN @ZipPrefix BETWEEN '100' AND '199' THEN ROUND(@Weight * 0.85, 2)  -- Northeast
        WHEN @ZipPrefix BETWEEN '300' AND '399' THEN ROUND(@Weight * 1.05, 2)  -- Southeast
        WHEN @ZipPrefix BETWEEN '600' AND '699' THEN ROUND(@Weight * 1.20, 2)  -- Midwest
        WHEN @ZipPrefix BETWEEN '900' AND '999' THEN ROUND(@Weight * 1.45, 2)  -- West Coast
        ELSE                                         ROUND(@Weight * 1.10, 2)
    END;

    IF @IsExpedited = 1
        SET @ExpediteAdder = @BaseRate * 0.5;  -- 50% surcharge

    SET @ShippingCost = CASE
        WHEN @OrderTotal >= @FreeThreshold THEN 0
        ELSE @BaseRate + @ExpediteAdder
    END;

    SELECT
        @OrderId                                AS OrderId,
        LOWER(REPLACE(CAST(@TrackingRef AS VARCHAR(36)), '-', '')) AS TrackingNumber,
        @Weight                                 AS TotalWeightLbs,
        @ShippingCost                           AS ShippingCost,
        @IsExpedited                            AS IsExpedited,
        CASE WHEN @IsExpedited = 1
             THEN DATEADD(day, 1, CAST(GETDATE() AS DATE))
             ELSE DATEADD(day, 5, CAST(GETDATE() AS DATE))
        END                                     AS EstimatedDelivery,
        FORMAT(GETDATE(), N'yyyy-MM-ddTHH:mm:ss') AS CalculatedAt;
END
GO
