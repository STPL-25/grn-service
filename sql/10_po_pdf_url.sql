-- ============================================================
-- 10_po_pdf_url.sql
-- Adds po_pdf_url to po_request_info so the supplier portal can offer
-- the final-approved PO PDF (emailed + FTP-stored on final approval) as a
-- download. Idempotent — safe to re-run.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'po_pdf_url')
    ALTER TABLE dbo.po_request_info ADD po_pdf_url NVARCHAR(500) NULL;
GO

-- ============================================================
-- sp_nt_GetPOsForSupplier (adds p.po_pdf_url)
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPOsForSupplier', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPOsForSupplier;
GO

CREATE PROCEDURE dbo.sp_nt_GetPOsForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        p.delivery_address,
        p.status,
        p.supplier_ack_status,
        CONVERT(VARCHAR(30), p.supplier_ack_date, 120) AS supplier_ack_date,
        p.po_pdf_url,
        c.com_name                              AS com_name,
        (
            SELECT COUNT(*)
            FROM dbo.nt_dispatch_slip d
            WHERE d.po_basic_sno = p.po_basic_sno
        )                                        AS dispatch_count
    FROM dbo.po_request_info p
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    WHERE p.is_active = 'Y'
      AND p.vendor_sno = @kyc_basic_info_sno
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetPODetailForSupplier (adds p.po_pdf_url)
-- @jsonInput: { kyc_basic_info_sno, po_basic_sno }
-- Ownership-checked: only returns a row if the PO belongs to this supplier.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPODetailForSupplier', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPODetailForSupplier;
GO

CREATE PROCEDURE dbo.sp_nt_GetPODetailForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @po_basic_sno       INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        p.delivery_address,
        p.terms_conditions,
        p.purpose,
        p.status,
        p.supplier_ack_status,
        CONVERT(VARCHAR(30), p.supplier_ack_date, 120) AS supplier_ack_date,
        p.po_pdf_url,
        c.com_name                              AS com_name,
        k.company_name                          AS vendor_name,
        (
            SELECT
                i.po_item_sno,
                i.prod_sno,
                i.prod_name,
                i.specification,
                i.qty            AS ordered_qty,
                i.unit_name      AS unit_name,
                i.agreed_unit_price AS unit_price,
                i.net_cost       AS total_amount
            FROM dbo.po_item_details i
            WHERE i.po_basic_sno = p.po_basic_sno
              AND i.is_active = 'Y'
            FOR JSON PATH
        )                                        AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.company_master c   ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE p.is_active = 'Y'
      AND p.po_basic_sno = @po_basic_sno
      AND p.vendor_sno = @kyc_basic_info_sno;
END;
GO
