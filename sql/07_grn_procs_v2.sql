-- ============================================================
-- GRN v2: repoint everything at grn_basic_info / grn_item_details /
-- grn_history_data, retiring nt_grn_basic_info / nt_grn_item_details.
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Run after 05_grn_basic_info_v2.sql, 05_grn_item_details.sql and
-- 06_grn_history_data.sql have created the base tables. This script:
--   1. Widens grn_basic_info.status from CHAR(1) to VARCHAR(20) so it can
--      hold the same display values the app has always used ('Received',
--      'Partial', ...) instead of a workflow status code.
--   2. Adds rejected_qty / condition to grn_item_details — the new table
--      dropped both in favour of pricing/tax columns, but the GRN entry
--      form and history view still need them.
--   3. Repoints sp_nt_CreateGRN / sp_nt_GetAllGRNs / sp_nt_GetGRNsByPO /
--      sp_nt_GetPendingGateEntriesForGRN at the new tables and adds
--      grn_history_data audit rows (one per item + one header row) on
--      create. All four are CREATE OR ALTER, safe to re-run.
--
-- Applied to production 2026-07-20, including a one-time migration of
-- the 5 existing nt_grn_basic_info rows + 201 nt_grn_item_details rows
-- into the new tables (identity values preserved). That one-time copy
-- is NOT part of this script (see git history / session notes) — this
-- script only carries schema + procedure changes so it's safe to run
-- fresh against another environment that has no legacy nt_grn_* data.
-- ============================================================

-- 1. Widen grn_basic_info.status
IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'grn_basic_info' AND COLUMN_NAME = 'status' AND DATA_TYPE = 'char'
)
BEGIN
    DECLARE @dfName SYSNAME;
    SELECT @dfName = dc.name
    FROM sys.default_constraints dc
    JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = OBJECT_ID('dbo.grn_basic_info') AND c.name = 'status';

    IF @dfName IS NOT NULL
        EXEC('ALTER TABLE dbo.grn_basic_info DROP CONSTRAINT [' + @dfName + ']');

    ALTER TABLE dbo.grn_basic_info ALTER COLUMN status VARCHAR(20) NOT NULL;

    ALTER TABLE dbo.grn_basic_info ADD CONSTRAINT DF_grn_basic_info_status DEFAULT 'Received' FOR status;
END
GO

-- 2. Add rejected_qty / condition to grn_item_details
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'grn_item_details' AND COLUMN_NAME = 'rejected_qty'
)
BEGIN
    ALTER TABLE dbo.grn_item_details
        ADD rejected_qty DECIMAL(10,3) NULL CONSTRAINT DF_grn_item_details_rejected_qty DEFAULT 0,
            condition VARCHAR(20) NULL CONSTRAINT DF_grn_item_details_condition DEFAULT 'Good';
END
GO

-- 3. Stored procedures
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
    FROM dbo.po_request_info
    WHERE po_basic_sno = @po_basic_sno;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @grn_no INT;
        SELECT @grn_no = ISNULL(MAX(grn_no), 0) + 1 FROM dbo.grn_basic_info;

        INSERT INTO dbo.grn_basic_info (
            grn_no, com_sno, div_sno, brn_sno, dept_sno, gate_entry_sno, po_basic_sno, vendor_sno,
            received_date, doc_ref_no, vehicle_no, challan_no, remarks, is_active, status, created_by, created_date
        )
        VALUES (
            @grn_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @gate_entry_sno, @po_basic_sno, @vendor_sno,
            @received_date, @doc_ref_no, @vehicle_no, @challan_no, @remarks, 'Y', 'Received', @created_by, GETDATE()
        );

        SET @grn_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.grn_item_details (
            grn_basic_sno, po_item_sno, prod_sno, prod_name, specification,
            po_qty, received_qty, diff_qty, rejected_qty, unit_name, condition, hsn_code, remarks,
            created_by, created_date, is_active
        )
        SELECT
            @grn_basic_sno,
            j.po_item_sno,
            j.prod_sno,
            j.prod_name,
            j.specification,
            j.ordered_qty,
            j.received_qty,
            (ISNULL(j.received_qty, 0) - ISNULL(j.ordered_qty, 0)),
            ISNULL(j.rejected_qty, 0),
            j.unit_name,
            ISNULL(j.condition, 'Good'),
            NULLIF(LTRIM(RTRIM(j.hsn_code)), ''),
            j.remarks,
            @created_by,
            GETDATE(),
            'Y'
        FROM OPENJSON(@items)
        WITH (
            po_item_sno   INT           '$.po_item_sno',
            prod_sno      INT           '$.prod_sno',
            prod_name     VARCHAR(255)  '$.prod_name',
            specification VARCHAR(500)  '$.specification',
            ordered_qty   DECIMAL(18,2) '$.ordered_qty',
            received_qty  DECIMAL(18,2) '$.received_qty',
            rejected_qty  DECIMAL(18,2) '$.rejected_qty',
            unit_name     VARCHAR(50)   '$.unit_name',
            condition     VARCHAR(20)   '$.condition',
            hsn_code      VARCHAR(10)   '$.hsn_code',
            remarks       VARCHAR(500)  '$.remarks'
        ) j;

        -- line-level audit trail
        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, po_item_sno, grn_basic_sno, gate_entry_sno,
            qty, pending_qty_after, to_status, status_by, remarks
        )
        SELECT
            'Item Received',
            @po_basic_sno,
            j.po_item_sno,
            @grn_basic_sno,
            @gate_entry_sno,
            j.received_qty,
            (ISNULL(j.ordered_qty, 0) - ISNULL(j.received_qty, 0)),
            'Received',
            @created_by,
            j.remarks
        FROM OPENJSON(@items)
        WITH (
            po_item_sno   INT           '$.po_item_sno',
            ordered_qty   DECIMAL(18,2) '$.ordered_qty',
            received_qty  DECIMAL(18,2) '$.received_qty',
            remarks       VARCHAR(500)  '$.remarks'
        ) j;

        -- header-level audit trail
        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, grn_basic_sno, gate_entry_sno, to_status, status_by, remarks
        )
        VALUES (
            'GRN Created', @po_basic_sno, @grn_basic_sno, @gate_entry_sno, 'Received', @created_by, @remarks
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        b.po_basic_sno,
        b.vendor_sno,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        CONVERT(VARCHAR(30), b.created_date, 120) AS created_at
    FROM dbo.grn_basic_info b
    WHERE b.grn_basic_sno = @grn_basic_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAllGRNs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @status = JSON_VALUE(@jsonInput, '$.status');

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                 AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)  AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.created_by                                AS received_by_name,
        CONVERT(VARCHAR(30), b.created_date, 120)    AS created_at,
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
                gi.remarks
            FROM dbo.grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
              AND gi.is_active = 'Y'
            FOR JSON PATH
        )                                            AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge   ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.is_active = 'Y'
      AND (@status IS NULL OR b.status = @status)
    ORDER BY b.grn_basic_sno DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNsByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

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
                gi.remarks
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
    ORDER BY b.grn_basic_sno DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPendingGateEntriesForGRN
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_no NVARCHAR(30) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @gate_entry_no = JSON_VALUE(@jsonInput, '$.gate_entry_no');

    SELECT
        g.gate_entry_sno,
        g.gate_entry_no,
        g.invoice_no,
        CONVERT(VARCHAR(10), g.invoice_date, 120)   AS invoice_date,
        g.received_qty                              AS gate_received_qty,
        CONVERT(VARCHAR(10), g.received_date, 120)  AS gate_received_date,
        g.status                                     AS gate_entry_status,

        p.po_basic_sno,
        p.po_df_no                                   AS po_no,
        p.pr_basic_sno,
        pr.pr_no                                     AS pr_no,
        p.vendor_sno,
        k.company_name                               AS vendor_name,
        c.com_name                                   AS com_name,
        CONVERT(VARCHAR(10), p.po_date, 120)          AS po_date,
        CONVERT(VARCHAR(10), p.required_date, 120)    AS required_date,
        p.delivery_address,
        p.terms_conditions,
        p.purpose,
        p.com_sno,
        p.div_sno,
        dv.div_name,
        p.brn_sno,
        br.brn_name,
        p.dept_sno,
        dp.dept_name,
        p.status,

        (
            SELECT
                i.po_item_sno,
                i.prod_sno,
                ISNULL(i.prod_name, pm.prod_name)      AS prod_name,
                i.specification,
                i.qty                                   AS ordered_qty,
                ISNULL(i.unit_name, um.uom_name)        AS unit_name,
                i.agreed_unit_price                     AS unit_price,
                i.net_cost                               AS total_amount,
                ISNULL(rq.received_so_far, 0)           AS received_qty,
                (i.qty - ISNULL(rq.received_so_far, 0)) AS pending_qty
            FROM dbo.po_item_details i
            LEFT JOIN dbo.product_master pm
                ON pm.prod_sno = i.prod_sno
            LEFT JOIN dbo.uom_master um
                ON um.uom_sno = i.unit
            LEFT JOIN (
                SELECT
                    gi.po_item_sno,
                    SUM(gi.received_qty) AS received_so_far
                FROM dbo.grn_item_details gi
                WHERE gi.is_active = 'Y'
                GROUP BY gi.po_item_sno
            ) rq
                ON rq.po_item_sno = i.po_item_sno
            WHERE i.po_basic_sno = p.po_basic_sno
                -- po_item_details.is_active has been observed as '1' rather than 'Y' in production
                AND i.is_active IN ('1', 'Y')
            FOR JSON PATH
        ) AS items

    FROM dbo.nt_gate_entry g
    JOIN dbo.po_request_info p
        ON p.po_basic_sno = g.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k
        ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.company_master c
        ON c.com_sno = p.com_sno
    LEFT JOIN dbo.division_master dv
        ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br
        ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp
        ON dp.dept_sno = p.dept_sno
    LEFT JOIN dbo.pr_basic_info pr
        ON pr.pr_basic_sno = p.pr_basic_sno

    WHERE g.status <> 'GRN Done'
        AND (@gate_entry_no IS NULL OR g.gate_entry_no = @gate_entry_no)

    ORDER BY g.gate_entry_sno DESC;
END;
GO
