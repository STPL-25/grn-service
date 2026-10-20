-- GRN: supplier invoice details + invoice document are now mandatory.
-- Adds invoice_date / invoice_amount / invoice_doc_url to grn_basic_info (doc_ref_no is the invoice no)
-- and makes sp_nt_CreateGRN reject a GRN that lacks any of them. Existing GRNs keep NULLs.
-- Re-runnable.  Apply: node sql/run_sql.mjs sql/54_grn_invoice_mandatory.sql
IF COL_LENGTH('dbo.grn_basic_info', 'invoice_date') IS NULL     ALTER TABLE dbo.grn_basic_info ADD invoice_date DATE NULL;
IF COL_LENGTH('dbo.grn_basic_info', 'invoice_amount') IS NULL   ALTER TABLE dbo.grn_basic_info ADD invoice_amount DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.grn_basic_info', 'invoice_doc_url') IS NULL  ALTER TABLE dbo.grn_basic_info ADD invoice_doc_url VARCHAR(500) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_sno INT           = JSON_VALUE(@jsonInput, '$.gate_entry_sno');
    DECLARE @po_basic_sno   INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @vendor_sno     INT           = JSON_VALUE(@jsonInput, '$.vendor_sno');
    DECLARE @received_date  DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @doc_ref_no     VARCHAR(100)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.doc_ref_no'))), '');
    DECLARE @invoice_date   DATE          = TRY_CONVERT(DATE, JSON_VALUE(@jsonInput, '$.invoice_date'));
    DECLARE @invoice_amount DECIMAL(18,2) = TRY_CONVERT(DECIMAL(18,2), JSON_VALUE(@jsonInput, '$.invoice_amount'));
    DECLARE @invoice_doc_url VARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.invoice_doc_url'))), '');
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

    IF @doc_ref_no IS NULL OR @invoice_date IS NULL OR @invoice_amount IS NULL OR @invoice_amount <= 0 OR @invoice_doc_url IS NULL
    BEGIN
        RAISERROR('Invoice number, invoice date, invoice amount and the invoice document are required to create a GRN.', 16, 1);
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
            received_date, doc_ref_no, invoice_date, invoice_amount, invoice_doc_url, vehicle_no, challan_no, remarks,
            is_active, status, created_by, created_date
        )
        VALUES (
            @grn_no, @com_sno, @div_sno, @brn_sno, @dept_sno,
            @gate_entry_sno, @po_basic_sno, @vendor_sno,
            @received_date, @doc_ref_no, @invoice_date, @invoice_amount, @invoice_doc_url, @vehicle_no, @challan_no, @remarks,
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
        b.doc_ref_no, CONVERT(VARCHAR(10), b.invoice_date, 120) AS invoice_date, b.invoice_amount, b.invoice_doc_url,
        b.vehicle_no, b.challan_no, b.remarks, b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        CONVERT(VARCHAR(30), b.created_date, 120) AS created_at
    FROM dbo.grn_basic_info b
    WHERE b.grn_basic_sno = @grn_basic_sno;
END
GO
