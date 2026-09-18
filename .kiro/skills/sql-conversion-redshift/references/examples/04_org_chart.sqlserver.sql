-- Worked example 04 — recursive CTE + latest-row-per-key filter (MIDDLE view)
-- Patterns: recursive CTE without a column list, ROW_NUMBER() subquery filter, CAST to NVARCHAR path,
--           TRY_CAST, ISNULL.
-- Converted: 04_org_chart.redshift.sql
CREATE VIEW dbo.v_OrgChart AS
WITH Chart AS (
    SELECT e.EmployeeId, e.ManagerId, e.Name, 0 AS Depth, CAST(e.Name AS NVARCHAR(MAX)) AS Path
    FROM   dbo.Employee e WHERE e.ManagerId IS NULL
    UNION ALL
    SELECT e.EmployeeId, e.ManagerId, e.Name, c.Depth + 1, c.Path + N' > ' + e.Name
    FROM   dbo.Employee e JOIN Chart c ON e.ManagerId = c.EmployeeId
),
LatestTitle AS (
    SELECT EmployeeId, Title
    FROM (SELECT t.EmployeeId, t.Title, ROW_NUMBER() OVER (PARTITION BY t.EmployeeId ORDER BY t.EffectiveFrom DESC) AS rn
          FROM dbo.EmployeeTitle t) x
    WHERE x.rn = 1
)
SELECT c.EmployeeId, c.ManagerId, c.Name, c.Depth, c.Path, ISNULL(lt.Title, N'n/a') AS Title,
       TRY_CAST(c.Name AS INT) AS NumericName
FROM   Chart c LEFT JOIN LatestTitle lt ON lt.EmployeeId = c.EmployeeId;
