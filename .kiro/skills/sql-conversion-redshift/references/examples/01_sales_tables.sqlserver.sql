-- Worked example 01 — SQL Server DDL for a warehouse load (fact + dimension)
-- Patterns: IDENTITY, NVARCHAR/MONEY/BIT/UNIQUEIDENTIFIER/DATETIME2, CHECK, computed column,
--           filtered unique index, FK, default GETDATE()/NEWID().
-- Converted: 01_sales_tables.redshift.sql (design file: 01_sales_tables.design.json)
CREATE TABLE dbo.DimCustomer (
    CustomerKey     INT IDENTITY(1,1) NOT NULL,
    CustomerId      UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    CustomerName    NVARCHAR(200) NOT NULL,
    Region          VARCHAR(50) NOT NULL,
    IsActive        BIT NOT NULL DEFAULT 1,
    Notes           NVARCHAR(MAX) NULL,
    CreatedAt       DATETIME2(3) NOT NULL CONSTRAINT DF_DimCustomer_CreatedAt DEFAULT SYSDATETIME(),
    CONSTRAINT PK_DimCustomer PRIMARY KEY CLUSTERED (CustomerKey),
    CONSTRAINT CK_DimCustomer_Region CHECK (Region IN ('EMEA', 'AMER', 'APAC'))
);
CREATE UNIQUE NONCLUSTERED INDEX UX_DimCustomer_Name ON dbo.DimCustomer (CustomerName) WHERE IsActive = 1;

CREATE TABLE dbo.FactSales (
    SalesKey        BIGINT IDENTITY(1,1) NOT NULL,
    CustomerKey     INT NOT NULL,
    SaleDate        DATE NOT NULL,
    Quantity        SMALLINT NOT NULL,
    UnitPrice       MONEY NOT NULL,
    LineTotal       AS (Quantity * UnitPrice) PERSISTED,
    LoadedAt        DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_FactSales PRIMARY KEY (SalesKey),
    CONSTRAINT FK_FactSales_Customer FOREIGN KEY (CustomerKey) REFERENCES dbo.DimCustomer (CustomerKey)
);
CREATE NONCLUSTERED INDEX IX_FactSales_SaleDate ON dbo.FactSales (SaleDate, CustomerKey);
