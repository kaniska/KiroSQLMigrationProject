-- Worked example 07 — SQL Server source
-- Patterns: recursive CTE (no RECURSIVE keyword in T-SQL), REPLICATE,
--           string concatenation with +, ORDER BY on the recursion level.
-- Converted: 07_get_org_chart.postgres.sql
CREATE PROCEDURE dbo.usp_GetOrgChart
    @RootEmployeeId INT,
    @MaxDepth       INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    WITH OrgTree AS (
        SELECT EmployeeId, ManagerId, EmployeeName, Title, 0 AS Level
        FROM   dbo.Employees
        WHERE  EmployeeId = @RootEmployeeId
        UNION ALL
        SELECT e.EmployeeId, e.ManagerId, e.EmployeeName, e.Title, ot.Level + 1
        FROM   dbo.Employees e
        JOIN   OrgTree ot ON e.ManagerId = ot.EmployeeId
        WHERE  ot.Level < @MaxDepth
    )
    SELECT EmployeeId, ManagerId, EmployeeName, Title, Level,
           REPLICATE('  ', Level) + EmployeeName AS IndentedName
    FROM   OrgTree
    ORDER  BY Level, EmployeeName
    OPTION (MAXRECURSION 100);
END
GO
