-- sql/87: supplier uploads a LEDGER against a debit / credit note - for one note, or for an invoice (covers every debit and credit
-- note on that invoice).
--
-- Why: the supplier portal's "Debit / Credit Notes" screen was read-only. The supplier has to send us their ledger (statement of
-- account) so the deduction / addition can be matched to their books. Two scopes, one table:
--   scope 'NOTE'    - a single debit or credit note (note_kind + note_sno)
--   scope 'INVOICE' - one upload for an invoice (invoice_no); it applies to ALL debit + credit notes on that invoice
-- The file itself goes to the FTP server (NON_TRADE_DATAS/NOTE_LEDGERS) from grn-service; only its URL is stored here.
--
-- "The invoice of a note" = the supplier's invoice number from the Gate Entry the GRN came in on (nt_gate_entry.invoice_no, via
-- grn_basic_info.gate_entry_sno). A debit note carries it already (debit_note_basic_info.vendor_invoice_no, sql/21). A credit note
-- never stored it (sql/71 returned NULL) - so the two credit-note read procedures below now resolve it from the gate entry, the same
-- way, otherwise a credit note could never be part of an invoice ledger. fn_nt_SupplierNoteKeys is the ONE place that decides which
-- invoice a note belongs to; the list procedures and the upload check both go through the same rule.
-- Notes without an invoice number (gate entry has none) can only take a per-note ledger.
--
-- A supplier can only upload against / see / remove their own (vendor_sno) rows - every procedure takes kyc_basic_info_sno from the
-- portal login, never from the request body.  Removing is a soft delete (is_active = 'N').
--
-- Re-runnable.  Rollback: sql/backups/supplier_note_ledger_2026-11-05_ROLLBACK.sql (drops the 3 procs + function + table and
-- restores the old credit-note procedures).

IF OBJECT_ID('dbo.supplier_note_ledger', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.supplier_note_ledger (
        ledger_sno    INT IDENTITY(1,1) PRIMARY KEY,
        vendor_sno    INT           NOT NULL,
        scope         VARCHAR(10)   NOT NULL,
        note_kind     VARCHAR(6)    NULL,
        note_sno      INT           NULL,
        invoice_no    VARCHAR(100)  NULL,
        file_url      VARCHAR(500)  NOT NULL,
        file_name     VARCHAR(255)  NULL,
        remarks       VARCHAR(500)  NULL,
        uploaded_by   VARCHAR(100)  NULL,
        uploaded_date DATETIME      NOT NULL DEFAULT GETDATE(),
        is_active     CHAR(1)       NOT NULL DEFAULT 'Y',
        CONSTRAINT CK_supplier_note_ledger_scope CHECK (
            (scope = 'NOTE'    AND note_kind IN ('DEBIT', 'CREDIT') AND note_sno IS NOT NULL AND invoice_no IS NULL)
         OR (scope = 'INVOICE' AND invoice_no IS NOT NULL AND note_kind IS NULL AND note_sno IS NULL)
        )
    );
    CREATE INDEX IX_supplier_note_ledger_vendor ON dbo.supplier_note_ledger (vendor_sno, is_active);
END
GO

-- Every live debit + credit note of one supplier with the invoice number it belongs to (NULL when there is none).
CREATE OR ALTER FUNCTION dbo.fn_nt_SupplierNoteKeys (@vendor_sno INT)
RETURNS TABLE
AS
RETURN
(
    SELECT 'DEBIT' AS note_kind, b.debit_note_sno AS note_sno,
           NULLIF(LTRIM(RTRIM(b.vendor_invoice_no)), '') AS invoice_no
    FROM dbo.debit_note_basic_info b
    WHERE b.is_active = 'Y' AND b.vendor_sno = @vendor_sno
    UNION ALL
    SELECT 'CREDIT', c.credit_note_sno,
           NULLIF(LTRIM(RTRIM(ge.invoice_no)), '')
    FROM dbo.credit_note_basic_info c
    JOIN dbo.grn_basic_info g          ON g.grn_basic_sno = c.grn_basic_sno
    LEFT JOIN dbo.nt_gate_entry ge     ON ge.gate_entry_sno = g.gate_entry_sno
    WHERE c.is_active = 'Y' AND c.vendor_sno = @vendor_sno
);
GO

-- Credit notes now show (and group by) the supplier's invoice, like debit notes do.
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
        k.invoice_no                                 AS vendor_invoice_no,
        CONVERT(VARCHAR(10), ge.invoice_date, 120)   AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.credit_note_date, 120) AS credit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status
    FROM dbo.credit_note_basic_info b
    JOIN dbo.grn_basic_info g       ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.nt_gate_entry ge  ON ge.gate_entry_sno = g.gate_entry_sno
    LEFT JOIN dbo.fn_nt_SupplierNoteKeys(@kyc_basic_info_sno) k ON k.note_kind = 'CREDIT' AND k.note_sno = b.credit_note_sno
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
        k.invoice_no                                 AS vendor_invoice_no,
        CONVERT(VARCHAR(10), ge.invoice_date, 120)   AS vendor_invoice_date,
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
    LEFT JOIN dbo.nt_gate_entry ge  ON ge.gate_entry_sno = g.gate_entry_sno
    LEFT JOIN dbo.fn_nt_SupplierNoteKeys(@kyc_basic_info_sno) k ON k.note_kind = 'CREDIT' AND k.note_sno = b.credit_note_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    WHERE b.credit_note_sno = @credit_note_sno
      AND b.vendor_sno = @kyc_basic_info_sno
      AND b.is_active = 'Y';
END;
GO

-- Records one uploaded ledger (the file is already on the FTP server; this stores its URL).
-- @jsonInput: { kyc_basic_info_sno, scope: 'NOTE'|'INVOICE', note_kind: 'DEBIT'|'CREDIT', note_sno, invoice_no, file_url, file_name,
--               remarks, uploaded_by }
-- Errors 58101-58106 are written for the supplier (grn-service passes them through as they are).
CREATE OR ALTER PROCEDURE dbo.sp_nt_AddSupplierNoteLedger
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT           = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @scope      VARCHAR(10)   = UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.scope'))));
    DECLARE @note_kind  VARCHAR(6)    = UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.note_kind'))));
    DECLARE @note_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.note_sno') AS INT);
    DECLARE @invoice_no VARCHAR(100)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.invoice_no'))), '');
    DECLARE @file_url   VARCHAR(500)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.file_url'))), '');
    DECLARE @file_name  VARCHAR(255)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.file_name'))), '');
    DECLARE @remarks    VARCHAR(500)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), '');
    DECLARE @uploaded_by VARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uploaded_by'))), '');

    IF @file_url IS NULL
    BEGIN
        THROW 58101, 'Choose the ledger file to upload.', 1;
    END

    IF @scope = 'NOTE'
    BEGIN
        IF @note_kind NOT IN ('DEBIT', 'CREDIT') OR @note_kind IS NULL OR @note_sno IS NULL
        BEGIN
            THROW 58102, 'Choose the debit or credit note this ledger is for.', 1;
        END
        IF NOT EXISTS (SELECT 1 FROM dbo.fn_nt_SupplierNoteKeys(@vendor_sno) WHERE note_kind = @note_kind AND note_sno = @note_sno)
        BEGIN
            THROW 58103, 'That debit / credit note was not found for your account.', 1;
        END
        SET @invoice_no = NULL;
    END
    ELSE IF @scope = 'INVOICE'
    BEGIN
        IF @invoice_no IS NULL
        BEGIN
            THROW 58104, 'Choose the invoice this ledger is for.', 1;
        END
        -- store the invoice text exactly as the notes carry it (the screen groups on that text)
        DECLARE @canonical VARCHAR(100);
        SELECT TOP 1 @canonical = invoice_no FROM dbo.fn_nt_SupplierNoteKeys(@vendor_sno) WHERE invoice_no = @invoice_no;
        IF @canonical IS NULL
        BEGIN
            THROW 58105, 'None of your debit / credit notes is on that invoice.', 1;
        END
        SET @invoice_no = @canonical;
        SET @note_kind = NULL;
        SET @note_sno = NULL;
    END
    ELSE
    BEGIN
        THROW 58106, 'Upload the ledger against a single note or against an invoice.', 1;
    END

    INSERT INTO dbo.supplier_note_ledger (vendor_sno, scope, note_kind, note_sno, invoice_no, file_url, file_name, remarks, uploaded_by)
    VALUES (@vendor_sno, @scope, @note_kind, @note_sno, @invoice_no, @file_url, @file_name, @remarks, @uploaded_by);

    SELECT l.ledger_sno, l.scope, l.note_kind, l.note_sno, l.invoice_no, l.file_url, l.file_name, l.remarks, l.uploaded_by,
           CONVERT(VARCHAR(19), l.uploaded_date, 120) AS uploaded_date
    FROM dbo.supplier_note_ledger l
    WHERE l.ledger_sno = SCOPE_IDENTITY();
END;
GO

-- All the live ledgers this supplier has uploaded (the screen matches them to notes / invoices).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierNoteLedgers
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT l.ledger_sno, l.scope, l.note_kind, l.note_sno, l.invoice_no, l.file_url, l.file_name, l.remarks, l.uploaded_by,
           CONVERT(VARCHAR(19), l.uploaded_date, 120) AS uploaded_date
    FROM dbo.supplier_note_ledger l
    WHERE l.vendor_sno = @vendor_sno
      AND l.is_active = 'Y'
    ORDER BY l.ledger_sno DESC;
END;
GO

-- Takes one of the supplier's own ledgers off the screen (soft delete).
CREATE OR ALTER PROCEDURE dbo.sp_nt_RemoveSupplierNoteLedger
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @ledger_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.ledger_sno') AS INT);

    UPDATE dbo.supplier_note_ledger
    SET is_active = 'N'
    WHERE ledger_sno = @ledger_sno AND vendor_sno = @vendor_sno AND is_active = 'Y';

    IF @@ROWCOUNT = 0
    BEGIN
        THROW 58107, 'That ledger was not found (it may already be removed).', 1;
    END

    SELECT @ledger_sno AS ledger_sno;
END;
GO
