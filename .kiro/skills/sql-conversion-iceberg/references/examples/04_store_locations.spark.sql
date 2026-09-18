-- Worked example 04 — Spark SQL Iceberg DDL (NOT NULL kept; Athena drops it) and the load expression for the spatial column
CREATE TABLE glue_catalog.sales_lake.store_location (
    store_id int NOT NULL,
    store_code string NOT NULL COMMENT 'source: CHAR(8)',
    location binary NOT NULL COMMENT 'source: GEOGRAPHY as WKB',
    opens_at string COMMENT 'source: TIME(0)',
    last_audited_at timestamp COMMENT 'source: DATETIMEOFFSET(3) (UTC)',
    floor_area float,
    attributes string COMMENT 'source: XML',
    version binary COMMENT 'source: ROWVERSION'
)
USING iceberg
PARTITIONED BY (truncate(2, store_code))
TBLPROPERTIES ('format-version'='2', 'write.format.default'='parquet', 'write.parquet.compression-codec'='zstd');

-- load: the extract exposes Location.STAsBinary() as location_wkb and LastAuditedAt AT TIME ZONE 'UTC' as last_audited_utc
INSERT INTO glue_catalog.sales_lake.store_location
SELECT store_id, rpad(store_code, 8, ' '), location_wkb, date_format(opens_at, 'HH:mm:ss'), last_audited_utc, floor_area, attributes_xml, version_bytes
FROM   src_store_location;
