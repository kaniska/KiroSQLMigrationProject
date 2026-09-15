-- Worked example 03 — SQL Server source
-- Patterns: #temp table, @@ROWCOUNT, PRINT + early RETURN, BEGIN TRAN inside
--           TRY/CATCH, OUTPUT ... INTO @table variable, UPDATE ... FROM join,
--           RAISERROR with a %s argument.
-- Converted: 03_generate_monthly_invoices.postgres.sql
CREATE PROCEDURE dbo.usp_GenerateMonthlyInvoices
    @BillingMonth DATE
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Uninvoiced (
        CustomerId INT, OrderId INT, Amount MONEY
    );

    INSERT INTO #Uninvoiced (CustomerId, OrderId, Amount)
    SELECT o.CustomerId, o.OrderId, o.TotalAmount
    FROM   dbo.Orders o
    WHERE  MONTH(o.CreatedAt) = MONTH(@BillingMonth)
      AND  YEAR(o.CreatedAt)  = YEAR(@BillingMonth)
      AND  o.InvoiceId IS NULL;

    IF @@ROWCOUNT = 0
    BEGIN
        PRINT 'No uninvoiced orders for this period.';
        DROP TABLE #Uninvoiced;
        RETURN;
    END

    DECLARE @NewInvoices TABLE (InvoiceId INT, CustomerId INT);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.Invoices (CustomerId, PeriodStart, TotalAmount, CreatedAt)
        OUTPUT INSERTED.InvoiceId, INSERTED.CustomerId INTO @NewInvoices (InvoiceId, CustomerId)
        SELECT CustomerId, @BillingMonth, SUM(Amount), GETDATE()
        FROM   #Uninvoiced
        GROUP  BY CustomerId;

        UPDATE o
        SET    o.InvoiceId = ni.InvoiceId
        FROM   dbo.Orders o
        JOIN   #Uninvoiced  u  ON u.OrderId     = o.OrderId
        JOIN   @NewInvoices ni ON ni.CustomerId = u.CustomerId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Invoice generation failed: %s', 16, 1, @Err);
    END CATCH

    DROP TABLE #Uninvoiced;
END
GO
