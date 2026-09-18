-- PROTECTED source layer: never edited by change propagation
CREATE OR REPLACE VIEW src.v_asset AS
SELECT asset_code, asset_desc, last_seen FROM src.asset;
