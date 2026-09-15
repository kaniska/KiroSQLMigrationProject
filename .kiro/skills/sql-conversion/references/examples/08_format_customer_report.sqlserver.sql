-- Worked example 08 — SQL Server source
-- Patterns: string and date built-ins whose PostgreSQL look-alikes behave
--           differently: DATEDIFF(year), LEN, CHARINDEX, REPLICATE with a
--           possibly negative count, FORMAT, CONVERT(..., 101).
-- Converted: 08_format_customer_report.postgres.sql
CREATE PROCEDURE dbo.usp_FormatCustomerReport
    @CustomerId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        UPPER(LEFT(c.FirstName, 1)) + LOWER(SUBSTRING(c.FirstName, 2, LEN(c.FirstName)))
                                                   AS FormattedFirstName,
        DATEDIFF(year, c.BirthDate, GETDATE())     AS Age,
        FORMAT(c.CreatedAt, 'MMM dd, yyyy')        AS JoinDate,
        CHARINDEX('@', c.Email)                    AS AtPosition,
        REPLICATE('*', LEN(c.Phone) - 4) + RIGHT(c.Phone, 4)
                                                   AS MaskedPhone,
        CONVERT(VARCHAR, DATEADD(day, 30, GETDATE()), 101)
                                                   AS TrialExpiry
    FROM dbo.Customers c
    WHERE c.CustomerId = @CustomerId;
END
GO
