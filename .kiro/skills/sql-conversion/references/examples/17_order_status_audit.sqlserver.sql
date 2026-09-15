-- Worked example 17 — SQL Server source
-- Patterns: AFTER UPDATE trigger, inserted/deleted pseudo-tables (one row
--           per affected row, statement-level firing), IF NOT UPDATE(col),
--           ISNULL-based change detection (treats NULL and '' as equal).
-- Converted: 17_order_status_audit.postgres.sql
-- Audit table: dbo.OrderStatusAudit (see 00_sample_schema.sqlserver.sql)
CREATE TRIGGER dbo.tr_Orders_StatusAudit
ON dbo.Orders
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(Status)
        RETURN;

    INSERT INTO dbo.OrderStatusAudit (OrderId, OldStatus, NewStatus)
    SELECT i.OrderId, d.Status, i.Status
    FROM   inserted i
    JOIN   deleted  d ON d.OrderId = i.OrderId
    WHERE  ISNULL(d.Status, '') <> ISNULL(i.Status, '');
END
GO
