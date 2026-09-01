-- ============================================================
-- Debit Note module — tables + stored procedures
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/debitnote (internal, /api/debit_note) and
--            grn-service/src/supplier (supplier portal, /api/supplier)
--
-- A debit note is raised by staff against a specific GRN when goods
-- received are damaged, short of the ordered quantity, or being returned
-- to the supplier. It records the quantity/amount being charged back to
-- the vendor, per GRN line. Raised here means visible to the supplier in
-- their own portal (ownership-checked by vendor_sno, same pattern as the
-- PO/dispatch procs in 09_supplier_portal.sql) and listed internally on
-- the GRN screen ("our screen").
--
-- All procedures follow this codebase's convention: a single optional
-- @jsonInput NVARCHAR(MAX) parameter, fields read via JSON_VALUE/JSON_QUERY.
-- ============================================================

-- ── Tables ────────────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.debit_note_basic_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.debit_note_basic_info (
        debit_note_sno   INT IDENTITY(1,1) PRIMARY KEY,
        debit_note_no    VARCHAR(30)   NOT NULL UNIQUE,
        grn_basic_sno    INT           NOT NULL,
        po_basic_sno     INT           NOT NULL,
        vendor_sno       INT           NULL,
        com_sno          INT           NULL,
        div_sno          INT           NULL,
        brn_sno          INT           NULL,
        dept_sno         INT           NULL,
        debit_note_date  DATE          NOT NULL DEFAULT (GETDATE()),
        total_qty        DECIMAL(18,2) NOT NULL DEFAULT 0,
        total_amount     DECIMAL(18,2) NOT NULL DEFAULT 0,
        remarks          VARCHAR(500)  NULL,
        status           VARCHAR(20)   NOT NULL DEFAULT 'Raised',
        is_active        CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by       VARCHAR(20)   NULL,
        created_date     DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_debit_note_basic_info_grn
            FOREIGN KEY (grn_basic_sno) REFERENCES dbo.grn_basic_info (grn_basic_sno)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_debit_note_basic_info_grn_basic_sno' AND object_id = OBJECT_ID('dbo.debit_note_basic_info'))
    CREATE INDEX IX_debit_note_basic_info_grn_basic_sno ON dbo.debit_note_basic_info (grn_basic_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_debit_note_basic_info_po_basic_sno' AND object_id = OBJECT_ID('dbo.debit_note_basic_info'))
    CREATE INDEX IX_debit_note_basic_info_po_basic_sno ON dbo.debit_note_basic_info (po_basic_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_debit_note_basic_info_vendor_sno' AND object_id = OBJECT_ID('dbo.debit_note_basic_info'))
    CREATE INDEX IX_debit_note_basic_info_vendor_sno ON dbo.debit_note_basic_info (vendor_sno);
GO

IF OBJECT_ID('dbo.debit_note_item_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.debit_note_item_details (
        debit_note_item_sno INT IDENTITY(1,1) PRIMARY KEY,
        debit_note_sno       INT           NOT NULL,
        grn_item_sno          INT           NULL,
        po_item_sno           INT           NULL,
        prod_sno               INT           NULL,
        prod_name               VARCHAR(255)  NULL,
        specification            VARCHAR(500)  NULL,
        unit_name                 VARCHAR(50)   NULL,
        -- Damage | Shortage | Return
        reason_type                VARCHAR(20)   NOT NULL,
        qty                          DECIMAL(18,2) NOT NULL,
        unit_price                    DECIMAL(18,2) NOT NULL DEFAULT 0,
        amount                          DECIMAL(18,2) NOT NULL DEFAULT 0,
        remarks                          VARCHAR(500)  NULL,
        is_active                         CHAR(1)       NOT NULL DEFAULT 'Y',
        CONSTRAINT FK_debit_note_item_details_note
            FOREIGN KEY (debit_note_sno) REFERENCES dbo.debit_note_basic_info (debit_note_sno)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_debit_note_item_details_debit_note_sno' AND object_id = OBJECT_ID('dbo.debit_note_item_details'))
    CREATE INDEX IX_debit_note_item_details_debit_note_sno ON dbo.debit_note_item_details (debit_note_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_debit_note_item_details_grn_item_sno' AND object_id = OBJECT_ID('dbo.debit_note_item_details'))
    CREATE INDEX IX_debit_note_item_details_grn_item_sno ON dbo.debit_note_item_details (grn_item_sno);
GO

IF OBJECT_ID('dbo.debit_note_history_data', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.debit_note_history_data (
        debit_note_history_sno INT IDENTITY(1,1) PRIMARY KEY,
        event_type               VARCHAR(30)   NOT NULL,
        debit_note_sno            INT           NOT NULL,
        po_basic_sno               INT           NULL,
        grn_basic_sno                INT           NULL,
        remarks                       VARCHAR(500)  NULL,
        status_by                      VARCHAR(50)   NULL,
        status_at                        DATETIME      NOT NULL DEFAULT (GETDATE()),
        CONSTRAINT FK_debit_note_history_data_note
            FOREIGN KEY (debit_note_sno) REFERENCES dbo.debit_note_basic_info (debit_note_sno)
    );
END
GO

-- ============================================================
-- sp_nt_GetGRNDiscrepancyItems
-- @jsonInput: { grn_basic_sno }
-- Internal use — feeds the "Raise Debit Note" form's prefill. Returns one
-- row per grn_item_details line on this GRN that has a discrepancy
-- (rejected/damaged qty, or received short of ordered), with a suggested
-- reason_type/qty/unit_price, and remaining_qty netted against whatever has
-- already been put on an earlier (still-active) debit note for that same
-- GRN line — so re-opening the form after a partial debit note doesn't
-- offer to double-charge the same shortfall.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetGRNDiscrepancyItems', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetGRNDiscrepancyItems;
GO

CREATE PROCEDURE dbo.sp_nt_GetGRNDiscrepancyItems
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');

    SELECT
        gi.grn_item_sno,
        gi.po_item_sno,
        gi.prod_sno,
        gi.prod_name,
        gi.specification,
        gi.unit_name,
        gi.po_qty                                   AS ordered_qty,
        gi.received_qty,
        gi.rejected_qty,
        gi.condition,
        ISNULL(pi.agreed_unit_price, gi.received_unit_price) AS unit_price,
        CASE WHEN gi.condition = 'Damaged' THEN 'Damage'
             WHEN ISNULL(gi.received_qty, 0) < ISNULL(gi.po_qty, 0) THEN 'Shortage'
             ELSE 'Damage'
        END                                          AS suggested_reason_type,
        (
            ISNULL(gi.rejected_qty, 0)
            + CASE WHEN ISNULL(gi.received_qty, 0) < ISNULL(gi.po_qty, 0)
                   THEN (ISNULL(gi.po_qty, 0) - ISNULL(gi.received_qty, 0))
                   ELSE 0
              END
        )                                            AS discrepancy_qty,
        ISNULL(dn.already_debited_qty, 0)             AS already_debited_qty,
        (
            (
                ISNULL(gi.rejected_qty, 0)
                + CASE WHEN ISNULL(gi.received_qty, 0) < ISNULL(gi.po_qty, 0)
                       THEN (ISNULL(gi.po_qty, 0) - ISNULL(gi.received_qty, 0))
                       ELSE 0
                  END
            ) - ISNULL(dn.already_debited_qty, 0)
        )                                            AS remaining_qty
    FROM dbo.grn_item_details gi
    LEFT JOIN dbo.po_item_details pi ON pi.po_item_sno = gi.po_item_sno
    LEFT JOIN (
        SELECT di.grn_item_sno, SUM(di.qty) AS already_debited_qty
        FROM dbo.debit_note_item_details di
        JOIN dbo.debit_note_basic_info db ON db.debit_note_sno = di.debit_note_sno
        WHERE di.is_active = 'Y' AND db.is_active = 'Y'
        GROUP BY di.grn_item_sno
    ) dn ON dn.grn_item_sno = gi.grn_item_sno
    WHERE gi.grn_basic_sno = @grn_basic_sno
      AND gi.is_active = 'Y'
      AND (
            ISNULL(gi.rejected_qty, 0) > 0
            OR gi.condition = 'Damaged'
            OR ISNULL(gi.received_qty, 0) < ISNULL(gi.po_qty, 0)
          )
    ORDER BY gi.grn_item_sno;
END;
GO

-- ============================================================
-- sp_nt_CreateDebitNote
-- @jsonInput: {
--   grn_basic_sno, remarks, created_by,
--   items: [{ grn_item_sno, po_item_sno, prod_sno, prod_name, specification,
--             unit_name, reason_type, qty, unit_price, remarks }]
-- }
-- grn_basic_sno resolves po_basic_sno/vendor_sno/com_sno/div_sno/brn_sno/
-- dept_sno from the GRN itself — the caller never supplies those directly,
-- so a debit note can't be misfiled against the wrong PO/vendor.
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

    DECLARE @po_basic_sno INT, @vendor_sno INT, @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;

    SELECT @po_basic_sno = po_basic_sno, @vendor_sno = vendor_sno,
           @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno
    FROM dbo.grn_basic_info
    WHERE grn_basic_sno = @grn_basic_sno AND is_active = 'Y';

    IF @po_basic_sno IS NULL
    BEGIN
        RAISERROR('GRN not found.', 16, 1);
        RETURN;
    END

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
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;

        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(debit_note_no, 6) AS INT)), 0) + 1
        FROM dbo.debit_note_basic_info
        WHERE debit_note_no LIKE 'DN-' + @year + '-%';

        DECLARE @debit_note_no VARCHAR(30) = 'DN-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        DECLARE @total_qty DECIMAL(18,2), @total_amount DECIMAL(18,2);
        SELECT @total_qty = SUM(qty), @total_amount = SUM(qty * unit_price) FROM @lineItems;

        INSERT INTO dbo.debit_note_basic_info (
            debit_note_no, grn_basic_sno, po_basic_sno, vendor_sno, com_sno, div_sno, brn_sno, dept_sno,
            debit_note_date, total_qty, total_amount, remarks, status, is_active, created_by, created_date
        )
        VALUES (
            @debit_note_no, @grn_basic_sno, @po_basic_sno, @vendor_sno, @com_sno, @div_sno, @brn_sno, @dept_sno,
            GETDATE(), @total_qty, @total_amount, @remarks, 'Raised', 'Y', @created_by, GETDATE()
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
        b.vendor_sno,
        CONVERT(VARCHAR(10), b.debit_note_date, 120) AS debit_note_date,
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
-- sp_nt_GetAllDebitNotes  (internal — "our screen")
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
-- sp_nt_GetDebitNotesByGRN  (internal)
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
        b.vendor_sno,
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
    WHERE b.grn_basic_sno = @grn_basic_sno
      AND b.is_active = 'Y'
    ORDER BY b.debit_note_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetDebitNotesForSupplier  (supplier portal — ownership-checked)
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
