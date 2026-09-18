-- Worked example 04 — Athena Iceberg DDL + a spatial query on the WKB column (IB-19, IB-15, IB-16, IB-18, IB-22)
CREATE TABLE sales_lake.store_location (
    store_id int,
    store_code string COMMENT 'source: CHAR(8)',
    location binary COMMENT 'source: GEOGRAPHY as WKB',
    opens_at string COMMENT 'source: TIME(0)',
    last_audited_at timestamp COMMENT 'source: DATETIMEOFFSET(3) (UTC)',
    floor_area float,
    attributes string COMMENT 'source: XML',
    version binary COMMENT 'source: ROWVERSION'
)
PARTITIONED BY (truncate(2, store_code))
LOCATION 's3://example-lake-bucket/sales_lake/store_location/'
TBLPROPERTIES ('table_type'='ICEBERG', 'format'='parquet', 'write_compression'='zstd');

-- stores within 5 km of a point: Athena geospatial functions read the WKB bytes (the load writes ST_AsBinary of the SQL Server value)
SELECT store_id, store_code,
       ST_Distance(to_spherical_geography(ST_GeomFromBinary(location)), to_spherical_geography(ST_Point(-122.33, 47.61))) AS meters
FROM   sales_lake.store_location
WHERE  ST_Distance(to_spherical_geography(ST_GeomFromBinary(location)), to_spherical_geography(ST_Point(-122.33, 47.61))) <= 5000;

-- row count at the snapshot used for reconciliation (IB-73, V-012)
SELECT count(*) FROM sales_lake.store_location FOR TIMESTAMP AS OF TIMESTAMP '2026-01-01 00:00:00 UTC';
