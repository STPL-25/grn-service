-- ============================================================
-- grn_item_details table
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- ============================================================

IF OBJECT_ID('dbo.grn_item_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.grn_item_details (
        grn_item_sno       INT IDENTITY(1,1) PRIMARY KEY,
        grn_basic_sno      INT,
        po_item_sno        INT,
        prod_sno           INT,
        prod_name          VARCHAR(200),
        specification      VARCHAR(200),
        po_qty             DECIMAL(10,3),
        received_qty       DECIMAL(10,3),
        diff_qty           DECIMAL(10,3),
        unit               INT,
        unit_name          VARCHAR(200),
        po_unit_price      DECIMAL(10,2),
        received_unit_price DECIMAL(10,2),
        diff_unit_price    DECIMAL(10,2),
        total_po_cost      DECIMAL(10,2),
        total_grn_cost     DECIMAL(10,2),
        total_diff_cost    DECIMAL(10,2),
        hsn_sno            INT,
        hsn_code           VARCHAR(10),
        tax_pct            DECIMAL(5,2),
        net_cost           DECIMAL(10,2),
        remarks            VARCHAR(200),
        created_by         VARCHAR(20),
        created_date       DATE DEFAULT (GETDATE()),
        modifed_by         VARCHAR(20),
        modifed_date       DATE,
        is_active          CHAR(1) DEFAULT 'Y'
    );
END
GO
