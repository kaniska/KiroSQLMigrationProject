-- ============================================================
-- Source Example: SQL Server Stored Procedure
-- File: examples/source_example.sql
-- Demonstrates: temp tables, cursors, error handling, data types,
--               identity columns, OUTPUT, MERGE, string/date funcs
-- Schema: source/schema/sales_db_schema.sql
-- ============================================================

USE [SalesDB]
GO

-- ============================================================
-- 1. Simple procedure with parameters and basic DML
-- ============================================================
CREATE PROCEDURE [dbo].[usp_CreateOrder]
    @CustomerId     INT,
    @ProductId      INT,
    @Quantity       SMALLINT,
    @Notes          NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OrderId    INT;
    DECLARE @UnitPrice  MONEY;
    DECLARE @TotalAmt   MONEY;
    DECLARE @CreatedAt  DATETIME = GETDATE();

    -- Validate product exists and get price
    SELECT @UnitPrice = Price
    FROM   dbo.Products WITH (NOLOCK)
    WHERE  ProductId = @ProductId
      AND  IsActive = 1;

    IF @UnitPrice IS NULL
    BEGIN
        RAISERROR('Product %d not found or inactive.', 16, 1, @ProductId);
        RETURN;
    END

    SET @TotalAmt = @UnitPrice * @Quantity;

    BEGIN TRY
        INSERT INTO dbo.Orders (CustomerId, CreatedAt, TotalAmount, Notes, Status)
        VALUES (@CustomerId, @CreatedAt, @TotalAmt, @Notes, 'Pending');

        SET @OrderId = SCOPE_IDENTITY();

        INSERT INTO dbo.OrderLines (OrderId, ProductId, Quantity, UnitPrice)
        VALUES (@OrderId, @ProductId, @Quantity, @UnitPrice);

        -- Return the new order
        SELECT @OrderId AS OrderId, @TotalAmt AS TotalAmount, @CreatedAt AS CreatedAt;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev  INT            = ERROR_SEVERITY();
        RAISERROR(@ErrMsg, @ErrSev, 1);
    END CATCH
END
GO

-- ============================================================
-- 2. Procedure with temp table and cursor
-- ============================================================
CREATE PROCEDURE [dbo].[usp_ProcessPendingOrders]
    @BatchSize      INT = 100,
    @ProcessedDate  DATETIME2 = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @ProcessedDate IS NULL
        SET @ProcessedDate = GETDATE();

    -- Temp table to stage the batch
    CREATE TABLE #PendingBatch (
        OrderId     INT          NOT NULL,
        CustomerId  INT          NOT NULL,
        TotalAmount MONEY        NOT NULL,
        Status      VARCHAR(50)  NOT NULL
    );

    INSERT INTO #PendingBatch (OrderId, CustomerId, TotalAmount, Status)
    SELECT TOP (@BatchSize)
           OrderId, CustomerId, TotalAmount, Status
    FROM   dbo.Orders WITH (NOLOCK)
    WHERE  Status = 'Pending'
    ORDER  BY OrderId ASC;

    IF @@ROWCOUNT = 0
    BEGIN
        PRINT 'No pending orders to process.';
        DROP TABLE #PendingBatch;
        RETURN;
    END

    -- Cursor to process each order
    DECLARE @OrderId     INT;
    DECLARE @CustomerId  INT;
    DECLARE @TotalAmount MONEY;

    DECLARE order_cursor CURSOR FOR
        SELECT OrderId, CustomerId, TotalAmount
        FROM   #PendingBatch
        ORDER  BY OrderId;

    OPEN order_cursor;
    FETCH NEXT FROM order_cursor INTO @OrderId, @CustomerId, @TotalAmount;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            UPDATE dbo.Orders
            SET    Status = 'Processing',
                   UpdatedAt = @ProcessedDate
            WHERE  OrderId = @OrderId;

            -- Simulate processing logic
            IF @TotalAmount > 1000
            BEGIN
                UPDATE dbo.Orders
                SET    RequiresApproval = 1
                WHERE  OrderId = @OrderId;
            END

            UPDATE dbo.Orders
            SET    Status = 'Processed',
                   ProcessedAt = @ProcessedDate
            WHERE  OrderId = @OrderId;

        END TRY
        BEGIN CATCH
            -- Log the failure but continue with next order
            INSERT INTO dbo.ProcessingErrors (OrderId, ErrorMessage, OccurredAt)
            VALUES (@OrderId, ERROR_MESSAGE(), GETDATE());
        END CATCH

        FETCH NEXT FROM order_cursor INTO @OrderId, @CustomerId, @TotalAmount;
    END

    CLOSE order_cursor;
    DEALLOCATE order_cursor;

    DROP TABLE #PendingBatch;
END
GO

-- ============================================================
-- 3. Procedure using OUTPUT clause and MERGE
-- ============================================================
CREATE PROCEDURE [dbo].[usp_UpsertCustomer]
    @ExternalId  UNIQUEIDENTIFIER,
    @FirstName   NVARCHAR(100),
    @LastName    NVARCHAR(100),
    @Email       NVARCHAR(255),
    @Phone       VARCHAR(20) = NULL,
    @BirthDate   DATE        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ResultTable TABLE (
        Action      VARCHAR(10),
        CustomerId  INT,
        Email       NVARCHAR(255)
    );

    MERGE dbo.Customers AS tgt
    USING (SELECT @ExternalId AS ExternalId,
                  @FirstName  AS FirstName,
                  @LastName   AS LastName,
                  @Email      AS Email,
                  @Phone      AS Phone,
                  @BirthDate  AS BirthDate) AS src
    ON tgt.ExternalId = src.ExternalId
    WHEN MATCHED THEN
        UPDATE SET
            FirstName = src.FirstName,
            LastName  = src.LastName,
            Email     = src.Email,
            Phone     = src.Phone,
            UpdatedAt = GETDATE()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ExternalId, FirstName, LastName, Email, Phone, BirthDate, CreatedAt)
        VALUES (src.ExternalId, src.FirstName, src.LastName, src.Email,
                src.Phone, src.BirthDate, GETDATE())
    OUTPUT
        $action,
        INSERTED.CustomerId,
        INSERTED.Email
    INTO @ResultTable (Action, CustomerId, Email);

    SELECT Action, CustomerId, Email FROM @ResultTable;
END
GO

-- ============================================================
-- 4. Procedure with dynamic SQL and string/date manipulation
-- ============================================================
CREATE PROCEDURE [dbo].[usp_SearchOrders]
    @CustomerId    INT         = NULL,
    @Status        VARCHAR(50) = NULL,
    @DateFrom      DATETIME    = NULL,
    @DateTo        DATETIME    = NULL,
    @SearchText    NVARCHAR(200) = NULL,
    @PageNumber    INT         = 1,
    @PageSize      INT         = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SQL        NVARCHAR(MAX);
    DECLARE @ParamDef   NVARCHAR(1000);
    DECLARE @Offset     INT = (@PageNumber - 1) * @PageSize;

    IF @DateFrom IS NULL
        SET @DateFrom = DATEADD(month, -3, GETDATE());
    IF @DateTo IS NULL
        SET @DateTo   = GETDATE();

    SET @SQL = N'
        SELECT  o.OrderId,
                o.CustomerId,
                c.FirstName + '' '' + c.LastName AS CustomerName,
                o.TotalAmount,
                o.Status,
                FORMAT(o.CreatedAt, ''yyyy-MM-dd'') AS OrderDate,
                DATEDIFF(day, o.CreatedAt, GETDATE()) AS DaysOld
        FROM    dbo.Orders     o WITH (NOLOCK)
        JOIN    dbo.Customers  c WITH (NOLOCK) ON c.CustomerId = o.CustomerId
        WHERE   o.CreatedAt BETWEEN @DateFrom AND @DateTo
    ';

    IF @CustomerId IS NOT NULL
        SET @SQL = @SQL + N' AND o.CustomerId = @CustomerId';

    IF @Status IS NOT NULL
        SET @SQL = @SQL + N' AND o.Status = @Status';

    IF @SearchText IS NOT NULL
        SET @SQL = @SQL + N' AND (c.FirstName LIKE ''%'' + @SearchText + ''%''
                                OR c.LastName  LIKE ''%'' + @SearchText + ''%''
                                OR c.Email     LIKE ''%'' + @SearchText + ''%'')';

    SET @SQL = @SQL + N'
        ORDER  BY o.CreatedAt DESC
        OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
    ';

    SET @ParamDef = N'
        @DateFrom   DATETIME,
        @DateTo     DATETIME,
        @CustomerId INT,
        @Status     VARCHAR(50),
        @SearchText NVARCHAR(200),
        @Offset     INT,
        @PageSize   INT
    ';

    EXEC sp_executesql @SQL, @ParamDef,
        @DateFrom   = @DateFrom,
        @DateTo     = @DateTo,
        @CustomerId = @CustomerId,
        @Status     = @Status,
        @SearchText = @SearchText,
        @Offset     = @Offset,
        @PageSize   = @PageSize;
END
GO
