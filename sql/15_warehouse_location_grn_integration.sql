-- ============================================================
-- Warehouse Location <-> GRN integration
-- Database : Non_Trade (MSSQL, 10.0.21.8) — same physical DB as backend-stpl,
-- which is why this can read dbo.warehouse_location_master directly (see
-- backend-stpl/sql/16_warehouse_location_master.sql for that table +
-- its Get/Create procs, same pattern grn-service already relies on for
-- dbo.company_master / dbo.division_master / dbo.branch_master joins in
-- sp_nt_GetPendingGateEntriesForGRN).
--
-- What this does:
--   1. Adds warehouse_location_sno / warehouse_location_name to
--      grn_item_details — the per-line "which location did this receipt
--      go into" field the GRN entry screen now captures.
--   2. Re-points sp_nt_CreateGRN (v3, superseding the v2 in
--      07_grn_procs_v2.sql) to accept/store warehouse_location_sno per
--      item, resolving warehouse_location_name server-side via a join
--      (never trusts a client-supplied name string).
--   3. Adds the same two columns to sp_nt_GetAllGRNs / sp_nt_GetGRNsByPO's
--      item JSON so GRN history/detail views can show the location.
--   4. Adds sp_nt_GetWarehouseLocationsForGRN — given a GRN's
--      com_sno/div_sno/brn_sno (looked up from po_request_info, same as
--      the GRN header itself), returns only the locations whose
--      com_snos/div_snos/brn_snos scope actually covers that PO's org
--      unit, so the entry screen's Location dropdown never offers a
--      location that doesn't apply there. An empty div_snos/brn_snos on a
--      location means "not restricted at that level" (see the master's
--      own file for the scoping rule).
--
-- warehouse_location_sno is nullable — existing GRN flows for org scopes
-- that don't have any locations configured yet keep working unchanged.
-- ============================================================

-- 1. Add columns to grn_item_details
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'grn_item_details' AND COLUMN_NAME = 'warehouse_location_sno'
)
BEGIN
    ALTER TABLE dbo.grn_item_details
        ADD warehouse_location_sno  INT           NULL,
            warehouse_location_name VARCHAR(150)  NULL;
END
GO

-- 2. sp_nt_CreateGRN v3 — adds warehouse_location_sno/_name per item
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
            warehouse_location_sno, warehouse_location_name,
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
            j.warehouse_location_sno,
            wl.location_name,
            @created_by,
            GETDATE(),
            'Y'
        FROM OPENJSON(@items)
        WITH (
            po_item_sno             INT           '$.po_item_sno',
            prod_sno                 INT           '$.prod_sno',
            prod_name                VARCHAR(255)  '$.prod_name',
            specification             VARCHAR(500)  '$.specification',
            ordered_qty                DECIMAL(18,2) '$.ordered_qty',
            received_qty                DECIMAL(18,2) '$.received_qty',
            rejected_qty                 DECIMAL(18,2) '$.rejected_qty',
            unit_name                     VARCHAR(50)   '$.unit_name',
            condition                      VARCHAR(20)   '$.condition',
            hsn_code                        VARCHAR(10)   '$.hsn_code',
            remarks                          VARCHAR(500)  '$.remarks',
            warehouse_location_sno            INT           '$.warehouse_location_sno'
        ) j
        LEFT JOIN dbo.warehouse_location_master wl ON wl.location_sno = j.warehouse_location_sno;

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

-- 3. sp_nt_GetAllGRNs / sp_nt_GetGRNsByPO — add location to the item JSON
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
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name
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
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name
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

-- 4. sp_nt_GetWarehouseLocationsForGRN — locations valid for a GRN's org scope
-- @jsonInput: { com_sno, div_sno, brn_sno }
-- A location matches when @com_sno is one of its com_snos, AND its div_snos
-- is either empty (unrestricted) or contains @div_sno, AND likewise for
-- brn_snos/@brn_sno.
IF OBJECT_ID('dbo.sp_nt_GetWarehouseLocationsForGRN', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetWarehouseLocationsForGRN;
GO
CREATE PROCEDURE dbo.sp_nt_GetWarehouseLocationsForGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno INT = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno INT = JSON_VALUE(@jsonInput, '$.brn_sno');

    SELECT l.location_sno, l.location_code, l.location_name, l.description
    FROM dbo.warehouse_location_master l
    WHERE l.is_active = 'Y'
      AND (
          @com_sno IS NULL
          OR EXISTS (SELECT 1 FROM OPENJSON(l.com_snos) j WHERE TRY_CAST(j.value AS INT) = @com_sno)
      )
      AND (
          @div_sno IS NULL
          OR NOT EXISTS (SELECT 1 FROM OPENJSON(l.div_snos))
          OR EXISTS (SELECT 1 FROM OPENJSON(l.div_snos) j WHERE TRY_CAST(j.value AS INT) = @div_sno)
      )
      AND (
          @brn_sno IS NULL
          OR NOT EXISTS (SELECT 1 FROM OPENJSON(l.brn_snos))
          OR EXISTS (SELECT 1 FROM OPENJSON(l.brn_snos) j WHERE TRY_CAST(j.value AS INT) = @brn_sno)
      )
    ORDER BY l.location_name;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.procedures WHERE name = 'sp_nt_GetWarehouseLocationsForGRN';
--   SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
--     WHERE TABLE_NAME = 'grn_item_details' AND COLUMN_NAME LIKE 'warehouse_location%';
-- ============================================================
