-- Worked example 15 — SQL Server source
-- Patterns: OUTPUT parameters (one with a default), RETURN status code,
--           early RETURN that leaves outputs untouched, and the caller side
--           (EXEC @rc = … @x = @y OUTPUT).
-- Converted: 15_order_stats.postgres.sql
CREATE PROCEDURE dbo.usp_GetOrderStats
    @CustomerId  INT,
    @OrderCount  INT          OUTPUT,
    @TotalSpent  MONEY        OUTPUT,
    @AvgOrder    MONEY = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerId = @CustomerId)
        RETURN 1;                                   -- 1 = unknown customer

    SELECT @OrderCount = COUNT(*),
           @TotalSpent = ISNULL(SUM(TotalAmount), 0)
    FROM   dbo.Orders
    WHERE  CustomerId = @CustomerId AND Status <> 'Cancelled';

    SET @AvgOrder = CASE WHEN @OrderCount = 0 THEN NULL ELSE @TotalSpent / @OrderCount END;

    RETURN 0;
END
GO

-- Caller
DECLARE @rc INT, @n INT, @total MONEY, @avg MONEY;
EXEC @rc = dbo.usp_GetOrderStats @CustomerId = 1,
                                 @OrderCount = @n OUTPUT,
                                 @TotalSpent = @total OUTPUT,
                                 @AvgOrder   = @avg OUTPUT;
SELECT @rc AS ReturnCode, @n AS OrderCount, @total AS TotalSpent, @avg AS AvgOrder;
