-- name: public.calculate_shipping
-- Connected Stored Procedure transformation: rebuild it as a SQL transformation (query mode) with the
-- same ports bound as ?port? placeholders (IC-13). Query:
SELECT shipping_cost FROM public.calculate_shipping(?OrderId?, ?ShipToZip?, ?IsExpedited?)
