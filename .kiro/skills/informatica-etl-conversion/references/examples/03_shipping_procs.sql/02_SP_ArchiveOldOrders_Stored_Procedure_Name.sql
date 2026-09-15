-- name: public.archive_old_orders
-- Stored Procedure Type "Source Pre Load". PowerCenter's Stored Procedure transformation does not run
-- against PostgreSQL connections (verify for your connector, IC-13): move the call into the
-- Source Qualifier's Pre SQL as
SELECT public.archive_old_orders($$ARCHIVE_DAYS)
