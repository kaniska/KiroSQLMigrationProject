-- Worked example 04 — spatial and time-zone columns (GEOGRAPHY → WKB binary, DATETIMEOFFSET → UTC timestamp, TIME → string)
-- Converted: 04_store_locations.athena.sql + 04_store_locations.spark.sql (design file: 04_store_locations.design.json)
CREATE TABLE dbo.StoreLocation (
    StoreId        INT NOT NULL PRIMARY KEY,
    StoreCode      CHAR(8) NOT NULL,
    Location       GEOGRAPHY NOT NULL,
    OpensAt        TIME(0) NULL,
    LastAuditedAt  DATETIMEOFFSET(3) NULL,
    FloorArea      REAL NULL,
    Attributes     XML NULL,
    Version        ROWVERSION
);
