-- ROLLBACK for sql/87_supplier_note_ledger.sql (2026-11-05).
-- Puts the two credit-note read procedures back as sql/71 defined them (invoice columns NULL), then drops the ledger procs,
-- the function and the table. Uploaded ledger rows are LOST (the files stay on the FTP server under NON_TRADE_DATAS/NOTE_LEDGERS).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetCreditNotesForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT
        b.credit_note_sno,
        b.credit_note_no,
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.po_basic_sno,
        p.po_df_no                                   AS po_no,
        c.com_name                                   AS com_name,
        CAST(NULL AS VARCHAR(50))                    AS vendor_invoice_no,
        CAST(NULL AS VARCHAR(10))                    AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.credit_note_date, 120) AS credit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status
    FROM dbo.credit_note_basic_info b
    JOIN dbo.grn_basic_info g       ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    WHERE b.is_active = 'Y'
      AND b.vendor_sno = @kyc_basic_info_sno
    ORDER BY b.credit_note_sno DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetCreditNoteDetailForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @credit_note_sno    INT = JSON_VALUE(@jsonInput, '$.credit_note_sno');

    SELECT
        b.credit_note_sno,
        b.credit_note_no,
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.po_basic_sno,
        p.po_df_no                                   AS po_no,
        c.com_name                                   AS com_name,
        CAST(NULL AS VARCHAR(50))                    AS vendor_invoice_no,
        CAST(NULL AS VARCHAR(10))                    AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.credit_note_date, 120) AS credit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status,
        (
            SELECT
                ci.credit_note_item_sno,
                ci.prod_name,
                ci.specification,
                ci.unit_name,
                ci.reason_type,
                ci.qty,
                ci.unit_price,
                ci.amount,
                ci.remarks
            FROM dbo.credit_note_item_details ci
            WHERE ci.credit_note_sno = b.credit_note_sno
              AND ci.is_active = 'Y'
            FOR JSON PATH
        )                                              AS items
    FROM dbo.credit_note_basic_info b
    JOIN dbo.grn_basic_info g       ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    WHERE b.credit_note_sno = @credit_note_sno
      AND b.vendor_sno = @kyc_basic_info_sno
      AND b.is_active = 'Y';
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_nt_AddSupplierNoteLedger;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetSupplierNoteLedgers;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_RemoveSupplierNoteLedger;
GO
DROP FUNCTION IF EXISTS dbo.fn_nt_SupplierNoteKeys;
GO
DROP TABLE IF EXISTS dbo.supplier_note_ledger;
GO
