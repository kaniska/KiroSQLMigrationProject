-- Worked example 05 — security-bearing view (identity function + authorization join)
-- Patterns: ORIGINAL_LOGIN(), IS_MEMBER(), authorization table join, masked column via CASE.
-- Converted: 05_secure_employee_view.redshift.sql (RLS + masking policy drafts, SECURITY_MAPPING_REQUIRED until approved)
CREATE VIEW dbo.v_EmployeeSecure AS
SELECT e.EmployeeId, e.Name, e.DepartmentId,
       CASE WHEN IS_MEMBER('HRManagers') = 1 THEN e.Salary ELSE NULL END AS Salary,
       CASE WHEN IS_MEMBER('HRManagers') = 1 THEN e.NationalId ELSE 'XXX-XX-' + RIGHT(e.NationalId, 4) END AS NationalId
FROM   dbo.Employee e
WHERE  e.DepartmentId IN (SELECT a.DepartmentId FROM dbo.UserDepartmentAccess a WHERE a.UserName = ORIGINAL_LOGIN());
