-- Worked example 17 — PostgreSQL conversion of 17_order_status_audit.sqlserver.sql
-- Key decisions:
--   * SQL Server triggers fire once per STATEMENT with the inserted/deleted
--     sets → FOR EACH STATEMENT trigger with transition tables:
--     REFERENCING OLD TABLE AS deleted NEW TABLE AS inserted. The body keeps
--     its set-based INSERT … SELECT unchanged.
--   * The trigger body becomes a separate RETURNS trigger function named
--     trg_<table>_<event>_fn; tr_Orders_StatusAudit → trg_orders_status_audit.
--   * IF NOT UPDATE(Status): transition tables cannot be combined with
--     UPDATE OF <column> in PostgreSQL, so the trigger fires on every UPDATE.
--     The WHERE clause already filters unchanged rows, so the audit rows are
--     identical.
--   * ISNULL(x, '') <> ISNULL(y, '') is kept as COALESCE (NULL and '' compare
--     equal). IS DISTINCT FROM would change behaviour (H1).
--   * AFTER statement triggers return NULL.
CREATE OR REPLACE FUNCTION public.trg_orders_status_audit_fn()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.order_status_audit (order_id, old_status, new_status)
    SELECT i.order_id, d.status, i.status
    FROM   inserted i
    JOIN   deleted  d ON d.order_id = i.order_id
    WHERE  COALESCE(d.status, '') <> COALESCE(i.status, '');
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER trg_orders_status_audit
    AFTER UPDATE ON public.orders
    REFERENCING OLD TABLE AS deleted NEW TABLE AS inserted
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.trg_orders_status_audit_fn();

-- Usage:
-- UPDATE public.orders SET status = 'Shipped' WHERE order_id = 1;
-- SELECT * FROM public.order_status_audit;
