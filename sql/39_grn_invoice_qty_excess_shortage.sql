-- ============================================================
-- GRN: supplier-invoice qty/UOM, shortage / excess, excess-over-PO approval,
-- automatic Debit (shortage) and Credit (excess) notes.
-- Database : Non_trade_Dev first (re-runnable; apply to Non_Trade only after sign-off)
--
-- Rules (agreed 2026-10-15):
--   * Each GRN line records the supplier INVOICE qty + UOM next to the received qty.
--       shortage_qty = invoice - received   (received less than invoiced)  -> DEBIT note
--       excess_qty   = received - invoice   (received more than invoiced)  -> CREDIT note
--     (compared only when the invoice UOM equals the line's received UOM.)
--   * Accepted qty beyond what the PO still allows (net = received - rejected,
--     minus PO pending) is HELD (hold_qty): it is NOT posted to inventory and an
--     approval request goes to the configured approver (nt_grn_excess_approval_config).
--       Accept -> hold released, stock posted by the service, notes raised.
--       Reject -> received_qty reduced by the held qty, marked "Return to Supplier"
--                 (reissue), notes raised on what is left.
--   * Notes are created automatically once a line has no held qty (sp_nt_GRN_RaiseAutoNotes).
-- ============================================================

-- ── 1. grn_item_details columns ──────────────────────────────────────────────
IF COL_LENGTH('dbo.grn_item_details', 'invoice_qty') IS NULL
    ALTER TABLE dbo.grn_item_details ADD invoice_qty DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.grn_item_details', 'invoice_uom') IS NULL
    ALTER TABLE dbo.grn_item_details ADD invoice_uom VARCHAR(50) NULL;
IF COL_LENGTH('dbo.grn_item_details', 'shortage_qty') IS NULL
    ALTER TABLE dbo.grn_item_details ADD shortage_qty DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.grn_item_details', 'excess_qty') IS NULL
    ALTER TABLE dbo.grn_item_details ADD excess_qty DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.grn_item_details', 'hold_qty') IS NULL
    ALTER TABLE dbo.grn_item_details ADD hold_qty DECIMAL(18,2) NOT NULL CONSTRAINT DF_grn_item_hold_qty DEFAULT (0);
-- Pending Approval | Accepted | Rejected   (NULL = nothing was above the PO)
IF COL_LENGTH('dbo.grn_item_details', 'excess_status') IS NULL
    ALTER TABLE dbo.grn_item_details ADD excess_status VARCHAR(20) NULL;
IF COL_LENGTH('dbo.grn_item_details', 'notes_raised') IS NULL
    ALTER TABLE dbo.grn_item_details ADD notes_raised CHAR(1) NOT NULL CONSTRAINT DF_grn_item_notes_raised DEFAULT ('N');
GO

-- ── 2. Approver config + requests ────────────────────────────────────────────
IF OBJECT_ID('dbo.nt_grn_excess_approval_config', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_grn_excess_approval_config (
        config_sno    INT IDENTITY(1,1) PRIMARY KEY,
        stage_name    VARCHAR(100) NOT NULL DEFAULT 'Excess Receipt Approval',
        approver_ecno VARCHAR(50)  NOT NULL,
        is_active     CHAR(1)      NOT NULL DEFAULT 'Y',
        created_at    DATETIME     NOT NULL DEFAULT GETDATE()
    );
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.nt_grn_excess_approval_config)
    INSERT INTO dbo.nt_grn_excess_approval_config (approver_ecno) VALUES ('KTM1004');
GO

IF OBJECT_ID('dbo.nt_grn_excess_requests', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_grn_excess_requests (
        excess_sno      INT IDENTITY(1,1) PRIMARY KEY,
        grn_basic_sno   INT NOT NULL,
        grn_item_sno    INT NOT NULL,
        po_basic_sno    INT NULL,
        po_item_sno     INT NULL,
        prod_sno        INT NULL,
        prod_name       VARCHAR(255) NULL,
        unit_name       VARCHAR(50)  NULL,
        po_qty          DECIMAL(18,2) NULL,
        po_pending_qty  DECIMAL(18,2) NULL,   -- what the PO still allowed before this GRN
        received_qty    DECIMAL(18,2) NULL,
        excess_qty      DECIMAL(18,2) NOT NULL, -- the qty above the PO, awaiting decision
        status          VARCHAR(12)  NOT NULL DEFAULT 'Pending',  -- Pending | Accepted | Rejected
        reissue_status  VARCHAR(30)  NULL,                       -- 'Return to Supplier' when rejected
        approver_ecno   VARCHAR(50)  NOT NULL,
        requested_by    VARCHAR(50)  NULL,
        requested_at    DATETIME     NOT NULL DEFAULT GETDATE(),
        acted_by        VARCHAR(50)  NULL,
        acted_at        DATETIME     NULL,
        remarks         VARCHAR(500) NULL
    );
    CREATE INDEX IX_nt_grn_excess_req_grn ON dbo.nt_grn_excess_requests (grn_basic_sno);
    CREATE INDEX IX_nt_grn_excess_req_appr ON dbo.nt_grn_excess_requests (approver_ecno, status);
END
GO

-- ── 3. Credit note tables (mirror of the debit note ones) ────────────────────
IF OBJECT_ID('dbo.credit_note_basic_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.credit_note_basic_info (
        credit_note_sno  INT IDENTITY(1,1) PRIMARY KEY,
        credit_note_no   VARCHAR(30)   NOT NULL UNIQUE,
        grn_basic_sno    INT           NOT NULL,
        po_basic_sno     INT           NOT NULL,
        vendor_sno       INT           NULL,
        com_sno          INT           NULL,
        div_sno          INT           NULL,
        brn_sno          INT           NULL,
        dept_sno         INT           NULL,
        credit_note_date DATE          NOT NULL DEFAULT (GETDATE()),
        total_qty        DECIMAL(18,2) NOT NULL DEFAULT 0,
        total_amount     DECIMAL(18,2) NOT NULL DEFAULT 0,
        remarks          VARCHAR(500)  NULL,
        status           VARCHAR(20)   NOT NULL DEFAULT 'Raised',
        is_active        CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by       VARCHAR(20)   NULL,
        created_date     DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_credit_note_basic_info_grn
            FOREIGN KEY (grn_basic_sno) REFERENCES dbo.grn_basic_info (grn_basic_sno)
    );
    CREATE INDEX IX_credit_note_basic_info_grn ON dbo.credit_note_basic_info (grn_basic_sno);
END
GO
IF OBJECT_ID('dbo.credit_note_item_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.credit_note_item_details (
        credit_note_item_sno INT IDENTITY(1,1) PRIMARY KEY,
        credit_note_sno   INT           NOT NULL,
        grn_item_sno      INT           NULL,
        po_item_sno       INT           NULL,
        prod_sno          INT           NULL,
        prod_name         VARCHAR(255)  NULL,
        specification     VARCHAR(500)  NULL,
        unit_name         VARCHAR(50)   NULL,
        reason_type       VARCHAR(20)   NOT NULL DEFAULT 'Excess',
        qty               DECIMAL(18,2) NOT NULL,
        unit_price        DECIMAL(18,2) NOT NULL DEFAULT 0,
        amount            DECIMAL(18,2) NOT NULL DEFAULT 0,
        remarks           VARCHAR(500)  NULL,
        is_active         CHAR(1)       NOT NULL DEFAULT 'Y',
        CONSTRAINT FK_credit_note_item_details_note
            FOREIGN KEY (credit_note_sno) REFERENCES dbo.credit_note_basic_info (credit_note_sno)
    );
    CREATE INDEX IX_credit_note_item_details_note ON dbo.credit_note_item_details (credit_note_sno);
END
GO

-- ── 4. UOM list for the invoice-UOM dropdown ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNUomList
AS
BEGIN
    SET NOCOUNT ON;
    SELECT uom_sno, uom_name FROM dbo.uom_master WHERE is_active IN ('Y','1') ORDER BY uom_name;
END
GO

-- ── 5. Auto debit (shortage) / credit (excess) notes ─────────────────────────
-- @jsonInput: { grn_basic_sno, created_by }
-- Works only on lines with an invoice qty, nothing held for approval, and no notes
-- raised yet. Safe inside the caller's transaction (no transaction of its own).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GRN_RaiseAutoNotes
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @created_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by');

    DECLARE @po_basic_sno INT, @vendor_sno INT, @com INT, @div INT, @brn INT, @dept INT;
    SELECT @po_basic_sno = po_basic_sno, @vendor_sno = vendor_sno,
           @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
    FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn_basic_sno AND is_active = 'Y';
    IF @po_basic_sno IS NULL RETURN;

    DECLARE @lines TABLE (
        grn_item_sno INT, po_item_sno INT, prod_sno INT, prod_name VARCHAR(255), specification VARCHAR(500),
        unit_name VARCHAR(50), shortage DECIMAL(18,2), excess DECIMAL(18,2), unit_price DECIMAL(18,2)
    );

    INSERT INTO @lines
    SELECT gi.grn_item_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name, gi.specification, gi.unit_name,
           CASE WHEN gi.invoice_qty > gi.received_qty THEN gi.invoice_qty - gi.received_qty ELSE 0 END,
           CASE WHEN gi.received_qty > gi.invoice_qty THEN gi.received_qty - gi.invoice_qty ELSE 0 END,
           ISNULL(pi.agreed_unit_price, ISNULL(gi.received_unit_price, 0))
    FROM dbo.grn_item_details gi
    LEFT JOIN dbo.po_item_details pi ON pi.po_item_sno = gi.po_item_sno
    WHERE gi.grn_basic_sno = @grn_basic_sno AND gi.is_active = 'Y'
      AND gi.notes_raised = 'N' AND ISNULL(gi.hold_qty, 0) = 0
      AND gi.invoice_qty IS NOT NULL
      AND (gi.invoice_uom IS NULL OR gi.unit_name IS NULL OR LOWER(LTRIM(RTRIM(gi.invoice_uom))) = LOWER(LTRIM(RTRIM(gi.unit_name))));

    -- refresh the stored shortage / excess (they change when held qty is rejected)
    UPDATE gi SET shortage_qty = l.shortage, excess_qty = l.excess
    FROM dbo.grn_item_details gi JOIN @lines l ON l.grn_item_sno = gi.grn_item_sno;

    DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT, @tq DECIMAL(18,2), @ta DECIMAL(18,2);

    IF EXISTS (SELECT 1 FROM @lines WHERE shortage > 0)
    BEGIN
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(debit_note_no, 6) AS INT)), 0) + 1
        FROM dbo.debit_note_basic_info WHERE debit_note_no LIKE 'DN-' + @year + '-%';
        DECLARE @dn_no VARCHAR(30) = 'DN-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);
        SELECT @tq = SUM(shortage), @ta = SUM(shortage * unit_price) FROM @lines WHERE shortage > 0;
        INSERT INTO dbo.debit_note_basic_info (debit_note_no, grn_basic_sno, po_basic_sno, vendor_sno, com_sno, div_sno, brn_sno, dept_sno,
            debit_note_date, total_qty, total_amount, remarks, status, is_active, created_by, created_date)
        VALUES (@dn_no, @grn_basic_sno, @po_basic_sno, @vendor_sno, @com, @div, @brn, @dept,
            GETDATE(), @tq, @ta, 'Auto: received less than supplier invoice qty', 'Raised', 'Y', @created_by, GETDATE());
        DECLARE @dn INT = SCOPE_IDENTITY();
        INSERT INTO dbo.debit_note_item_details (debit_note_sno, grn_item_sno, po_item_sno, prod_sno, prod_name, specification,
            unit_name, reason_type, qty, unit_price, amount, remarks, is_active)
        SELECT @dn, grn_item_sno, po_item_sno, prod_sno, prod_name, specification, unit_name, 'Shortage',
               shortage, unit_price, shortage * unit_price, 'Invoice qty more than received', 'Y'
        FROM @lines WHERE shortage > 0;
        INSERT INTO dbo.debit_note_history_data (event_type, debit_note_sno, po_basic_sno, grn_basic_sno, remarks, status_by)
        VALUES ('Debit Note Raised', @dn, @po_basic_sno, @grn_basic_sno, 'Auto: shortage vs supplier invoice', @created_by);
    END

    IF EXISTS (SELECT 1 FROM @lines WHERE excess > 0)
    BEGIN
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(credit_note_no, 6) AS INT)), 0) + 1
        FROM dbo.credit_note_basic_info WHERE credit_note_no LIKE 'CN-' + @year + '-%';
        DECLARE @cn_no VARCHAR(30) = 'CN-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);
        SELECT @tq = SUM(excess), @ta = SUM(excess * unit_price) FROM @lines WHERE excess > 0;
        INSERT INTO dbo.credit_note_basic_info (credit_note_no, grn_basic_sno, po_basic_sno, vendor_sno, com_sno, div_sno, brn_sno, dept_sno,
            credit_note_date, total_qty, total_amount, remarks, status, is_active, created_by, created_date)
        VALUES (@cn_no, @grn_basic_sno, @po_basic_sno, @vendor_sno, @com, @div, @brn, @dept,
            GETDATE(), @tq, @ta, 'Auto: received more than supplier invoice qty (accepted)', 'Raised', 'Y', @created_by, GETDATE());
        DECLARE @cn INT = SCOPE_IDENTITY();
        INSERT INTO dbo.credit_note_item_details (credit_note_sno, grn_item_sno, po_item_sno, prod_sno, prod_name, specification,
            unit_name, reason_type, qty, unit_price, amount, remarks, is_active)
        SELECT @cn, grn_item_sno, po_item_sno, prod_sno, prod_name, specification, unit_name, 'Excess',
               excess, unit_price, excess * unit_price, 'Received more than invoice qty', 'Y'
        FROM @lines WHERE excess > 0;
    END

    UPDATE gi SET notes_raised = 'Y'
    FROM dbo.grn_item_details gi JOIN @lines l ON l.grn_item_sno = gi.grn_item_sno;
END
GO

-- ── 6. sp_nt_CreateGRN — adds invoice qty/UOM, hold-over-PO, approval requests, auto notes ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_sno INT           = JSON_VALUE(@jsonInput, '$.gate_entry_sno');
    DECLARE @po_basic_sno   INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @vendor_sno     INT           = JSON_VALUE(@jsonInput, '$.vendor_sno');
    DECLARE @received_date  DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @doc_ref_no     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.doc_ref_no');
    DECLARE @vehicle_no     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.vehicle_no');
    DECLARE @challan_no     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.challan_no');
    DECLARE @remarks        VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @items          NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

    IF @gate_entry_sno IS NULL OR @po_basic_sno IS NULL OR @received_date IS NULL
    BEGIN
        RAISERROR('gate_entry_sno, po_basic_sno and received_date are required.', 16, 1);
        RETURN;
    END

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
    BEGIN
        RAISERROR('At least one item is required.', 16, 1);
        RETURN;
    END

    DECLARE @grn_basic_sno INT;
    DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;

    SELECT @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno
    FROM dbo.po_request_info WHERE po_basic_sno = @po_basic_sno;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @grn_no INT;
        SELECT @grn_no = ISNULL(MAX(grn_no), 0) + 1 FROM dbo.grn_basic_info;

        INSERT INTO dbo.grn_basic_info (
            grn_no, com_sno, div_sno, brn_sno, dept_sno,
            gate_entry_sno, po_basic_sno, vendor_sno,
            received_date, doc_ref_no, vehicle_no, challan_no, remarks,
            is_active, status, created_by, created_date
        )
        VALUES (
            @grn_no, @com_sno, @div_sno, @brn_sno, @dept_sno,
            @gate_entry_sno, @po_basic_sno, @vendor_sno,
            @received_date, @doc_ref_no, @vehicle_no, @challan_no, @remarks,
            'Y', 'Received', @created_by, GETDATE()
        );

        SET @grn_basic_sno = SCOPE_IDENTITY();

        -- What the PO still allowed per line BEFORE this GRN (server-side, not trusted from the client).
        DECLARE @lines TABLE (
            idx INT IDENTITY(1,1), po_item_sno INT, prod_sno INT, prod_name VARCHAR(255), specification VARCHAR(500),
            ordered_qty DECIMAL(18,2), received_qty DECIMAL(18,2), rejected_qty DECIMAL(18,2), unit_name VARCHAR(50),
            condition VARCHAR(20), hsn_code VARCHAR(10), remarks VARCHAR(500), warehouse_location_sno INT,
            invoice_qty DECIMAL(18,2), invoice_uom VARCHAR(50), pending_before DECIMAL(18,2), hold DECIMAL(18,2)
        );

        INSERT INTO @lines (po_item_sno, prod_sno, prod_name, specification, ordered_qty, received_qty, rejected_qty,
                            unit_name, condition, hsn_code, remarks, warehouse_location_sno, invoice_qty, invoice_uom)
        SELECT po_item_sno, prod_sno, prod_name, specification, ordered_qty, received_qty, ISNULL(rejected_qty, 0),
               unit_name, ISNULL(condition, 'Good'), NULLIF(LTRIM(RTRIM(hsn_code)), ''), remarks, warehouse_location_sno,
               invoice_qty, NULLIF(LTRIM(RTRIM(invoice_uom)), '')
        FROM OPENJSON(@items)
        WITH (
            po_item_sno INT '$.po_item_sno', prod_sno INT '$.prod_sno', prod_name VARCHAR(255) '$.prod_name',
            specification VARCHAR(500) '$.specification', ordered_qty DECIMAL(18,2) '$.ordered_qty',
            received_qty DECIMAL(18,2) '$.received_qty', rejected_qty DECIMAL(18,2) '$.rejected_qty',
            unit_name VARCHAR(50) '$.unit_name', condition VARCHAR(20) '$.condition', hsn_code VARCHAR(10) '$.hsn_code',
            remarks VARCHAR(500) '$.remarks', warehouse_location_sno INT '$.warehouse_location_sno',
            invoice_qty DECIMAL(18,2) '$.invoice_qty', invoice_uom VARCHAR(50) '$.invoice_uom'
        );

        UPDATE l SET
            pending_before = CASE WHEN l.po_item_sno IS NULL THEN NULL
                ELSE ISNULL(pi.qty, l.ordered_qty) - ISNULL((
                        SELECT SUM(g2.received_qty) FROM dbo.grn_item_details g2
                        WHERE g2.po_item_sno = l.po_item_sno AND g2.is_active = 'Y' AND g2.grn_basic_sno <> @grn_basic_sno), 0) END
        FROM @lines l LEFT JOIN dbo.po_item_details pi ON pi.po_item_sno = l.po_item_sno;

        -- Accepted qty (received - rejected) beyond the PO's pending qty is held for approval.
        UPDATE @lines SET hold = CASE
                WHEN pending_before IS NULL THEN 0
                WHEN (received_qty - rejected_qty) > CASE WHEN pending_before < 0 THEN 0 ELSE pending_before END
                    THEN (received_qty - rejected_qty) - CASE WHEN pending_before < 0 THEN 0 ELSE pending_before END
                ELSE 0 END;

        INSERT INTO dbo.grn_item_details (
            grn_basic_sno, po_item_sno, prod_sno, prod_name, specification,
            po_qty, received_qty, diff_qty, rejected_qty, unit_name,
            condition, hsn_code, remarks,
            warehouse_location_sno, warehouse_location_name,
            invoice_qty, invoice_uom, shortage_qty, excess_qty, hold_qty, excess_status,
            created_by, created_date, is_active
        )
        SELECT
            @grn_basic_sno, l.po_item_sno, l.prod_sno, l.prod_name, l.specification,
            l.ordered_qty, l.received_qty, (ISNULL(l.received_qty, 0) - ISNULL(l.ordered_qty, 0)), l.rejected_qty, l.unit_name,
            l.condition, l.hsn_code, l.remarks,
            l.warehouse_location_sno, wl.location_name,
            l.invoice_qty, l.invoice_uom,
            CASE WHEN l.invoice_qty IS NULL OR (l.invoice_uom IS NOT NULL AND l.unit_name IS NOT NULL AND LOWER(l.invoice_uom) <> LOWER(LTRIM(RTRIM(l.unit_name)))) THEN NULL
                 WHEN l.invoice_qty > l.received_qty THEN l.invoice_qty - l.received_qty ELSE 0 END,
            CASE WHEN l.invoice_qty IS NULL OR (l.invoice_uom IS NOT NULL AND l.unit_name IS NOT NULL AND LOWER(l.invoice_uom) <> LOWER(LTRIM(RTRIM(l.unit_name)))) THEN NULL
                 WHEN l.received_qty > l.invoice_qty THEN l.received_qty - l.invoice_qty ELSE 0 END,
            l.hold,
            CASE WHEN l.hold > 0 THEN 'Pending Approval' END,
            @created_by, GETDATE(), 'Y'
        FROM @lines l
        LEFT JOIN dbo.warehouse_location_master wl ON wl.location_sno = l.warehouse_location_sno
        ORDER BY l.idx;

        -- approval requests for the held qty
        IF EXISTS (SELECT 1 FROM @lines WHERE hold > 0)
        BEGIN
            DECLARE @approver VARCHAR(50);
            SELECT TOP 1 @approver = approver_ecno FROM dbo.nt_grn_excess_approval_config WHERE is_active = 'Y' ORDER BY config_sno;
            IF @approver IS NULL
                THROW 53101, 'Received qty is above the PO qty but no excess-receipt approver is configured (nt_grn_excess_approval_config).', 1;

            INSERT INTO dbo.nt_grn_excess_requests (grn_basic_sno, grn_item_sno, po_basic_sno, po_item_sno, prod_sno, prod_name, unit_name,
                po_qty, po_pending_qty, received_qty, excess_qty, approver_ecno, requested_by)
            SELECT @grn_basic_sno, gi.grn_item_sno, @po_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name, gi.unit_name,
                   gi.po_qty, CASE WHEN pb.pending_before < 0 THEN 0 ELSE pb.pending_before END, gi.received_qty, gi.hold_qty, @approver, @created_by
            FROM dbo.grn_item_details gi
            OUTER APPLY (SELECT TOP 1 pending_before FROM @lines l WHERE l.po_item_sno = gi.po_item_sno) pb
            WHERE gi.grn_basic_sno = @grn_basic_sno AND gi.hold_qty > 0;
        END

        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, po_item_sno, grn_basic_sno, gate_entry_sno,
            qty, pending_qty_after, to_status, status_by, remarks
        )
        SELECT 'Item Received', @po_basic_sno, l.po_item_sno, @grn_basic_sno, @gate_entry_sno,
               l.received_qty, (ISNULL(l.ordered_qty, 0) - ISNULL(l.received_qty, 0)), 'Received', @created_by, l.remarks
        FROM @lines l;

        INSERT INTO dbo.grn_history_data (event_type, po_basic_sno, grn_basic_sno, gate_entry_sno, to_status, status_by, remarks)
        VALUES ('GRN Created', @po_basic_sno, @grn_basic_sno, @gate_entry_sno, 'Received', @created_by, @remarks);

        -- debit (shortage) / credit (excess) notes for every line with nothing held
        DECLARE @noteJson NVARCHAR(MAX) = (SELECT @grn_basic_sno AS grn_basic_sno, @created_by AS created_by FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC dbo.sp_nt_GRN_RaiseAutoNotes @jsonInput = @noteJson;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno, b.po_basic_sno, b.vendor_sno,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.doc_ref_no, b.vehicle_no, b.challan_no, b.remarks, b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        CONVERT(VARCHAR(30), b.created_date, 120) AS created_at
    FROM dbo.grn_basic_info b
    WHERE b.grn_basic_sno = @grn_basic_sno;
END
GO

-- ── 7. Inventory sync: held qty is not stock yet ─────────────────────────────
-- rejected_qty is returned as (rejected + held) so the service's received - rejected
-- net excludes qty still awaiting approval. Accepting it posts the held qty separately.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNItemsForInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');

    SELECT
        gi.grn_item_sno, gi.grn_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name,
        gi.unit_name, gi.received_qty, (ISNULL(gi.rejected_qty, 0) + ISNULL(gi.hold_qty, 0)) AS rejected_qty,
        gi.warehouse_location_sno,
        gi.inventory_sync_status, gi.received_unit_price,
        gb.com_sno, gb.div_sno, gb.brn_sno, gb.dept_sno, gb.created_by,
        gb.received_date,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.grn_basic_sno = @grn_basic_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNItemForInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_item_sno INT = JSON_VALUE(@jsonInput, '$.grn_item_sno');

    SELECT
        gi.grn_item_sno, gi.grn_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name,
        gi.unit_name, gi.received_qty, (ISNULL(gi.rejected_qty, 0) + ISNULL(gi.hold_qty, 0)) AS rejected_qty,
        gi.warehouse_location_sno,
        gi.inventory_sync_status, gi.received_unit_price,
        gb.com_sno, gb.div_sno, gb.brn_sno, gb.dept_sno, gb.created_by,
        gb.received_date,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.grn_item_sno = @grn_item_sno;
END
GO

-- ── 8. Excess approval: list + decide ────────────────────────────────────────
-- @jsonInput: { approver_ecno?, status?, grn_basic_sno?, excess_sno? }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNExcessRequests
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @appr VARCHAR(50) = NULLIF(JSON_VALUE(@jsonInput, '$.approver_ecno'), ''),
            @status VARCHAR(12) = NULLIF(JSON_VALUE(@jsonInput, '$.status'), ''),
            @grn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.grn_basic_sno') AS INT),
            @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.excess_sno') AS INT);

    SELECT r.excess_sno, r.grn_basic_sno, r.grn_item_sno, r.po_basic_sno, r.po_item_sno, r.prod_sno, r.prod_name, r.unit_name,
           r.po_qty, r.po_pending_qty, r.received_qty, r.excess_qty, r.status, r.reissue_status,
           r.approver_ecno, ap.ename AS approver_name, r.requested_by, rb.ename AS requested_by_name,
           r.requested_at, r.acted_by, r.acted_at, r.remarks,
           'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
           p.po_df_no AS po_no, k.company_name AS vendor_name, gi.invoice_qty, gi.invoice_uom
    FROM dbo.nt_grn_excess_requests r
    JOIN dbo.grn_basic_info b ON b.grn_basic_sno = r.grn_basic_sno
    LEFT JOIN dbo.grn_item_details gi ON gi.grn_item_sno = r.grn_item_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = r.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = b.vendor_sno
    LEFT JOIN dbo.vw_verified_employees ap ON ap.ecno = r.approver_ecno
    LEFT JOIN dbo.vw_verified_employees rb ON rb.ecno = r.requested_by
    WHERE (@appr IS NULL OR r.approver_ecno = @appr)
      AND (@status IS NULL OR r.status = @status)
      AND (@grn IS NULL OR r.grn_basic_sno = @grn)
      AND (@id IS NULL OR r.excess_sno = @id)
    ORDER BY r.excess_sno DESC;
END
GO

-- @jsonInput: { excess_sno, action: 'ACCEPT'|'REJECT', remarks, acted_by }
-- Returns one row: the decision + what the service needs to post stock for an accept.
CREATE OR ALTER PROCEDURE dbo.sp_nt_DecideGRNExcess
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = JSON_VALUE(@jsonInput, '$.excess_sno'),
            @action VARCHAR(10) = UPPER(JSON_VALUE(@jsonInput, '$.action')),
            @remarks VARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
            @by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.acted_by');

    IF @action NOT IN ('ACCEPT', 'REJECT') THROW 53110, 'action must be ACCEPT or REJECT.', 1;

    DECLARE @grn INT, @item INT, @qty DECIMAL(18,2), @status VARCHAR(12), @appr VARCHAR(50), @po INT;
    SELECT @grn = grn_basic_sno, @item = grn_item_sno, @qty = excess_qty, @status = status, @appr = approver_ecno, @po = po_basic_sno
    FROM dbo.nt_grn_excess_requests WHERE excess_sno = @id;

    IF @grn IS NULL THROW 53111, 'Excess approval request not found.', 1;
    IF @status <> 'Pending' THROW 53112, 'This request has already been decided.', 1;
    IF @appr <> @by THROW 53113, 'You are not the approver of this request.', 1;
    IF @action = 'REJECT' AND (@remarks IS NULL OR LTRIM(RTRIM(@remarks)) = '') THROW 53114, 'Remarks are required to reject.', 1;

    DECLARE @sync VARCHAR(20) = (SELECT inventory_sync_status FROM dbo.grn_item_details WHERE grn_item_sno = @item);

    BEGIN TRANSACTION;
    BEGIN TRY
        IF @action = 'ACCEPT'
        BEGIN
            UPDATE dbo.grn_item_details SET hold_qty = 0, excess_status = 'Accepted' WHERE grn_item_sno = @item;
            UPDATE dbo.nt_grn_excess_requests SET status = 'Accepted', acted_by = @by, acted_at = GETDATE(), remarks = @remarks WHERE excess_sno = @id;
        END
        ELSE
        BEGIN
            -- the held qty goes back to the supplier: it was never accepted into the GRN
            UPDATE dbo.grn_item_details SET
                received_qty = received_qty - @qty,
                diff_qty = (received_qty - @qty) - ISNULL(po_qty, 0),
                hold_qty = 0, excess_status = 'Rejected'
            WHERE grn_item_sno = @item;
            UPDATE dbo.nt_grn_excess_requests SET status = 'Rejected', reissue_status = 'Return to Supplier',
                acted_by = @by, acted_at = GETDATE(), remarks = @remarks WHERE excess_sno = @id;
        END

        INSERT INTO dbo.grn_history_data (event_type, po_basic_sno, po_item_sno, grn_basic_sno, qty, to_status, status_by, remarks)
        SELECT CASE WHEN @action = 'ACCEPT' THEN 'Excess Accepted' ELSE 'Excess Rejected' END,
               @po, po_item_sno, @grn, @qty, CASE WHEN @action = 'ACCEPT' THEN 'Accepted' ELSE 'Return to Supplier' END, @by, @remarks
        FROM dbo.grn_item_details WHERE grn_item_sno = @item;

        DECLARE @noteJson NVARCHAR(MAX) = (SELECT @grn AS grn_basic_sno, @by AS created_by FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC dbo.sp_nt_GRN_RaiseAutoNotes @jsonInput = @noteJson;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT r.excess_sno, r.grn_basic_sno, r.grn_item_sno, r.po_basic_sno, r.prod_name, r.unit_name, r.excess_qty,
           r.status, r.reissue_status, r.requested_by, r.remarks, @sync AS inventory_sync_status,
           'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
           b.com_sno, b.div_sno, b.brn_sno, b.dept_sno, b.received_date, b.created_by,
           gi.prod_sno, gi.po_item_sno, gi.warehouse_location_sno, gi.received_unit_price
    FROM dbo.nt_grn_excess_requests r
    JOIN dbo.grn_basic_info b ON b.grn_basic_sno = r.grn_basic_sno
    JOIN dbo.grn_item_details gi ON gi.grn_item_sno = r.grn_item_sno
    WHERE r.excess_sno = @id;
END
GO

-- ── 9. Credit notes read side ────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetCreditNotesByGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    SELECT c.credit_note_sno, c.credit_note_no, c.grn_basic_sno, c.po_basic_sno, c.vendor_sno,
           CONVERT(VARCHAR(10), c.credit_note_date, 120) AS credit_note_date,
           c.total_qty, c.total_amount, c.remarks, c.status, c.created_by,
           CONVERT(VARCHAR(30), c.created_date, 120) AS created_at,
           (SELECT i.credit_note_item_sno, i.grn_item_sno, i.prod_name, i.unit_name, i.reason_type, i.qty, i.unit_price, i.amount
            FROM dbo.credit_note_item_details i WHERE i.credit_note_sno = c.credit_note_sno AND i.is_active = 'Y'
            FOR JSON PATH) AS items
    FROM dbo.credit_note_basic_info c
    WHERE c.grn_basic_sno = @grn AND c.is_active = 'Y'
    ORDER BY c.credit_note_sno DESC;
END
GO

-- ── 10. sp_nt_GetGRNsByPO — exposes invoice / shortage / excess / approval fields ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNsByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @HierarchyJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)   AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        b.created_by                                 AS received_by,
        b.created_by                                 AS received_by_name,
        CONVERT(VARCHAR(30), b.created_date, 120)     AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.po_qty                            AS ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.hsn_code,
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name,
                gi.invoice_qty,
                gi.invoice_uom,
                gi.shortage_qty,
                gi.excess_qty,
                gi.hold_qty,
                gi.excess_status
            FROM dbo.grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
              AND gi.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge
        ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p
        ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k
        ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.po_basic_sno = @po_basic_sno
      AND b.is_active = 'Y'
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = b.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = b.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)
          )
      )
    ORDER BY b.grn_basic_sno DESC;
END
GO
