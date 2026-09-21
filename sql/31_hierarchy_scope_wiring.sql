-- ============================================================
-- Company/Division/Branch access scoping for grn-service list endpoints.
-- Database: Non_trade_Dev (MSSQL)
--
-- Companion to backend-stpl/sql/78_hierarchy_scope_wiring.sql — same
-- convention: an optional @HierarchyJson (or jsonInput.hierarchy for procs
-- that already take a single JSON blob) array of {com_sno, div_sno,
-- brn_sno}. NULL/absent = unfiltered (kept for internal/ops callers that
-- intentionally want everything). The Node layer always sends an actual
-- array — '[]' for an ecno with no assigned hierarchy — never omits it, so
-- the fail-closed "sees nothing until granted" default lives in
-- grn-service/src/middleware/hierarchyScope.js, not here.
--
-- sp_nt_GetStockSummary already had this (grn-service/sql/29_inventory_
-- stock_level_reference.sql) — needed no SQL change, only Node wiring.
-- This file extends the same pattern to the other org-scoped list procs:
-- GRN (grn_basic_info has com/div/brn), Inventory items (nt_inventory_items
-- has com/div/brn) and Stock Requests (nt_stock_requests has com/div/brn).
-- Each proc pulled fresh via OBJECT_DEFINITION() before editing, per
-- backend-stpl's established convention — the on-disk files these are
-- based on had already drifted from live in prior sessions.
-- ============================================================

-- ── sp_nt_GetAllGRNs ─────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAllGRNs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
    END

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
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
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
END;
GO

-- ── sp_nt_GetGRNsByPO ────────────────────────────────────────────────────
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
END;
GO

-- ── sp_nt_GetInventoryItems — add @HierarchyJson alongside the existing ───
-- ── explicit @com_sno/@div_sno/@brn_sno params (both apply, AND'd) ────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetInventoryItems
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @category  VARCHAR(50)  = NULL;
    DECLARE @warehouse VARCHAR(100) = NULL;
    DECLARE @status    VARCHAR(20)  = NULL;
    DECLARE @com_sno   INT          = NULL;
    DECLARE @div_sno   INT          = NULL;
    DECLARE @brn_sno   INT          = NULL;
    DECLARE @dept_sno  INT          = NULL;
    DECLARE @exclude_non_regular BIT = 0;
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @category  = JSON_VALUE(@jsonInput, '$.category');
        SET @warehouse = JSON_VALUE(@jsonInput, '$.warehouse');
        SET @status    = JSON_VALUE(@jsonInput, '$.status');
        SET @com_sno   = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno   = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno   = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno  = JSON_VALUE(@jsonInput, '$.dept_sno');
        SET @exclude_non_regular = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.exclude_non_regular') AS BIT), 0);
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
    END

    SELECT
        i.item_sno, i.item_code, i.item_name, i.category, i.sub_category, i.uom,
        i.current_stock, i.min_stock, i.max_stock, i.reorder_qty, i.warehouse,
        i.location AS location_code,
        wl.location_name,
        i.cost_price, i.selling_price, i.status, i.hsn_code, i.description, i.prod_sno,
        i.com_sno, c.com_name,
        i.div_sno, dv.div_name,
        i.brn_sno, br.brn_name,
        i.dept_sno, dp.dept_name,
        sl.min_qty       AS master_min_qty,
        sl.max_qty       AS master_max_qty,
        sl.reorder_level AS master_reorder_level,
        sl.scope_type    AS master_scope_type,
        scm.subcat_stock_type,
        scm.perishable_days,
        CONVERT(VARCHAR(10), lr.last_received_date, 120) AS last_received_date,
        CASE WHEN lr.last_received_date IS NOT NULL
             THEN DATEDIFF(DAY, lr.last_received_date, GETDATE())
             ELSE NULL END AS days_since_last_received,
        CASE WHEN scm.subcat_stock_type = 'Perishable'
                  AND scm.perishable_days IS NOT NULL
                  AND i.current_stock > 0
                  AND lr.last_received_date IS NOT NULL
                  AND DATEDIFF(DAY, lr.last_received_date, GETDATE()) > scm.perishable_days
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_expiry_stock,
        CONVERT(VARCHAR(30), i.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), i.updated_at, 120) AS updated_at
    FROM dbo.nt_inventory_items i
    LEFT JOIN dbo.company_master c   ON c.com_sno  = i.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = i.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = i.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = i.dept_sno
    LEFT JOIN dbo.product_master pm      ON pm.prod_sno   = i.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    LEFT JOIN dbo.warehouse_location_master wl ON wl.location_code = i.location
    OUTER APPLY (
        SELECT TOP 1
            p.min_qty, p.max_qty, p.reorder_level, p.scope_type,
            CASE
                WHEN p.scope_type = 'LOCATION' THEN 100
                WHEN p.brn_sno IS NOT NULL THEN 3
                WHEN p.div_sno IS NOT NULL THEN 2
                ELSE 1
            END AS specificity
        FROM dbo.product_stock_level_master p
        WHERE i.prod_sno IS NOT NULL
          AND p.prod_sno = i.prod_sno
          AND p.is_active = 'Y'
          AND (
                (p.scope_type = 'LOCATION' AND wl.location_sno IS NOT NULL AND p.location_sno = wl.location_sno)
             OR (p.scope_type = 'ORG' AND p.com_sno = i.com_sno
                 AND (p.div_sno IS NULL OR p.div_sno = i.div_sno)
                 AND (p.brn_sno IS NULL OR p.brn_sno = i.brn_sno))
              )
        ORDER BY specificity DESC
    ) sl
    OUTER APPLY (
        SELECT MAX(gb.received_date) AS last_received_date
        FROM dbo.grn_item_details gi
        JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
        WHERE i.prod_sno IS NOT NULL
          AND gi.prod_sno = i.prod_sno
          AND gi.is_active = 'Y'
          AND gb.is_active = 'Y'
    ) lr
    WHERE (@category  IS NULL OR i.category  = @category)
      AND (@warehouse IS NULL OR i.warehouse = @warehouse)
      AND (@status    IS NULL OR i.status    = @status)
      AND (@com_sno   IS NULL OR i.com_sno   = @com_sno)
      AND (@div_sno   IS NULL OR i.div_sno   = @div_sno)
      AND (@brn_sno   IS NULL OR i.brn_sno   = @brn_sno)
      AND (@dept_sno  IS NULL OR i.dept_sno  = @dept_sno)
      AND (@exclude_non_regular = 0 OR ISNULL(scm.subcat_stock_type, 'Regular') NOT IN ('Non-Regular', 'Perishable'))
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = i.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = i.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = i.brn_sno)
          )
      )
    ORDER BY i.item_sno DESC;
END;
GO

-- ── sp_nt_GetStockRequests ───────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockRequests
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status       VARCHAR(30) = NULL;
    DECLARE @requested_by VARCHAR(50) = NULL;
    DECLARE @com_sno      INT         = NULL;
    DECLARE @div_sno      INT         = NULL;
    DECLARE @brn_sno      INT         = NULL;
    DECLARE @dept_sno     INT         = NULL;
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status       = JSON_VALUE(@jsonInput, '$.status');
        SET @requested_by = JSON_VALUE(@jsonInput, '$.requested_by');
        SET @com_sno      = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno      = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno      = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno     = JSON_VALUE(@jsonInput, '$.dept_sno');
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
    END

    SELECT
        r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
        r.purpose, r.status, r.reject_reason, r.issued_by,
        r.source_type, r.pr_basic_sno, r.pr_no, r.grn_basic_sno,
        r.received_by_ecno, r.received_by_name,
        r.com_sno, c.com_name,
        r.div_sno, dv.div_name,
        r.brn_sno, br.brn_name,
        r.dept_sno, dp.dept_name,
        (SELECT COUNT(*)                 FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS item_count,
        (SELECT ISNULL(SUM(requested_qty), 0) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_requested_qty,
        (SELECT ISNULL(SUM(issued_qty), 0)    FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_issued_qty,
        CONVERT(VARCHAR(30), r.issued_at, 120)  AS issued_at,
        CONVERT(VARCHAR(30), r.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), r.updated_at, 120) AS updated_at
    FROM dbo.nt_stock_requests r
    LEFT JOIN dbo.company_master c   ON c.com_sno  = r.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = r.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = r.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = r.dept_sno
    WHERE (@status       IS NULL OR r.status       = @status)
      AND (@requested_by IS NULL OR r.requested_by = @requested_by)
      AND (@com_sno      IS NULL OR r.com_sno      = @com_sno)
      AND (@div_sno      IS NULL OR r.div_sno      = @div_sno)
      AND (@brn_sno      IS NULL OR r.brn_sno      = @brn_sno)
      AND (@dept_sno     IS NULL OR r.dept_sno     = @dept_sno)
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = r.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = r.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = r.brn_sno)
          )
      )
    ORDER BY r.request_sno DESC;
END;
GO
