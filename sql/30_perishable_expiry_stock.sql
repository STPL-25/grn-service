-- ============================================================
-- Perishable stock: auto-issue off GRN like Non-Regular, plus an
-- "Expiry Stock" signal on the Inventory Stock page.
-- Database: Non_trade_Dev (MSSQL)
--
-- Requires backend-stpl/sql/77_subcategory_perishable_type.sql to have run
-- first (adds subcat_stock_type = 'Perishable' and subcategory_master.
-- perishable_days).
--
-- Both procedures below are reproduced from their live OBJECT_DEFINITION()
-- (not from the on-disk 22_nonregular_direct_issue.sql / 29_inventory_
-- stock_level_reference.sql copies, which had already drifted from live).
-- Only the marked lines change.
-- ============================================================

-- ============================================================
-- sp_nt_AutoCreateStockIssueFromGRN
-- Change: the auto-create-Pending-request fast path (previously gated on
-- @stock_type = 'Non-Regular' only) now also fires for 'Perishable'. No
-- change needed anywhere else — sp_nt_IssueStockRequest already supports
-- issuing part of a request now and the remainder later (Pending ->
-- Partially Issued -> Issued), so Perishable inherits that for free.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_AutoCreateStockIssueFromGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_item_sno   INT           = JSON_VALUE(@jsonInput, '$.po_item_sno');
    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @qty           DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.qty');
    DECLARE @grn_basic_sno INT           = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @grn_no        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.grn_no');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @po_item_sno IS NULL OR @item_sno IS NULL OR @qty IS NULL OR @qty <= 0
        RETURN;

    -- Resolve PR origin + the product's subcategory stock type in one hop.
    DECLARE @pr_item_sno    INT,
            @pr_basic_sno   INT,
            @pr_no          VARCHAR(20),
            @requester_ecno VARCHAR(20),
            @com_sno        INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
            @stock_type     VARCHAR(20);

    SELECT
        @pr_item_sno    = pid.pr_item_sno,
        @pr_basic_sno   = pb.pr_basic_sno,
        @pr_no          = pb.pr_no,
        @requester_ecno = pb.created_by,
        @com_sno        = pb.com_sno,
        @div_sno        = pb.div_sno,
        @brn_sno        = pb.brn_sno,
        @dept_sno       = pb.dept_sno,
        @stock_type     = scm.subcat_stock_type
    FROM dbo.po_item_details poid
    JOIN dbo.pr_item_details pid ON pid.pr_item_sno = poid.pr_item_sno
    JOIN dbo.pr_basic_info pb    ON pb.pr_basic_sno = pid.pr_basic_sno
    LEFT JOIN dbo.product_master pm     ON pm.prod_sno   = pid.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    WHERE poid.po_item_sno = @po_item_sno;

    -- Not PR-traceable (e.g. a direct/Store PO line) -> nothing to create,
    -- nothing to notify.
    IF @pr_item_sno IS NULL
        RETURN;

    -- Idempotency: this exact Non-Regular/Perishable GRN line already
    -- produced a request (a retried GRN post). Nothing new to create or
    -- (re-)notify.
    IF @stock_type IN ('Non-Regular', 'Perishable') AND EXISTS (
        SELECT 1
        FROM dbo.nt_stock_request_items sri
        JOIN dbo.nt_stock_requests sr ON sr.request_sno = sri.request_sno
        WHERE sr.grn_basic_sno = @grn_basic_sno AND sri.po_item_sno = @po_item_sno
    )
        RETURN;

    DECLARE @requester_name VARCHAR(255);
    SELECT @requester_name = ename FROM dbo.vw_verified_employees WHERE ecno = @requester_ecno;

    DECLARE @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20);
    SELECT @item_code = item_code, @item_name = item_name, @uom = uom
    FROM dbo.nt_inventory_items WHERE item_sno = @item_sno;

    DECLARE @request_sno INT, @request_no VARCHAR(30);

    -- Non-Regular AND Perishable: auto-create the directly-issuable Pending
    -- request so the requester never has to raise a manual Store
    -- Requisition. (Perishable added here; Non-Regular behavior unchanged.)
    IF @stock_type IN ('Non-Regular', 'Perishable')
    BEGIN
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

        BEGIN TRANSACTION;
        BEGIN TRY
            DECLARE @seq INT;
            SELECT @seq = ISNULL(MAX(CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_stock_requests WITH (UPDLOCK, HOLDLOCK)
            WHERE request_no LIKE 'SR-' + @year + '-%';

            SET @request_no = 'SR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

            INSERT INTO dbo.nt_stock_requests (
                request_no, requested_by, requested_name, purpose, status,
                source_type, pr_basic_sno, pr_no, grn_basic_sno,
                com_sno, div_sno, brn_sno, dept_sno, created_at
            )
            VALUES (
                @request_no, @requester_ecno, @requester_name,
                'Auto: GRN receipt for ' + @stock_type + ' item, PR ' + ISNULL(@pr_no, ''), 'Pending',
                'Auto-GRN', @pr_basic_sno, @pr_no, @grn_basic_sno,
                @com_sno, @div_sno, @brn_sno, @dept_sno, GETDATE()
            );

            SET @request_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.nt_stock_request_items (
                request_sno, item_sno, item_code, item_name, uom,
                requested_qty, issued_qty, line_status, pr_item_sno, po_item_sno
            )
            VALUES (
                @request_sno, @item_sno, @item_code, @item_name, @uom,
                @qty, 0, 'Pending', @pr_item_sno, @po_item_sno
            );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            THROW;
        END CATCH
    END

    -- Always returned when PR-traceable, so the caller can notify the
    -- requester regardless of stock type. request_sno/request_no are only
    -- non-NULL when the auto-create above just ran.
    SELECT
        @requester_ecno AS requester_ecno,
        @requester_name AS requester_name,
        @pr_no          AS pr_no,
        @pr_basic_sno   AS pr_basic_sno,
        @stock_type     AS stock_type,
        @item_name      AS item_name,
        @uom            AS uom,
        @qty            AS qty,
        @request_sno    AS request_sno,
        @request_no     AS request_no;
END;
GO

-- ============================================================
-- sp_nt_GetInventoryItems
-- Additive changes only:
--   - subcat_stock_type / perishable_days now selected (subcategory_master
--     was already joined for the exclude_non_regular filter).
--   - last_received_date / days_since_last_received: an approximation, not
--     true batch aging (this codebase has no per-batch remaining-qty
--     tracking — see grn-service/sql/02_inventory.sql's nt_stock_movements,
--     a flat running-balance ledger with no lot/FIFO concept). It's
--     MAX(grn_basic_info.received_date) across every GRN for that product,
--     i.e. "last time this product was topped up" — if stock is
--     replenished before the older remainder clears, the older remainder
--     will look artificially fresh. Accepted tradeoff for short-shelf-life,
--     daily-cadence perishables (vegetables/milk/eggs) rather than building
--     full batch/lot tracking.
--   - is_expiry_stock: current_stock > 0 AND subcat_stock_type =
--     'Perishable' AND perishable_days configured AND days since last
--     receipt > perishable_days.
--   - @exclude_non_regular now also excludes Perishable (same rationale as
--     Non-Regular: it's earmarked for its own PR's auto-issue, shouldn't be
--     manually requisitioned out from under the original requester).
-- ============================================================
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
    ORDER BY i.item_sno DESC;
END;
GO
