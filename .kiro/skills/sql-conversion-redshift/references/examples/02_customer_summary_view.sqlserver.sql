-- Worked example 02 — SQL Server BI edge view (RIGHT_EDGE)
-- Patterns: ISNULL, IIF, STRING_AGG, + concatenation, N'' literals, [brackets], WITH (NOLOCK),
--           DATEADD/DATEDIFF/GETDATE kept, CONVERT(VARCHAR(10), d, 120), TOP.
-- Converted: 02_customer_summary_view.redshift.sql
CREATE VIEW [dbo].[v_CustomerSummary] AS
SELECT TOP 100 PERCENT
       c.[CustomerKey],
       c.[CustomerName] + N' (' + c.[Region] + N')'                          AS [DisplayName],
       ISNULL(SUM(f.[LineTotal]), 0)                                        AS [Revenue],
       IIF(MAX(f.[SaleDate]) >= DATEADD(day, -30, GETDATE()), N'ACTIVE', N'DORMANT') AS [Status],
       DATEDIFF(day, MIN(f.[SaleDate]), GETDATE())                          AS [DaysSinceFirstSale],
       STRING_AGG(CONVERT(VARCHAR(10), f.[SaleDate], 120), ',') WITHIN GROUP (ORDER BY f.[SaleDate]) AS [SaleDates],
       LEN(c.[CustomerName])                                                AS [NameLength],
       CHARINDEX(N'Ltd', c.[CustomerName])                                  AS [LtdPos]
FROM   [dbo].[DimCustomer] c WITH (NOLOCK)
       LEFT JOIN [dbo].[FactSales] f WITH (NOLOCK) ON f.[CustomerKey] = c.[CustomerKey]
WHERE  c.[IsActive] = 1
GROUP BY c.[CustomerKey], c.[CustomerName], c.[Region]
ORDER BY [Revenue] DESC;
