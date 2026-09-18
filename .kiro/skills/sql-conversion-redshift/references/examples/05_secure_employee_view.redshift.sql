-- Worked example 05 — Amazon Redshift: presentation view + RLS policy + masking policy drafts
-- Ledger: RS-61 ORIGINAL_LOGIN()/IS_MEMBER() → RLS policy on CURRENT_USER + role-scoped masking; identity mapping
--         (SQL Server login → Redshift user, HRManagers → role hr_managers) must be approved (SECURITY_MAPPING_REQUIRED)
-- Status: PARTIAL until the identity mapping is approved and the policies are attached in the target account.
CREATE OR REPLACE VIEW hr.v_employee_secure AS
SELECT e.employee_id, e.name, e.department_id, e.salary, e.national_id
FROM   hr.employee e;

-- TODO: MANUAL REVIEW REQUIRED — approve identity mapping before ATTACH (RS-61, SECURITY_MAPPING_REQUIRED)
CREATE RLS POLICY hr_department_access
WITH (department_id INTEGER)
USING (department_id IN (SELECT a.department_id FROM hr.user_department_access a WHERE a.user_name = CURRENT_USER));
ATTACH RLS POLICY hr_department_access ON hr.employee TO PUBLIC;
ALTER TABLE hr.employee ROW LEVEL SECURITY ON;

CREATE MASKING POLICY mask_salary WITH (salary DECIMAL(19,4)) USING (NULL::DECIMAL(19,4));
CREATE MASKING POLICY mask_national_id WITH (national_id VARCHAR(20)) USING ('XXX-XX-' || RIGHT(national_id, 4));
ATTACH MASKING POLICY mask_salary      ON hr.employee (salary)      TO PUBLIC PRIORITY 10;
ATTACH MASKING POLICY mask_national_id ON hr.employee (national_id) TO PUBLIC PRIORITY 10;
-- hr_managers keep the clear values: a higher-priority pass-through policy, or no policy for the role
CREATE MASKING POLICY show_salary WITH (salary DECIMAL(19,4)) USING (salary);
ATTACH MASKING POLICY show_salary ON hr.employee (salary) TO ROLE hr_managers PRIORITY 20;
