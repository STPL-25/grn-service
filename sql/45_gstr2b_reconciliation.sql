-- ============================================================
-- 45_gstr2b_reconciliation.sql   (Non_trade_Dev ONLY)
--
-- Phase 4: GSTR-2B upload + matching + payment hold.
--
--   * sp_nt_Gstr2bImport takes the parsed rows (B2B invoices + CDNR notes) of one 2B file and runs the matching.
--   * Match key for an invoice row: supplier GSTIN + invoice number (normalised: case, spaces, - / . _ and leading zeros ignored).
--       Matched    amount (and booked taxable value) within Rs 1  -> invoice.itc_status = Eligible / Ineligible (2B "ITC available")
--       Mismatch   same invoice, amounts differ                    -> shown side by side, nothing changes
--       Unmatched  not in books -> candidate suppliers (GSTIN, then name similarity) are shown; Accounts confirms one
--                  and the invoice is added (source RETROSPECTIVE, remark 'Added from GSTR-2B')
--   * ITC 'No' on a booked invoice moves its Input GST to Purchases/Consumables Expense (journal INVOICE_ITC).
--   * Payment hold (enforced in sp_nt_ReleasePaymentNet, sql/44): an invoice of a GST-registered supplier cannot be paid until its
--     itc_status is Eligible/Ineligible, unless Accounts sets an override on that invoice (sp_nt_SetInvoiceHoldOverride).
--   * CDNR (supplier credit/debit note) rows are stored and listed; they are not auto-matched to our notes yet.
-- Re-runnable.
-- ============================================================

-- ── invoice columns ─────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.invoice_info', 'itc_status')            IS NULL ALTER TABLE dbo.invoice_info ADD itc_status VARCHAR(12) NULL;
IF COL_LENGTH('dbo.invoice_info', 'gstr2b_row_sno')        IS NULL ALTER TABLE dbo.invoice_info ADD gstr2b_row_sno INT NULL;
IF COL_LENGTH('dbo.invoice_info', 'payment_hold_override') IS NULL ALTER TABLE dbo.invoice_info ADD payment_hold_override CHAR(1) NULL;
IF COL_LENGTH('dbo.invoice_info', 'hold_override_reason')  IS NULL ALTER TABLE dbo.invoice_info ADD hold_override_reason NVARCHAR(300) NULL;
IF COL_LENGTH('dbo.invoice_info', 'hold_override_by')      IS NULL ALTER TABLE dbo.invoice_info ADD hold_override_by VARCHAR(30) NULL;
IF COL_LENGTH('dbo.invoice_info', 'itc_reclass_journal_sno') IS NULL ALTER TABLE dbo.invoice_info ADD itc_reclass_journal_sno INT NULL;
GO

-- ── normalisers ─────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_nt_NormInvoiceNo (@s NVARCHAR(100))
RETURNS NVARCHAR(100)
AS
BEGIN
    SET @s = UPPER(LTRIM(RTRIM(ISNULL(@s, N''))));
    SET @s = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@s, N' ', N''), N'/', N''), N'-', N''), N'.', N''), N'_', N''), N'\', N''), N'#', N'');
    WHILE LEN(@s) > 1 AND LEFT(@s, 1) = N'0' SET @s = SUBSTRING(@s, 2, 100);
    RETURN @s;
END
GO
CREATE OR ALTER FUNCTION dbo.fn_nt_NormName (@s NVARCHAR(300))
RETURNS NVARCHAR(300)
AS
BEGIN
    SET @s = N' ' + LOWER(ISNULL(@s, N'')) + N' ';
    SET @s = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@s, N'.', N' '), N',', N' '), N'&', N' and '), N'-', N' '), N'(', N' '), N')', N' '), N'/', N' '), N'''', N'');
    SET @s = REPLACE(@s, N'  ', N' '); SET @s = REPLACE(@s, N'  ', N' '); SET @s = REPLACE(@s, N'  ', N' ');
    -- drop legal-form noise words (twice so adjacent ones go too)
    DECLARE @i INT = 0;
    WHILE @i < 2
    BEGIN
        SELECT @s = REPLACE(@s, w, N' ') FROM (VALUES (N' pvt '), (N' private '), (N' ltd '), (N' limited '), (N' llp '), (N' co '), (N' company '), (N' and '), (N' inc '), (N' the ')) x(w);
        SET @i += 1;
    END
    SET @s = REPLACE(@s, N'  ', N' '); SET @s = REPLACE(@s, N'  ', N' ');
    RETURN LTRIM(RTRIM(@s));
END
GO
-- token-overlap similarity of two names, 0..100
CREATE OR ALTER FUNCTION dbo.fn_nt_NameScore (@a NVARCHAR(300), @b NVARCHAR(300))
RETURNS INT
AS
BEGIN
    DECLARE @na NVARCHAR(300) = dbo.fn_nt_NormName(@a), @nb NVARCHAR(300) = dbo.fn_nt_NormName(@b);
    IF @na = N'' OR @nb = N'' RETURN 0;
    IF @na = @nb RETURN 100;
    DECLARE @ta INT = (SELECT COUNT(DISTINCT value) FROM STRING_SPLIT(@na, N' ') WHERE value <> N''),
            @tb INT = (SELECT COUNT(DISTINCT value) FROM STRING_SPLIT(@nb, N' ') WHERE value <> N''),
            @common INT = (SELECT COUNT(*) FROM (SELECT DISTINCT value FROM STRING_SPLIT(@na, N' ') WHERE value <> N'') x
                           JOIN (SELECT DISTINCT value FROM STRING_SPLIT(@nb, N' ') WHERE value <> N'') y ON x.value = y.value);
    IF @ta + @tb = 0 RETURN 0;
    RETURN CAST(200.0 * @common / (@ta + @tb) AS INT);
END
GO

-- ── tables ──────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.gstr2b_upload', 'U') IS NULL
CREATE TABLE dbo.gstr2b_upload (
    upload_sno   INT IDENTITY(1,1) PRIMARY KEY,
    com_sno      INT NULL,
    return_period VARCHAR(6) NOT NULL,           -- MMYYYY
    file_name    NVARCHAR(260) NULL,
    file_hash    VARCHAR(64) NOT NULL,
    row_count    INT NOT NULL DEFAULT 0,
    uploaded_by  VARCHAR(30) NULL,
    uploaded_at  DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_gstr2b_upload_hash')
    CREATE UNIQUE INDEX UX_gstr2b_upload_hash ON dbo.gstr2b_upload (file_hash);
GO
IF OBJECT_ID('dbo.gstr2b_row', 'U') IS NULL
CREATE TABLE dbo.gstr2b_row (
    row_sno        INT IDENTITY(1,1) PRIMARY KEY,
    upload_sno     INT NOT NULL REFERENCES dbo.gstr2b_upload (upload_sno),
    doc_type       VARCHAR(4) NOT NULL DEFAULT 'INV',   -- INV (B2B) | CDN (B2B-CDNR)
    supplier_gstin VARCHAR(20) NOT NULL,
    trade_name     NVARCHAR(200) NULL,
    invoice_no     NVARCHAR(100) NOT NULL,
    norm_invoice_no NVARCHAR(100) NOT NULL,
    invoice_date   DATE NULL,
    invoice_value  DECIMAL(18,2) NOT NULL DEFAULT 0,
    taxable_value  DECIMAL(18,2) NOT NULL DEFAULT 0,
    igst           DECIMAL(18,2) NOT NULL DEFAULT 0,
    cgst           DECIMAL(18,2) NOT NULL DEFAULT 0,
    sgst           DECIMAL(18,2) NOT NULL DEFAULT 0,
    cess           DECIMAL(18,2) NOT NULL DEFAULT 0,
    place_of_supply VARCHAR(40) NULL,
    reverse_charge CHAR(1) NULL,
    itc_available  VARCHAR(5) NULL,                     -- Yes | No | Temp
    itc_reason     NVARCHAR(200) NULL,
    filing_period  VARCHAR(20) NULL,
    irn            VARCHAR(80) NULL,
    match_status   VARCHAR(10) NOT NULL DEFAULT 'New',  -- New | Matched | Mismatch | Unmatched | Added | Skipped | Info
    books_invoice_sno INT NULL,
    mismatch_note  NVARCHAR(300) NULL,
    acted_by       VARCHAR(30) NULL,
    acted_at       DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_gstr2b_row_upload')
    CREATE INDEX IX_gstr2b_row_upload ON dbo.gstr2b_row (upload_sno, match_status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_gstr2b_row_key')
    CREATE INDEX IX_gstr2b_row_key ON dbo.gstr2b_row (supplier_gstin, norm_invoice_no);
GO

-- ── ITC 'No': move booked Input GST to expense ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_ReclassIneligibleITC
    @invoice_sno INT, @by VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cg DECIMAL(18,2), @sg DECIMAL(18,2), @ig DECIMAL(18,2), @vendor INT, @com INT, @div INT, @brn INT, @dept INT, @dt DATE, @booked INT, @done INT, @vno VARCHAR(50);
    SELECT @cg = ISNULL(cgst_amount, 0), @sg = ISNULL(sgst_amount, 0), @ig = ISNULL(igst_amount, 0), @vendor = vendor_sno, @com = com_sno, @div = div_sno,
           @brn = brn_sno, @dept = dept_sno, @dt = ISNULL(invoice_date, CAST(GETDATE() AS DATE)), @booked = gst_journal_sno, @done = itc_reclass_journal_sno, @vno = vendor_invoice_no
    FROM dbo.invoice_info WHERE invoice_sno = @invoice_sno;
    IF @booked IS NULL OR @done IS NOT NULL OR (@cg + @sg + @ig) = 0 RETURN;

    DECLARE @h_exp INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'PURCHASE_EXPENSE'),
            @h_cg INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'INPUT_CGST'),
            @h_sg INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'INPUT_SGST'),
            @h_ig INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'INPUT_IGST'), @j INT;
    INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
    VALUES (@dt, 'INVOICE_ITC', @invoice_sno, N'ITC not available in GSTR-2B: invoice ' + ISNULL(@vno, N'') + N' GST to expense', @com, @div, @brn, @dept, @by);
    SET @j = SCOPE_IDENTITY();
    UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;
    INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) VALUES (@j, @h_exp, @cg + @sg + @ig, 0, @vendor);
    IF @cg > 0 INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) VALUES (@j, @h_cg, 0, @cg, @vendor);
    IF @sg > 0 INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) VALUES (@j, @h_sg, 0, @sg, @vendor);
    IF @ig > 0 INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) VALUES (@j, @h_ig, 0, @ig, @vendor);
    UPDATE dbo.invoice_info SET itc_reclass_journal_sno = @j WHERE invoice_sno = @invoice_sno;
END
GO

-- ── matching ────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bMatch
    @upload_sno INT, @by VARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- 1) find the books invoice for every New invoice row
    UPDATE r SET
        books_invoice_sno = m.invoice_sno,
        match_status = CASE WHEN m.invoice_sno IS NULL THEN 'Unmatched'
                            WHEN ABS(m.invoice_amount - r.invoice_value) <= 1.00
                                 AND (m.taxable_value IS NULL OR ABS(m.taxable_value - r.taxable_value) <= 1.00) THEN 'Matched'
                            ELSE 'Mismatch' END,
        mismatch_note = CASE WHEN m.invoice_sno IS NOT NULL AND NOT (ABS(m.invoice_amount - r.invoice_value) <= 1.00
                                 AND (m.taxable_value IS NULL OR ABS(m.taxable_value - r.taxable_value) <= 1.00))
                             THEN N'Books: invoice ' + CONVERT(NVARCHAR(30), m.invoice_amount) + N', taxable ' + ISNULL(CONVERT(NVARCHAR(30), m.taxable_value), N'-')
                                  + N' | 2B: invoice ' + CONVERT(NVARCHAR(30), r.invoice_value) + N', taxable ' + CONVERT(NVARCHAR(30), r.taxable_value) END
    FROM dbo.gstr2b_row r
    OUTER APPLY (
        SELECT TOP 1 i.invoice_sno, i.invoice_amount, i.taxable_value
        FROM dbo.invoice_info i
        JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
        WHERE i.is_active = 'Y' AND UPPER(LTRIM(RTRIM(k.gst_no))) = r.supplier_gstin
          AND dbo.fn_nt_NormInvoiceNo(i.vendor_invoice_no) = r.norm_invoice_no
        ORDER BY ABS(i.invoice_amount - r.invoice_value)
    ) m
    WHERE r.upload_sno = @upload_sno AND r.doc_type = 'INV' AND r.match_status = 'New';

    UPDATE dbo.gstr2b_row SET match_status = 'Info' WHERE upload_sno = @upload_sno AND doc_type = 'CDN' AND match_status = 'New';

    -- 2) apply the ITC outcome to matched invoices
    UPDATE i SET itc_status = CASE WHEN r.itc_available = 'No' THEN 'Ineligible' ELSE 'Eligible' END, gstr2b_row_sno = r.row_sno
    FROM dbo.invoice_info i JOIN dbo.gstr2b_row r ON r.books_invoice_sno = i.invoice_sno
    WHERE r.upload_sno = @upload_sno AND r.match_status = 'Matched';

    DECLARE @inv INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT r.books_invoice_sno FROM dbo.gstr2b_row r WHERE r.upload_sno = @upload_sno AND r.match_status = 'Matched' AND r.itc_available = 'No';
    OPEN c; FETCH NEXT FROM c INTO @inv;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.sp_nt_ReclassIneligibleITC @invoice_sno = @inv, @by = @by; FETCH NEXT FROM c INTO @inv; END
    CLOSE c; DEALLOCATE c;
END
GO

-- ── import ──────────────────────────────────────────────────────────────────
-- @jsonInput: { com_sno?, return_period:'MMYYYY', file_name, file_hash, uploaded_by,
--   rows: [{ doc_type:'INV'|'CDN', supplier_gstin, trade_name, invoice_no, invoice_date, invoice_value, taxable_value, igst, cgst, sgst, cess,
--            place_of_supply, reverse_charge, itc_available, itc_reason, filing_period, irn }] }
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bImport
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT), @period VARCHAR(6) = JSON_VALUE(@jsonInput, '$.return_period'),
            @fname NVARCHAR(260) = JSON_VALUE(@jsonInput, '$.file_name'), @hash VARCHAR(64) = JSON_VALUE(@jsonInput, '$.file_hash'),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.uploaded_by'), @rows NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.rows');
    IF @period IS NULL OR LEN(@period) <> 6 OR TRY_CAST(@period AS INT) IS NULL THROW 53601, 'return_period must be MMYYYY.', 1;
    IF @hash IS NULL OR @rows IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@rows)) THROW 53602, 'file_hash and at least one row are required.', 1;
    IF EXISTS (SELECT 1 FROM dbo.gstr2b_upload WHERE file_hash = @hash) THROW 53603, 'This file has already been uploaded.', 1;

    DECLARE @u INT;
    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.gstr2b_upload (com_sno, return_period, file_name, file_hash, uploaded_by) VALUES (@com, @period, @fname, @hash, @by);
        SET @u = SCOPE_IDENTITY();
        INSERT INTO dbo.gstr2b_row (upload_sno, doc_type, supplier_gstin, trade_name, invoice_no, norm_invoice_no, invoice_date, invoice_value, taxable_value,
                                    igst, cgst, sgst, cess, place_of_supply, reverse_charge, itc_available, itc_reason, filing_period, irn)
        SELECT @u, CASE WHEN UPPER(ISNULL(x.doc_type, 'INV')) = 'CDN' THEN 'CDN' ELSE 'INV' END, UPPER(LTRIM(RTRIM(x.supplier_gstin))), x.trade_name, LTRIM(RTRIM(x.invoice_no)),
               dbo.fn_nt_NormInvoiceNo(x.invoice_no), x.invoice_date, ISNULL(x.invoice_value, 0), ISNULL(x.taxable_value, 0),
               ISNULL(x.igst, 0), ISNULL(x.cgst, 0), ISNULL(x.sgst, 0), ISNULL(x.cess, 0), x.place_of_supply,
               CASE WHEN UPPER(LEFT(x.reverse_charge, 1)) IN ('Y', 'N') THEN UPPER(LEFT(x.reverse_charge, 1)) END,
               CASE WHEN UPPER(LEFT(x.itc_available, 1)) = 'Y' THEN 'Yes' WHEN UPPER(LEFT(x.itc_available, 1)) = 'N' THEN 'No' WHEN x.itc_available IS NOT NULL THEN 'Temp' END,
               x.itc_reason, x.filing_period, x.irn
        FROM OPENJSON(@rows) WITH (
            doc_type VARCHAR(4) '$.doc_type', supplier_gstin VARCHAR(20) '$.supplier_gstin', trade_name NVARCHAR(200) '$.trade_name',
            invoice_no NVARCHAR(100) '$.invoice_no', invoice_date DATE '$.invoice_date', invoice_value DECIMAL(18,2) '$.invoice_value',
            taxable_value DECIMAL(18,2) '$.taxable_value', igst DECIMAL(18,2) '$.igst', cgst DECIMAL(18,2) '$.cgst', sgst DECIMAL(18,2) '$.sgst',
            cess DECIMAL(18,2) '$.cess', place_of_supply VARCHAR(40) '$.place_of_supply', reverse_charge VARCHAR(5) '$.reverse_charge',
            itc_available VARCHAR(20) '$.itc_available', itc_reason NVARCHAR(200) '$.itc_reason', filing_period VARCHAR(20) '$.filing_period', irn VARCHAR(80) '$.irn'
        ) x
        WHERE NULLIF(LTRIM(RTRIM(x.supplier_gstin)), '') IS NOT NULL AND NULLIF(LTRIM(RTRIM(x.invoice_no)), '') IS NOT NULL;
        UPDATE dbo.gstr2b_upload SET row_count = (SELECT COUNT(*) FROM dbo.gstr2b_row WHERE upload_sno = @u) WHERE upload_sno = @u;
        IF (SELECT row_count FROM dbo.gstr2b_upload WHERE upload_sno = @u) = 0 THROW 53604, 'No usable rows (supplier GSTIN and invoice number are required).', 1;

        EXEC dbo.sp_nt_Gstr2bMatch @upload_sno = @u, @by = @by;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    EXEC dbo.sp_nt_Gstr2bSummary @upload_sno = @u;
END
GO

-- ── reads ───────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bSummary
    @upload_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at,
           SUM(CASE WHEN r.match_status = 'Matched' THEN 1 ELSE 0 END) AS matched,
           SUM(CASE WHEN r.match_status = 'Mismatch' THEN 1 ELSE 0 END) AS mismatch,
           SUM(CASE WHEN r.match_status = 'Unmatched' THEN 1 ELSE 0 END) AS unmatched,
           SUM(CASE WHEN r.match_status = 'Added' THEN 1 ELSE 0 END) AS added,
           SUM(CASE WHEN r.match_status = 'Info' THEN 1 ELSE 0 END) AS notes_info
    FROM dbo.gstr2b_upload u LEFT JOIN dbo.gstr2b_row r ON r.upload_sno = u.upload_sno
    WHERE u.upload_sno = @upload_sno
    GROUP BY u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bListUploads
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at,
           SUM(CASE WHEN r.match_status = 'Matched' THEN 1 ELSE 0 END) AS matched,
           SUM(CASE WHEN r.match_status = 'Mismatch' THEN 1 ELSE 0 END) AS mismatch,
           SUM(CASE WHEN r.match_status = 'Unmatched' THEN 1 ELSE 0 END) AS unmatched,
           SUM(CASE WHEN r.match_status = 'Added' THEN 1 ELSE 0 END) AS added
    FROM dbo.gstr2b_upload u LEFT JOIN dbo.gstr2b_row r ON r.upload_sno = u.upload_sno
    GROUP BY u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at
    ORDER BY u.upload_sno DESC;
END
GO
-- { upload_sno, match_status? }
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bGetRows
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @u INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.upload_sno') AS INT), @s VARCHAR(10) = NULLIF(JSON_VALUE(@jsonInput, '$.match_status'), '');
    SELECT r.row_sno, r.doc_type, r.supplier_gstin, r.trade_name, r.invoice_no, CONVERT(VARCHAR(10), r.invoice_date, 120) AS invoice_date,
           r.invoice_value, r.taxable_value, r.igst, r.cgst, r.sgst, r.cess, r.itc_available, r.itc_reason, r.filing_period, r.match_status,
           r.books_invoice_sno, i.invoice_no AS books_invoice_no, i.invoice_amount AS books_amount, r.mismatch_note
    FROM dbo.gstr2b_row r LEFT JOIN dbo.invoice_info i ON i.invoice_sno = r.books_invoice_sno
    WHERE r.upload_sno = @u AND (@s IS NULL OR r.match_status = @s)
    ORDER BY r.row_sno;
END
GO
-- candidate suppliers for an unmatched row: exact GSTIN first, then name similarity >= 50
-- { row_sno }
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bCandidates
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @row INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.row_sno') AS INT), @gstin VARCHAR(20), @name NVARCHAR(200);
    SELECT @gstin = supplier_gstin, @name = trade_name FROM dbo.gstr2b_row WHERE row_sno = @row;
    SELECT TOP 10 k.kyc_basic_info_sno AS vendor_sno, k.company_name, k.legal_name, k.trade_name, k.gst_no, k.supp_code,
           CASE WHEN UPPER(LTRIM(RTRIM(k.gst_no))) = @gstin THEN 100
                ELSE (SELECT MAX(s) FROM (VALUES (dbo.fn_nt_NameScore(@name, k.company_name)), (dbo.fn_nt_NameScore(@name, k.legal_name)), (dbo.fn_nt_NameScore(@name, k.trade_name))) v(s)) END AS score,
           CASE WHEN UPPER(LTRIM(RTRIM(k.gst_no))) = @gstin THEN 'GSTIN' ELSE 'NAME' END AS matched_on
    FROM dbo.kyc_basic_info k
    WHERE k.is_active = 'Y'
      AND (UPPER(LTRIM(RTRIM(k.gst_no))) = @gstin
           OR (SELECT MAX(s) FROM (VALUES (dbo.fn_nt_NameScore(@name, k.company_name)), (dbo.fn_nt_NameScore(@name, k.legal_name)), (dbo.fn_nt_NameScore(@name, k.trade_name))) v(s)) >= 50)
    ORDER BY score DESC, k.company_name;
END
GO

-- ── act on an unmatched row ─────────────────────────────────────────────────
-- confirm a supplier: adds the invoice to the books (RETROSPECTIVE, GST already per 2B, ITC status per 2B)
-- { row_sno, vendor_sno, confirmed_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bConfirmSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @row INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.row_sno') AS INT), @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.confirmed_by');
    IF @row IS NULL OR @v IS NULL OR @by IS NULL THROW 53610, 'row_sno, vendor_sno and confirmed_by are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @v AND is_active = 'Y') THROW 53611, 'Supplier not found.', 1;

    DECLARE @status VARCHAR(10), @gstin VARCHAR(20), @ino NVARCHAR(100), @idate DATE, @ival DECIMAL(18,2), @tx DECIMAL(18,2), @ig DECIMAL(18,2), @cg DECIMAL(18,2),
            @sg DECIMAL(18,2), @itc VARCHAR(5), @com INT, @doc VARCHAR(4);
    SELECT @status = r.match_status, @gstin = r.supplier_gstin, @ino = r.invoice_no, @idate = r.invoice_date, @ival = r.invoice_value, @tx = r.taxable_value,
           @ig = r.igst, @cg = r.cgst, @sg = r.sgst, @itc = r.itc_available, @com = u.com_sno, @doc = r.doc_type
    FROM dbo.gstr2b_row r JOIN dbo.gstr2b_upload u ON u.upload_sno = r.upload_sno WHERE r.row_sno = @row;
    IF @status IS NULL THROW 53612, 'Row not found.', 1;
    IF @doc <> 'INV' THROW 53613, 'Only invoice rows can be added; credit/debit note rows are informational.', 1;
    IF @status NOT IN ('Unmatched', 'Mismatch') THROW 53614, 'This row is already matched, added or skipped.', 1;
    IF @status = 'Mismatch' THROW 53615, 'This invoice already exists in the books (amounts differ). Correct the books invoice instead of adding another.', 1;

    DECLARE @intra BIT = CASE WHEN @ig > 0 THEN 0 WHEN (@cg + @sg) > 0 THEN 1 ELSE NULL END,
            @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT, @invno VARCHAR(30), @inv INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(invoice_no, 6) AS INT)), 0) + 1 FROM dbo.invoice_info WITH (UPDLOCK, HOLDLOCK) WHERE invoice_no LIKE 'INV-' + @year + '-%';
        SET @invno = 'INV-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        INSERT INTO dbo.invoice_info (invoice_no, vendor_invoice_no, vendor_sno, com_sno, invoice_date, invoice_amount, invoice_type, source_type, match_status, remarks,
                                      is_active, created_by, created_date, supplier_gstin, taxable_value, cgst_amount, sgst_amount, igst_amount, is_intrastate, itc_status, gstr2b_row_sno)
        VALUES (@invno, LEFT(@ino, 50), @v, @com, @idate, @ival, 'MATERIAL', 'RETROSPECTIVE', 'Pending', 'Added from GSTR-2B',
                'Y', @by, GETDATE(), @gstin, @tx, @cg, @sg, @ig, @intra, CASE WHEN @itc = 'No' THEN 'Ineligible' ELSE 'Eligible' END, @row);
        SET @inv = SCOPE_IDENTITY();

        UPDATE dbo.gstr2b_row SET match_status = 'Added', books_invoice_sno = @inv, acted_by = @by, acted_at = GETDATE() WHERE row_sno = @row;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT @inv AS invoice_sno, @invno AS invoice_no, 'Added' AS match_status;
END
GO

-- { row_sno, skipped_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bSkipRow
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @row INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.row_sno') AS INT), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.skipped_by');
    UPDATE dbo.gstr2b_row SET match_status = 'Skipped', acted_by = @by, acted_at = GETDATE() WHERE row_sno = @row AND match_status IN ('Unmatched', 'Mismatch');
    IF @@ROWCOUNT = 0 THROW 53616, 'Row not found or not open for action.', 1;
    SELECT row_sno, match_status FROM dbo.gstr2b_row WHERE row_sno = @row;
END
GO

-- ── our invoices that are not in 2B yet (GST-registered suppliers, still Pending 2B) ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bMissingIn2B
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no, CONVERT(VARCHAR(10), i.invoice_date, 120) AS invoice_date, i.vendor_sno, k.company_name AS vendor_name, k.gst_no,
           i.invoice_amount, i.taxable_value, i.itc_status, i.payment_hold_override
    FROM dbo.invoice_info i JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    WHERE i.is_active = 'Y' AND LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, 'Pending 2B') = 'Pending 2B'
    ORDER BY i.invoice_date, i.invoice_sno;
END
GO

-- ── Accounts override of the payment hold ───────────────────────────────────
-- { invoice_sno, override: 'Y'|'N', reason (required for Y), by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_SetInvoiceHoldOverride
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inv INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT), @o CHAR(1) = UPPER(JSON_VALUE(@jsonInput, '$.override')),
            @reason NVARCHAR(300) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.by');
    IF @o NOT IN ('Y', 'N') THROW 53620, 'override must be Y or N.', 1;
    IF @o = 'Y' AND @reason IS NULL THROW 53621, 'A reason is required to release the hold.', 1;
    UPDATE dbo.invoice_info SET payment_hold_override = @o, hold_override_reason = CASE WHEN @o = 'Y' THEN @reason END, hold_override_by = @by, modified_by = @by, modified_date = GETDATE()
    WHERE invoice_sno = @inv;
    IF @@ROWCOUNT = 0 THROW 53622, 'Invoice not found.', 1;
    SELECT invoice_sno, payment_hold_override, hold_override_reason, itc_status FROM dbo.invoice_info WHERE invoice_sno = @inv;
END
GO
