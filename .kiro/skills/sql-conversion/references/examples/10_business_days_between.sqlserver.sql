-- Worked example 10 — SQL Server source
-- Patterns: scalar user-defined function (fn_ prefix), WHILE loop with
--           CONTINUE, compound assignment (+=), DATEPART(weekday) — which
--           depends on SET DATEFIRST (default 7 = Sunday is day 1).
-- Converted: 10_business_days_between.postgres.sql
CREATE FUNCTION dbo.fn_BusinessDaysBetween (
    @StartDate DATE,
    @EndDate   DATE
)
RETURNS INT
AS
BEGIN
    IF @StartDate IS NULL OR @EndDate IS NULL
        RETURN NULL;

    DECLARE @Days INT = 0;
    DECLARE @d    DATE = @StartDate;

    WHILE @d < @EndDate
    BEGIN
        SET @d = DATEADD(day, 1, @d);

        IF DATEPART(weekday, @d) IN (1, 7)   -- Sunday, Saturday under DATEFIRST 7
            CONTINUE;

        SET @Days += 1;
    END

    RETURN @Days;
END
GO
