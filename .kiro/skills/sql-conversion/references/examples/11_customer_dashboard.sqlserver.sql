-- Worked example 11 — SQL Server source
-- Patterns: TWO result sets from one procedure, the second one optional
--           (driven by a BIT flag); correlated COUNT(*) subquery; TOP (n).
-- Converted: 11_customer_dashboard.postgres.sql
CREATE PROCEDURE dbo.usp_GetCustomerDashboard
    @CustomerId    INT,
    @IncludeOrders BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Result set 1: profile
    SELECT c.CustomerId,
           c.FirstName + ' ' + c.LastName AS CustomerName,
           c.Email,
           (SELECT COUNT(*) FROM dbo.Orders o WHERE o.CustomerId = c.CustomerId) AS OrderCount
    FROM   dbo.Customers c
    WHERE  c.CustomerId = @CustomerId;

    -- Result set 2: five most recent orders (only when asked for)
    IF @IncludeOrders = 1
        SELECT TOP (5) o.OrderId, o.CreatedAt, o.TotalAmount, o.Status
        FROM   dbo.Orders o
        WHERE  o.CustomerId = @CustomerId
        ORDER  BY o.CreatedAt DESC;
END
GO
