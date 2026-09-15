-- Worked example 16 — SQL Server source
-- Patterns: inline table-valued function (RETURNS TABLE AS RETURN SELECT),
--           TOP (@n) WITH TIES, GROUP BY + HAVING, fn_ prefix.
-- Converted: 16_top_customers.postgres.sql
CREATE FUNCTION dbo.fn_TopCustomers (
    @MinOrders INT,
    @TopN      INT
)
RETURNS TABLE
AS
RETURN
    SELECT TOP (@TopN) WITH TIES
           c.CustomerId,
           c.FirstName + ' ' + c.LastName AS CustomerName,
           COUNT(o.OrderId)               AS OrderCount,
           SUM(o.TotalAmount)             AS TotalSpent
    FROM   dbo.Customers c
    JOIN   dbo.Orders    o ON o.CustomerId = c.CustomerId
    WHERE  o.Status <> 'Cancelled'
    GROUP  BY c.CustomerId, c.FirstName, c.LastName
    HAVING COUNT(o.OrderId) >= @MinOrders
    ORDER  BY COUNT(o.OrderId) DESC;
GO

-- Caller: SELECT * FROM dbo.fn_TopCustomers(1, 3);
