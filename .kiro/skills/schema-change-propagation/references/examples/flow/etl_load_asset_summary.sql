-- target-layer load (editable)
CREATE OR REPLACE PROCEDURE etl.load_asset_summary()
LANGUAGE plpgsql AS $$
BEGIN
    -- asset_code comes from the protected source view; 'asset_code' literal must stay
    INSERT INTO etl.asset_summary (asset_code, asset_desc, last_seen)
    SELECT s.asset_code, s.asset_desc, s.last_seen
    FROM   src.v_asset s
    ON CONFLICT (asset_code) DO UPDATE SET asset_desc = EXCLUDED.asset_desc, last_seen = EXCLUDED.last_seen;
    RAISE NOTICE 'loaded asset_code rows into asset_summary';
END;
$$;
CREATE OR REPLACE VIEW etl.v_asset_summary_report AS
SELECT a.asset_code, a.asset_desc, a.last_seen, l.asset_code_label
FROM   etl.asset_summary a
       LEFT JOIN lookup.asset_code_labels l ON l.asset_code = a.asset_code;
