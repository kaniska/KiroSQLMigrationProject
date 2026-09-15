-- Worked example 02 — SQL Server source
-- Patterns: cursor (DECLARE CURSOR / FETCH / @@FETCH_STATUS), aggregate
--           assignment, ISNULL, procedure with no result set.
-- Converted: 02_recalc_order_totals.postgres.sql
CREATE PROCEDURE dbo.usp_RecalcOrderTotals
    @StartDate DATETIME,
    @EndDate   DATETIME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OrderId INT, @NewTotal MONEY;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT OrderId FROM dbo.Orders WHERE CreatedAt BETWEEN @StartDate AND @EndDate;

    OPEN cur;
    FETCH NEXT FROM cur INTO @OrderId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @NewTotal = SUM(Quantity * UnitPrice)
        FROM   dbo.OrderLines
        WHERE  OrderId = @OrderId;

        UPDATE dbo.Orders SET TotalAmount = ISNULL(@NewTotal, 0) WHERE OrderId = @OrderId;

        FETCH NEXT FROM cur INTO @OrderId;
    END

    CLOSE cur;
    DEALLOCATE cur;
END
GO
