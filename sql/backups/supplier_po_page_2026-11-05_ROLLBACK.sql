-- Rollback for sql/89_supplier_po_page_amounts.sql: restores the three procedures exactly as they were on Non_trade_Dev before it ran
-- (captured from OBJECT_DEFINITION on 2026-11-05).

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPOsForSupplier
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

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPODetailForSupplier
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
        COALESCE(NULLIF(LTRIM(RTRIM(p.delivery_address)), ''),
                 NULLIF(LTRIM(RTRIM(addr.branch_address)), ''),
                 NULLIF(LTRIM(RTRIM(addr.company_address)), '')) AS delivery_address,
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
              AND i.is_active IN ('Y','1')
            FOR JSON PATH
        )                                        AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.company_master c   ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = p.vendor_sno
    OUTER APPLY (
        SELECT TOP 1 v.branch_address, v.company_address
        FROM dbo.vw_ActiveDeptRecords v
        WHERE v.brn_sno = p.brn_sno AND v.dept_sno = p.dept_sno
    ) addr
    WHERE p.is_active IN ('Y','1')
      AND p.po_basic_sno = @po_basic_sno
      AND p.vendor_sno = @kyc_basic_info_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_AcceptPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @po_basic_sno       INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    IF NOT EXISTS (
        SELECT 1 FROM dbo.po_request_info
        WHERE po_basic_sno = @po_basic_sno AND vendor_sno = @kyc_basic_info_sno AND is_active = 'Y'
    )
    BEGIN
        RAISERROR('PO not found for this supplier.', 16, 1);
        RETURN;
    END

    UPDATE dbo.po_request_info
    SET supplier_ack_status = 'Accepted',
        supplier_ack_date = GETDATE()
    WHERE po_basic_sno = @po_basic_sno;

    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SUPPLIER_ACK', CAST(@kyc_basic_info_sno AS VARCHAR(50)), 'PO accepted by supplier', 'Y');

    SELECT po_basic_sno, supplier_ack_status,
           CONVERT(VARCHAR(30), supplier_ack_date, 120) AS supplier_ack_date
    FROM dbo.po_request_info
    WHERE po_basic_sno = @po_basic_sno;
END;
GO
