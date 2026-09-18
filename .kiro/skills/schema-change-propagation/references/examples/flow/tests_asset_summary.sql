SELECT count(*) FROM etl.asset_summary WHERE asset_code IS NULL;
SELECT max(last_seen) FROM etl.asset_summary;
