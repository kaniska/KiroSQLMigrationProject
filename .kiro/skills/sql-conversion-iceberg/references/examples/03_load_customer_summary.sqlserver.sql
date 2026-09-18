-- Worked example 03 — SQL Server set-based load procedure with a result set
-- Patterns: OUTPUT parameter, SET NOCOUNT, BEGIN TRAN/TRY/CATCH, SELECT INTO #temp, MERGE with
--           WHEN MATCHED AND … / WHEN NOT MATCHED BY SOURCE, @@ROWCOUNT, RETURN code, final SELECT.
-- Converted: 03_load_customer_summary.spark.sql (source transformation) + 03_load_customer_summary.job.json → 03_load_customer_summary.glue.py
CREATE PROCEDURE dbo.usp_LoadCustomerSummary
    @AsOf DATE,
    @RowsMerged INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRAN;
        SELECT c.CustomerKey, SUM(f.LineTotal) AS Revenue, MAX(f.SaleDate) AS LastSale
        INTO   #stage
        FROM   dbo.DimCustomer c JOIN dbo.FactSales f ON f.CustomerKey = c.CustomerKey
        WHERE  f.SaleDate <= @AsOf
        GROUP BY c.CustomerKey;

        MERGE dbo.CustomerSummary AS t
        USING #stage AS s ON t.CustomerKey = s.CustomerKey
        WHEN MATCHED AND s.Revenue <> t.Revenue THEN UPDATE SET Revenue = s.Revenue, LastSale = s.LastSale, UpdatedAt = GETDATE()
        WHEN NOT MATCHED BY TARGET THEN INSERT (CustomerKey, Revenue, LastSale, UpdatedAt) VALUES (s.CustomerKey, s.Revenue, s.LastSale, GETDATE())
        WHEN NOT MATCHED BY SOURCE THEN DELETE;
        SET @RowsMerged = @@ROWCOUNT;
        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        RAISERROR('usp_LoadCustomerSummary failed', 16, 1);
        RETURN 1;
    END CATCH;
    SELECT CustomerKey, Revenue FROM dbo.CustomerSummary WHERE LastSale >= DATEADD(day, -7, @AsOf);
    RETURN 0;
END
