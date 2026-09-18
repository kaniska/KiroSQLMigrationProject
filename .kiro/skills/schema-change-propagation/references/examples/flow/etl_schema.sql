CREATE TABLE etl.asset_summary (
    asset_code INTEGER NOT NULL,
    asset_desc VARCHAR(200),
    last_seen  TIMESTAMP,
    CONSTRAINT pk_asset_summary PRIMARY KEY (asset_code)
);
