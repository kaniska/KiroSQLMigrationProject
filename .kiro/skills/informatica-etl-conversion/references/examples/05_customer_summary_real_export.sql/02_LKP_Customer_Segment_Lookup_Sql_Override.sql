SELECT s.segment_code AS SegmentCode, s.min_lifetime_amount AS MinLifetimeAmount FROM public.customer_segments s WHERE s.is_active ORDER BY s.min_lifetime_amount --
