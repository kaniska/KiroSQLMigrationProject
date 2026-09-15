-- ============================================================
-- Source: SQL Server schema (T-SQL DDL)
-- File: source/schema/sales_db_schema.sql
-- Databases: SalesDB + InventoryDB
-- Description: Table definitions that every procedure in source/,
--              examples/ and the sql-conversion skill's worked
--              examples reads or writes.
--              The legacy procedures were split across SalesDB and
--              InventoryDB, which share Products and Warehouses.
--              The migration consolidates both into ONE PostgreSQL
--              database (schema public).
-- Converted equivalent: generated/schema.sql
-- ============================================================

USE [SalesDB]
GO

-- ------------------------------------------------------------
-- Reference data
-- ------------------------------------------------------------
CREATE TABLE [dbo].[Categories] (
    CategoryId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Categories PRIMARY KEY,
    CategoryName  NVARCHAR(100)     NOT NULL CONSTRAINT UQ_Categories_CategoryName UNIQUE
);
GO

CREATE TABLE [dbo].[Warehouses] (
    WarehouseId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Warehouses PRIMARY KEY,
    WarehouseName  NVARCHAR(100)     NOT NULL
);
GO

-- ------------------------------------------------------------
-- Customers
-- ------------------------------------------------------------
CREATE TABLE [dbo].[Customers] (
    CustomerId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Customers PRIMARY KEY,
    ExternalId  UNIQUEIDENTIFIER  NULL,
    FirstName   NVARCHAR(100)     NOT NULL,
    LastName    NVARCHAR(100)     NOT NULL,
    Email       NVARCHAR(255)     NOT NULL CONSTRAINT UQ_Customers_Email UNIQUE,
    Phone       VARCHAR(20)       NULL,
    BirthDate   DATE              NULL,
    ReferredBy  INT               NULL
        CONSTRAINT FK_Customers_ReferredBy REFERENCES [dbo].[Customers] (CustomerId),
    CreatedAt   DATETIME2         NOT NULL CONSTRAINT DF_Customers_CreatedAt DEFAULT SYSDATETIME(),
    UpdatedAt   DATETIME2         NULL
);
GO

-- SQL Server UNIQUE allows only one NULL, hence the filtered index.
CREATE UNIQUE NONCLUSTERED INDEX UX_Customers_ExternalId
    ON [dbo].[Customers] (ExternalId)
    WHERE ExternalId IS NOT NULL;
GO

-- ------------------------------------------------------------
-- Products & inventory
-- ------------------------------------------------------------
CREATE TABLE [dbo].[Products] (
    ProductId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Products PRIMARY KEY,
    SKU                VARCHAR(50)       NOT NULL CONSTRAINT UQ_Products_SKU UNIQUE,
    ProductName        NVARCHAR(200)     NOT NULL,
    Category           NVARCHAR(100)     NULL,   -- legacy denormalised name; reporting procs group by it
    CategoryId         INT               NULL
        CONSTRAINT FK_Products_Categories REFERENCES [dbo].[Categories] (CategoryId),
    Price              MONEY             NOT NULL CONSTRAINT DF_Products_Price DEFAULT 0,
    WeightLbs          DECIMAL(10,3)     NULL,
    IsActive           BIT               NOT NULL CONSTRAINT DF_Products_IsActive DEFAULT 1,
    ReorderPoint       INT               NULL,
    ReorderQuantity    INT               NOT NULL CONSTRAINT DF_Products_ReorderQuantity DEFAULT 50,
    DefaultWarehouseId INT               NULL
        CONSTRAINT FK_Products_Warehouses REFERENCES [dbo].[Warehouses] (WarehouseId),
    CreatedAt          DATETIME2         NOT NULL CONSTRAINT DF_Products_CreatedAt DEFAULT SYSDATETIME(),
    UpdatedAt          DATETIME2         NULL
);
GO

CREATE TABLE [dbo].[Inventory] (
    ProductId      INT       NOT NULL
        CONSTRAINT FK_Inventory_Products REFERENCES [dbo].[Products] (ProductId),
    WarehouseId    INT       NOT NULL
        CONSTRAINT FK_Inventory_Warehouses REFERENCES [dbo].[Warehouses] (WarehouseId),
    QuantityOnHand INT       NOT NULL CONSTRAINT DF_Inventory_QuantityOnHand DEFAULT 0,
    LastUpdated    DATETIME2 NULL,
    LastRestocked  DATETIME  NULL,
    CONSTRAINT PK_Inventory PRIMARY KEY CLUSTERED (ProductId, WarehouseId)
);
GO

CREATE TABLE [dbo].[InventoryAudit] (
    AuditId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryAudit PRIMARY KEY,
    ProductId    INT               NOT NULL,
    WarehouseId  INT               NOT NULL,
    PreviousQty  INT               NOT NULL,
    Adjustment   INT               NOT NULL,
    NewQty       INT               NOT NULL,
    Reason       NVARCHAR(200)     NULL,
    AdjustedBy   NVARCHAR(100)     NOT NULL,
    AdjustedAt   DATETIME2         NOT NULL
);
GO

CREATE TABLE [dbo].[PurchaseOrders] (
    PurchaseOrderId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrders PRIMARY KEY,
    ProductId       INT               NOT NULL
        CONSTRAINT FK_PurchaseOrders_Products REFERENCES [dbo].[Products] (ProductId),
    WarehouseId     INT               NOT NULL
        CONSTRAINT FK_PurchaseOrders_Warehouses REFERENCES [dbo].[Warehouses] (WarehouseId),
    Quantity        INT               NOT NULL,
    Status          VARCHAR(20)       NOT NULL,   -- Draft | Submitted | InTransit | Received
    CreatedBy       NVARCHAR(100)     NOT NULL,
    CreatedAt       DATETIME          NOT NULL
);
GO

CREATE TABLE [dbo].[ProductStaging] (
    StagingId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductStaging PRIMARY KEY,
    ProductId     INT               NULL,
    SKU           VARCHAR(50)       NOT NULL,
    ProductName   NVARCHAR(200)     NOT NULL,
    Price         MONEY             NOT NULL,
    CategoryId    INT               NULL,
    IsActive      BIT               NOT NULL CONSTRAINT DF_ProductStaging_IsActive DEFAULT 1,
    EffectiveDate DATE              NOT NULL,
    ExpiresDate   DATE              NULL
);
GO

CREATE TABLE [dbo].[PriceAudit] (
    PriceAuditId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PriceAudit PRIMARY KEY,
    ProductId    INT               NOT NULL,
    OldPrice     MONEY             NOT NULL,
    NewPrice     MONEY             NOT NULL,
    ChangedAt    DATETIME          NOT NULL
);
GO

CREATE TABLE [dbo].[StockTransfers] (
    TransferId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockTransfers PRIMARY KEY,
    FromWarehouseId INT               NOT NULL,
    ToWarehouseId   INT               NOT NULL,
    ProductId       INT               NOT NULL,
    Quantity        INT               NOT NULL,
    TransferredBy   NVARCHAR(100)     NOT NULL,
    TransferredAt   DATETIME2         NOT NULL
);
GO

-- ------------------------------------------------------------
-- Sales
-- ------------------------------------------------------------
CREATE TABLE [dbo].[Coupons] (
    CouponId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Coupons PRIMARY KEY,
    Code        NVARCHAR(50)      NOT NULL CONSTRAINT UQ_Coupons_Code UNIQUE,
    DiscountPct DECIMAL(5,2)      NOT NULL,
    IsActive    BIT               NOT NULL CONSTRAINT DF_Coupons_IsActive DEFAULT 1,
    ExpiresAt   DATETIME2         NOT NULL,
    UseCount    INT               NOT NULL CONSTRAINT DF_Coupons_UseCount DEFAULT 0
);
GO

CREATE TABLE [dbo].[Invoices] (
    InvoiceId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Invoices PRIMARY KEY,
    CustomerId  INT               NOT NULL
        CONSTRAINT FK_Invoices_Customers REFERENCES [dbo].[Customers] (CustomerId),
    PeriodStart DATE              NOT NULL,
    TotalAmount MONEY             NOT NULL,
    CreatedAt   DATETIME2         NOT NULL
);
GO

CREATE TABLE [dbo].[Orders] (
    OrderId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY,
    CustomerId       INT               NOT NULL
        CONSTRAINT FK_Orders_Customers REFERENCES [dbo].[Customers] (CustomerId),
    CreatedAt        DATETIME2         NOT NULL CONSTRAINT DF_Orders_CreatedAt DEFAULT SYSDATETIME(),
    TotalAmount      MONEY             NOT NULL,
    DiscountPct      DECIMAL(5,2)      NOT NULL CONSTRAINT DF_Orders_DiscountPct DEFAULT 0,
    Notes            NVARCHAR(500)     NULL,
    Status           VARCHAR(50)       NOT NULL CONSTRAINT DF_Orders_Status DEFAULT 'Pending',
    RequiresApproval BIT               NOT NULL CONSTRAINT DF_Orders_RequiresApproval DEFAULT 0,
    InvoiceId        INT               NULL
        CONSTRAINT FK_Orders_Invoices REFERENCES [dbo].[Invoices] (InvoiceId),
    UpdatedAt        DATETIME2         NULL,
    ProcessedAt      DATETIME2         NULL
);
GO

CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_Status
    ON [dbo].[Orders] (CustomerId, Status)
    INCLUDE (TotalAmount, CreatedAt);
GO

CREATE NONCLUSTERED INDEX IX_Orders_CreatedAt
    ON [dbo].[Orders] (CreatedAt DESC);
GO

CREATE TABLE [dbo].[OrderLines] (
    LineId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OrderLines PRIMARY KEY,
    OrderId    INT               NOT NULL
        CONSTRAINT FK_OrderLines_Orders REFERENCES [dbo].[Orders] (OrderId),
    ProductId  INT               NOT NULL
        CONSTRAINT FK_OrderLines_Products REFERENCES [dbo].[Products] (ProductId),
    Quantity   SMALLINT          NOT NULL,
    UnitPrice  MONEY             NOT NULL,
    LineTotal  MONEY             NULL
);
GO

CREATE TABLE [dbo].[Refunds] (
    RefundId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Refunds PRIMARY KEY,
    OrderId     INT               NOT NULL
        CONSTRAINT FK_Refunds_Orders REFERENCES [dbo].[Orders] (OrderId),
    Amount      MONEY             NOT NULL,
    Reason      NVARCHAR(500)     NULL,
    ProcessedBy NVARCHAR(100)     NOT NULL,
    ProcessedAt DATETIME          NOT NULL,
    Status      NVARCHAR(20)      NOT NULL
);
GO

CREATE TABLE [dbo].[ProcessingErrors] (
    ErrorId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProcessingErrors PRIMARY KEY,
    OrderId      INT               NULL,
    ErrorMessage NVARCHAR(4000)    NULL,
    OccurredAt   DATETIME          NOT NULL
);
GO

-- ------------------------------------------------------------
-- HR (used by the org-chart worked example)
-- ------------------------------------------------------------
CREATE TABLE [dbo].[Employees] (
    EmployeeId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Employees PRIMARY KEY,
    ManagerId    INT               NULL
        CONSTRAINT FK_Employees_Manager REFERENCES [dbo].[Employees] (EmployeeId),
    EmployeeName NVARCHAR(200)     NOT NULL,
    Title        NVARCHAR(100)     NULL
);
GO
