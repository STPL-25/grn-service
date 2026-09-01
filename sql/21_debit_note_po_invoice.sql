-- ============================================================
-- Debit Note: PO-scoped numbering + seller's invoice number
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Follow-up to grn-service/sql/20_debit_note.sql, per direct user request:
-- "debit note ... maintained in table generated based on po number not by
-- supplier alone ... should have invoice no of seller."
--
-- Two changes:
--   1. debit_note_no changes from a global per-year sequence
--      (DN-2026-000001) to a sequence scoped per PO, embedding the PO's own
--      display number: DN-<po_df_no>-NNN (NNN resets per PO).
--   2. debit_note_basic_info gains vendor_invoice_no / vendor_invoice_date,
--      resolved server-side from dbo.nt_gate_entry (the seller's invoice,
--      already captured there as a required field at Gate Entry — the
--      receiving step just before GRN) via grn_basic_info.gate_entry_sno.
--      Same "caller never supplies it directly" pattern as
--      po_basic_sno/vendor_sno/etc in sp_nt_CreateDebitNote.
--
-- Run after grn-service/sql/20_debit_note.sql.
-- ============================================================

-- ── Schema ────────────────────────────────────────────────────────────────

-- debit_note_no now embeds the PO's po_df_no (VARCHAR(50) live) — widen
-- from VARCHAR(30) so 'DN-' + po_df_no + '-NNN' can never truncate.
IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'debit_note_basic_info' AND COLUMN_NAME = 'debit_note_no' AND CHARACTER_MAXIMUM_LENGTH < 60
)
    ALTER TABLE dbo.debit_note_basic_info ALTER COLUMN debit_note_no VARCHAR(60) NOT NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'debit_note_basic_info' AND COLUMN_NAME = 'vendor_invoice_no'
)
    ALTER TABLE dbo.debit_note_basic_info ADD vendor_invoice_no VARCHAR(100) NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'debit_note_basic_info' AND COLUMN_NAME = 'vendor_invoice_date'
)
    ALTER TABLE dbo.debit_note_basic_info ADD vendor_invoice_date DATE NULL;
GO

-- ============================================================
-- sp_nt_CreateDebitNote (replaces the version in 20_debit_note.sql)
-- @jsonInput: { grn_basic_sno, remarks, created_by,
--   items: [{ grn_item_sno, po_item_sno, prod_sno, prod_name, specification,
--             unit_name, reason_type, qty, unit_price, remarks }]
-- }
-- Resolves po_basic_sno/vendor_sno/com_sno/div_sno/brn_sno/dept_sno AND now
-- vendor_invoice_no/vendor_invoice_date from grn_basic_info (via its
-- gate_entry_sno) server-side — caller still only ever supplies
-- grn_basic_sno.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateDebitNote', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateDebitNote;
GO

CREATE PROCEDURE dbo.sp_nt_CreateDebitNote
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @grn_basic_sno INT           = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @remarks       VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @created_by    VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @items         NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

    IF @grn_basic_sno IS NULL
    BEGIN
        RAISERROR('grn_basic_sno is required.', 16, 1);
        RETURN;
    END

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
    BEGIN
        RAISERROR('At least one item is required.', 16, 1);
        RETURN;
    END

    DECLARE @po_basic_sno INT, @vendor_sno INT, @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @gate_entry_sno INT;

    SELECT @po_basic_sno = po_basic_sno, @vendor_sno = vendor_sno,
           @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno,
           @gate_entry_sno = gate_entry_sno
    FROM dbo.grn_basic_info
    WHERE grn_basic_sno = @grn_basic_sno AND is_active = 'Y';

    IF @po_basic_sno IS NULL
    BEGIN
        RAISERROR('GRN not found.', 16, 1);
        RETURN;
    END

    DECLARE @po_no VARCHAR(50);
    SELECT @po_no = po_df_no FROM dbo.po_request_info WHERE po_basic_sno = @po_basic_sno;
    IF @po_no IS NULL OR LEN(LTRIM(RTRIM(@po_no))) = 0
        SET @po_no = 'PO' + CAST(@po_basic_sno AS VARCHAR(20));

    DECLARE @vendor_invoice_no VARCHAR(100), @vendor_invoice_date DATE;
    IF @gate_entry_sno IS NOT NULL
        SELECT @vendor_invoice_no = invoice_no, @vendor_invoice_date = invoice_date
        FROM dbo.nt_gate_entry
        WHERE gate_entry_sno = @gate_entry_sno;

    DECLARE @lineItems TABLE (
        grn_item_sno   INT,
        po_item_sno    INT,
        prod_sno       INT,
        prod_name      VARCHAR(255),
        specification  VARCHAR(500),
        unit_name      VARCHAR(50),
        reason_type    VARCHAR(20),
        qty            DECIMAL(18,2),
        unit_price     DECIMAL(18,2),
        remarks        VARCHAR(500)
    );

    INSERT INTO @lineItems (grn_item_sno, po_item_sno, prod_sno, prod_name, specification, unit_name, reason_type, qty, unit_price, remarks)
    SELECT grn_item_sno, po_item_sno, prod_sno, prod_name, specification, unit_name, reason_type, qty, ISNULL(unit_price, 0), remarks
    FROM OPENJSON(@items)
    WITH (
        grn_item_sno   INT           '$.grn_item_sno',
        po_item_sno    INT           '$.po_item_sno',
        prod_sno       INT           '$.prod_sno',
        prod_name      VARCHAR(255)  '$.prod_name',
        specification  VARCHAR(500)  '$.specification',
        unit_name      VARCHAR(50)   '$.unit_name',
        reason_type    VARCHAR(20)   '$.reason_type',
        qty            DECIMAL(18,2) '$.qty',
        unit_price     DECIMAL(18,2) '$.unit_price',
        remarks        VARCHAR(500)  '$.remarks'
    );

    IF EXISTS (SELECT 1 FROM @lineItems WHERE qty IS NULL OR qty <= 0)
    BEGIN
        RAISERROR('Every item requires a quantity greater than 0.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @lineItems WHERE reason_type NOT IN ('Damage', 'Shortage', 'Return'))
    BEGIN
        RAISERROR('reason_type must be Damage, Shortage or Return.', 16, 1);
        RETURN;
    END

    DECLARE @debit_note_sno INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        -- Sequence resets per PO: DN-<po_df_no>-001, DN-<po_df_no>-002, ...
        DECLARE @prefix VARCHAR(56) = 'DN-' + @po_no + '-';
        DECLARE @seq INT;

        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(debit_note_no, 3) AS INT)), 0) + 1
        FROM dbo.debit_note_basic_info
        WHERE po_basic_sno = @po_basic_sno
          AND debit_note_no LIKE @prefix + '%';

        DECLARE @debit_note_no VARCHAR(60) = @prefix + RIGHT('000' + CAST(@seq AS VARCHAR(3)), 3);

        DECLARE @total_qty DECIMAL(18,2), @total_amount DECIMAL(18,2);
        SELECT @total_qty = SUM(qty), @total_amount = SUM(qty * unit_price) FROM @lineItems;

        INSERT INTO dbo.debit_note_basic_info (
            debit_note_no, grn_basic_sno, po_basic_sno, vendor_sno, com_sno, div_sno, brn_sno, dept_sno,
            debit_note_date, total_qty, total_amount, remarks, status, is_active, created_by, created_date,
            vendor_invoice_no, vendor_invoice_date
        )
        VALUES (
            @debit_note_no, @grn_basic_sno, @po_basic_sno, @vendor_sno, @com_sno, @div_sno, @brn_sno, @dept_sno,
            GETDATE(), @total_qty, @total_amount, @remarks, 'Raised', 'Y', @created_by, GETDATE(),
            @vendor_invoice_no, @vendor_invoice_date
        );

        SET @debit_note_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.debit_note_item_details (
            debit_note_sno, grn_item_sno, po_item_sno, prod_sno, prod_name, specification,
            unit_name, reason_type, qty, unit_price, amount, remarks, is_active
        )
        SELECT
            @debit_note_sno, grn_item_sno, po_item_sno, prod_sno, prod_name, specification,
            unit_name, reason_type, qty, unit_price, (qty * unit_price), remarks, 'Y'
        FROM @lineItems;

        INSERT INTO dbo.debit_note_history_data (
            event_type, debit_note_sno, po_basic_sno, grn_basic_sno, remarks, status_by
        )
        VALUES (
            'Debit Note Raised', @debit_note_sno, @po_basic_sno, @grn_basic_sno, @remarks, @created_by
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        b.debit_note_sno,
        b.debit_note_no,
        b.grn_basic_sno,
        b.po_basic_sno,
        @po_no                                        AS po_no,
        b.vendor_sno,
        b.vendor_invoice_no,
        CONVERT(VARCHAR(10), b.vendor_invoice_date, 120) AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.debit_note_date, 120)  AS debit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status,
        CONVERT(VARCHAR(30), b.created_date, 120) AS created_at
    FROM dbo.debit_note_basic_info b
    WHERE b.debit_note_sno = @debit_note_sno;
END;
GO

-- ============================================================
-- sp_nt_GetAllDebitNotes  (internal — "our screen") — adds vendor_invoice_no/date
-- @jsonInput optional: { status }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAllDebitNotes', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAllDebitNotes;
GO

CREATE PROCEDURE dbo.sp_nt_GetAllDebitNotes
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @status = JSON_VALUE(@jsonInput, '$.status');

    SELECT
        b.debit_note_sno,
        b.debit_note_no,
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        b.vendor_sno,
        k.company_name                               AS vendor_name,
        c.com_name                                   AS com_name,
        b.vendor_invoice_no,
        CONVERT(VARCHAR(10), b.vendor_invoice_date, 120) AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.debit_note_date, 120)  AS debit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status,
        b.created_by                                  AS raised_by,
        CONVERT(VARCHAR(30), b.created_date, 120)      AS created_at,
        (
            SELECT
                di.debit_note_item_sno,
                di.grn_item_sno,
                di.po_item_sno,
                di.prod_sno,
                di.prod_name,
                di.specification,
                di.unit_name,
                di.reason_type,
                di.qty,
                di.unit_price,
                di.amount,
                di.remarks
            FROM dbo.debit_note_item_details di
            WHERE di.debit_note_sno = b.debit_note_sno
              AND di.is_active = 'Y'
            FOR JSON PATH
        )                                              AS items
    FROM dbo.debit_note_basic_info b
    JOIN dbo.grn_basic_info g       ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    WHERE b.is_active = 'Y'
      AND (@status IS NULL OR b.status = @status)
    ORDER BY b.debit_note_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetDebitNotesByGRN  (internal) — adds vendor_invoice_no/date + po_no
-- @jsonInput: { grn_basic_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetDebitNotesByGRN', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetDebitNotesByGRN;
GO

CREATE PROCEDURE dbo.sp_nt_GetDebitNotesByGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');

    SELECT
        b.debit_note_sno,
        b.debit_note_no,
        b.grn_basic_sno,
        b.po_basic_sno,
        p.po_df_no                                   AS po_no,
        b.vendor_sno,
        b.vendor_invoice_no,
        CONVERT(VARCHAR(10), b.vendor_invoice_date, 120) AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.debit_note_date, 120) AS debit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status,
        b.created_by                                  AS raised_by,
        CONVERT(VARCHAR(30), b.created_date, 120)      AS created_at,
        (
            SELECT
                di.debit_note_item_sno,
                di.grn_item_sno,
                di.po_item_sno,
                di.prod_sno,
                di.prod_name,
                di.specification,
                di.unit_name,
                di.reason_type,
                di.qty,
                di.unit_price,
                di.amount,
                di.remarks
            FROM dbo.debit_note_item_details di
            WHERE di.debit_note_sno = b.debit_note_sno
              AND di.is_active = 'Y'
            FOR JSON PATH
        )                                              AS items
    FROM dbo.debit_note_basic_info b
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    WHERE b.grn_basic_sno = @grn_basic_sno
      AND b.is_active = 'Y'
    ORDER BY b.debit_note_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetDebitNotesForSupplier  (supplier portal — ownership-checked)
-- adds vendor_invoice_no/date
-- @jsonInput: { kyc_basic_info_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetDebitNotesForSupplier', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetDebitNotesForSupplier;
GO

CREATE PROCEDURE dbo.sp_nt_GetDebitNotesForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT
        b.debit_note_sno,
        b.debit_note_no,
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        c.com_name                                   AS com_name,
        b.vendor_invoice_no,
        CONVERT(VARCHAR(10), b.vendor_invoice_date, 120) AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.debit_note_date, 120)  AS debit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status
    FROM dbo.debit_note_basic_info b
    JOIN dbo.grn_basic_info g       ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    WHERE b.is_active = 'Y'
      AND b.vendor_sno = @kyc_basic_info_sno
    ORDER BY b.debit_note_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetDebitNoteDetailForSupplier  (supplier portal — ownership-checked)
-- adds vendor_invoice_no/date
-- @jsonInput: { kyc_basic_info_sno, debit_note_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetDebitNoteDetailForSupplier', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetDebitNoteDetailForSupplier;
GO

CREATE PROCEDURE dbo.sp_nt_GetDebitNoteDetailForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @debit_note_sno     INT = JSON_VALUE(@jsonInput, '$.debit_note_sno');

    SELECT
        b.debit_note_sno,
        b.debit_note_no,
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        c.com_name                                   AS com_name,
        b.vendor_invoice_no,
        CONVERT(VARCHAR(10), b.vendor_invoice_date, 120) AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.debit_note_date, 120)  AS debit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status,
        (
            SELECT
                di.debit_note_item_sno,
                di.prod_name,
                di.specification,
                di.unit_name,
                di.reason_type,
                di.qty,
                di.unit_price,
                di.amount,
                di.remarks
            FROM dbo.debit_note_item_details di
            WHERE di.debit_note_sno = b.debit_note_sno
              AND di.is_active = 'Y'
            FOR JSON PATH
        )                                              AS items
    FROM dbo.debit_note_basic_info b
    JOIN dbo.grn_basic_info g       ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    WHERE b.debit_note_sno = @debit_note_sno
      AND b.vendor_sno = @kyc_basic_info_sno
      AND b.is_active = 'Y';
END;
GO
