-- ============================================================
-- Source: SQL Server Stored Procedure
-- File: source/usp_SalesReporting.sql
-- Description: Sales reporting procedures covering
--              monthly summaries, customer lifetime value,
--              and product performance analytics
-- Schema: source/schema/sales_db_schema.sql
-- ============================================================

USE [SalesDB]
GO

-- ============================================================
-- 1. Monthly sales summary with window functions
-- ============================================================
CREATE PROCEDURE [dbo].[usp_GetMonthlySalesSummary]
    @Year       INT = NULL,
    @Month      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Default to current month
    IF @Year  IS NULL SET @Year  = YEAR(GETDATE());
    IF @Month IS NULL SET @Month = MONTH(GETDATE());

    DECLARE @StartDate DATETIME = DATEFROMPARTS(@Year, @Month, 1);
    DECLARE @EndDate   DATETIME = EOMONTH(@StartDate);

    SELECT
        p.Category,
        p.ProductName,
        SUM(ol.Quantity)                   AS UnitsSold,
        SUM(ol.Quantity * ol.UnitPrice)    AS Revenue,
        AVG(ol.UnitPrice)                  AS AvgSellingPrice,
        COUNT(DISTINCT o.OrderId)          AS OrderCount,
        SUM(SUM(ol.Quantity * ol.UnitPrice))
            OVER (PARTITION BY p.Category) AS CategoryRevenue,
        RANK()
            OVER (PARTITION BY p.Category
                  ORDER BY SUM(ol.Quantity * ol.UnitPrice) DESC) AS RankInCategory
    FROM   dbo.OrderLines  ol WITH (NOLOCK)
    JOIN   dbo.Orders      o  WITH (NOLOCK) ON o.OrderId   = ol.OrderId
    JOIN   dbo.Products    p  WITH (NOLOCK) ON p.ProductId = ol.ProductId
    WHERE  o.CreatedAt BETWEEN @StartDate AND @EndDate
      AND  o.Status != 'Cancelled'
    GROUP  BY p.Category, p.ProductId, p.ProductName
    ORDER  BY CategoryRevenue DESC, RankInCategory ASC;
END
GO

-- ============================================================
-- 2. Customer Lifetime Value with recursive CTE for referrals
-- ============================================================
CREATE PROCEDURE [dbo].[usp_GetCustomerLifetimeValue]
    @CustomerId     INT,
    @IncludeReferrals BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TotalRevenue   MONEY;
    DECLARE @OrderCount     INT;
    DECLARE @FirstOrderDate DATETIME;
    DECLARE @LastOrderDate  DATETIME;
    DECLARE @AvgOrderValue  MONEY;
    DECLARE @TenureMonths   INT;

    SELECT
        @TotalRevenue   = SUM(TotalAmount),
        @OrderCount     = COUNT(*),
        @FirstOrderDate = MIN(CreatedAt),
        @LastOrderDate  = MAX(CreatedAt)
    FROM   dbo.Orders WITH (NOLOCK)
    WHERE  CustomerId = @CustomerId
      AND  Status != 'Cancelled';

    SET @AvgOrderValue = CASE WHEN @OrderCount > 0
                              THEN @TotalRevenue / @OrderCount
                              ELSE 0 END;

    SET @TenureMonths = DATEDIFF(month, @FirstOrderDate, GETDATE());

    -- Direct customer stats
    SELECT
        c.CustomerId,
        c.FirstName + ' ' + c.LastName     AS CustomerName,
        c.Email,
        @TotalRevenue                       AS LifetimeRevenue,
        @OrderCount                         AS TotalOrders,
        @AvgOrderValue                      AS AvgOrderValue,
        @TenureMonths                       AS TenureMonths,
        FORMAT(@FirstOrderDate, 'yyyy-MM-dd') AS FirstOrderDate,
        FORMAT(@LastOrderDate, 'yyyy-MM-dd')  AS LastOrderDate,
        CASE
            WHEN @TotalRevenue >= 10000 THEN 'Platinum'
            WHEN @TotalRevenue >= 5000  THEN 'Gold'
            WHEN @TotalRevenue >= 1000  THEN 'Silver'
            ELSE 'Bronze'
        END AS Tier
    FROM dbo.Customers c WITH (NOLOCK)
    WHERE c.CustomerId = @CustomerId;

    -- Referral tree if requested (recursive CTE)
    IF @IncludeReferrals = 1
    BEGIN
        WITH ReferralTree AS (
            -- Anchor: direct referrals by this customer
            SELECT
                c.CustomerId,
                c.FirstName + ' ' + c.LastName AS CustomerName,
                c.ReferredBy,
                1 AS Level
            FROM dbo.Customers c WITH (NOLOCK)
            WHERE c.ReferredBy = @CustomerId

            UNION ALL

            -- Recursive: referrals of referrals
            SELECT
                c.CustomerId,
                c.FirstName + ' ' + c.LastName,
                c.ReferredBy,
                rt.Level + 1
            FROM dbo.Customers c WITH (NOLOCK)
            JOIN ReferralTree rt ON rt.CustomerId = c.ReferredBy
            WHERE rt.Level < 5  -- max 5 levels deep
        )
        SELECT
            rt.CustomerId,
            rt.CustomerName,
            rt.Level AS ReferralLevel,
            ISNULL(SUM(o.TotalAmount), 0) AS ReferralRevenue
        FROM   ReferralTree rt
        LEFT   JOIN dbo.Orders o WITH (NOLOCK)
               ON  o.CustomerId = rt.CustomerId
               AND o.Status != 'Cancelled'
        GROUP  BY rt.CustomerId, rt.CustomerName, rt.Level
        ORDER  BY rt.Level, ReferralRevenue DESC;
    END
END
GO

-- ============================================================
-- 3. Product performance with pivot and dynamic SQL
-- ============================================================
CREATE PROCEDURE [dbo].[usp_GetProductPerformance]
    @StartDate  DATE,
    @EndDate    DATE,
    @GroupBy    VARCHAR(10) = 'month'  -- 'month', 'week', 'quarter'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SQL        NVARCHAR(MAX);
    DECLARE @DateTrunc  NVARCHAR(100);

    SET @DateTrunc = CASE @GroupBy
        WHEN 'week'    THEN 'DATEADD(week, DATEDIFF(week, 0, o.CreatedAt), 0)'
        WHEN 'quarter' THEN 'DATEADD(quarter, DATEDIFF(quarter, 0, o.CreatedAt), 0)'
        ELSE                'DATEFROMPARTS(YEAR(o.CreatedAt), MONTH(o.CreatedAt), 1)'
    END;

    SET @SQL = N'
        SELECT
            p.ProductId,
            p.ProductName,
            p.Category,
            ' + @DateTrunc + ' AS PeriodStart,
            SUM(ol.Quantity)                AS UnitsSold,
            SUM(ol.Quantity * ol.UnitPrice) AS Revenue,
            COUNT(DISTINCT o.OrderId)       AS OrderCount,
            AVG(CAST(ol.Quantity AS FLOAT)) AS AvgUnitsPerOrder
        FROM   dbo.OrderLines ol WITH (NOLOCK)
        JOIN   dbo.Orders     o  WITH (NOLOCK) ON o.OrderId   = ol.OrderId
        JOIN   dbo.Products   p  WITH (NOLOCK) ON p.ProductId = ol.ProductId
        WHERE  o.CreatedAt BETWEEN @StartDate AND @EndDate
          AND  o.Status != ''Cancelled''
        GROUP  BY p.ProductId, p.ProductName, p.Category, ' + @DateTrunc + '
        ORDER  BY PeriodStart, Revenue DESC
    ';

    EXEC sp_executesql @SQL,
        N'@StartDate DATE, @EndDate DATE',
        @StartDate = @StartDate,
        @EndDate   = @EndDate;
END
GO
