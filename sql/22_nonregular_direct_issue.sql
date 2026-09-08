-- ============================================================
-- Non-Regular items: skip Store Requisition, auto-issue straight off GRN
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/inventory (receiveFromGRN),
--            grn-service/src/stockrequest (Store Issue)
--
-- Why this is needed
-- ------------------
-- Regular (day-to-day) items keep the existing flow: GRN -> nt_inventory_items
-- -> a user manually raises a Store Requisition -> a store incharge Issues it.
-- A Non-Regular item (subcategory_master.subcat_stock_type = 'Non-Regular',
-- see 50_subcategory_stock_type.sql in backend-stpl/sql) was bought for one
-- specific PR's need — once GRN receives it there is no reason to make the
-- requester separately raise a requisition for stock that already exists
-- solely because of their own PR. Instead, the GRN receipt itself creates the
-- Pending nt_stock_requests/nt_stock_request_items row (source_type =
-- 'Auto-GRN'), tied back to the originating PR via the existing
-- pr_item_details.pr_item_sno -> po_item_details.pr_item_sno/po_item_sno ->
-- grn_item_details.po_item_sno chain. The store incharge then just opens
-- Store Issue like any other pending request.
--
-- Also added: the receiving employee's ECNO, captured at ISSUE time (not
-- request time) and validated against the existing vw_verified_employees
-- view — applies to every issue, manual or auto, since both flows share
-- sp_nt_IssueStockRequest.
--
-- And: sp_nt_GetInventoryItems gets an optional @exclude_non_regular flag so
-- the manual "New Requisition" item picker can stop offering Non-Regular
-- items — that stock is earmarked for the auto-issue path only, so leaving
-- it in the shared manual pick-list would let someone else request/drain it
-- out from under the original requester before their auto-issue is fulfilled.
-- ============================================================

-- ── nt_stock_requests: source + PR/GRN linkage + receiver ──────────────────
IF COL_LENGTH('dbo.nt_stock_requests', 'source_type') IS NULL
    ALTER TABLE dbo.nt_stock_requests ADD source_type VARCHAR(20) NOT NULL
        CONSTRAINT DF_nt_stock_requests_source_type DEFAULT 'Manual';
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_nt_stock_requests_source_type')
    ALTER TABLE dbo.nt_stock_requests ADD CONSTRAINT CK_nt_stock_requests_source_type
        CHECK (source_type IN ('Manual', 'Auto-GRN'));
GO

IF COL_LENGTH('dbo.nt_stock_requests', 'pr_basic_sno') IS NULL
    ALTER TABLE dbo.nt_stock_requests ADD pr_basic_sno INT NULL;
GO

IF COL_LENGTH('dbo.nt_stock_requests', 'pr_no') IS NULL
    ALTER TABLE dbo.nt_stock_requests ADD pr_no VARCHAR(20) NULL;
GO

IF COL_LENGTH('dbo.nt_stock_requests', 'grn_basic_sno') IS NULL
    ALTER TABLE dbo.nt_stock_requests ADD grn_basic_sno INT NULL;
GO

IF COL_LENGTH('dbo.nt_stock_requests', 'received_by_ecno') IS NULL
    ALTER TABLE dbo.nt_stock_requests ADD received_by_ecno VARCHAR(50) NULL;
GO

IF COL_LENGTH('dbo.nt_stock_requests', 'received_by_name') IS NULL
    ALTER TABLE dbo.nt_stock_requests ADD received_by_name VARCHAR(255) NULL;
GO

-- ── nt_stock_request_items: which PR/PO line this line came from ───────────
IF COL_LENGTH('dbo.nt_stock_request_items', 'pr_item_sno') IS NULL
    ALTER TABLE dbo.nt_stock_request_items ADD pr_item_sno INT NULL;
GO

IF COL_LENGTH('dbo.nt_stock_request_items', 'po_item_sno') IS NULL
    ALTER TABLE dbo.nt_stock_request_items ADD po_item_sno INT NULL;
GO

-- ── nt_stock_movements: who physically received the goods on this OUT ──────
IF COL_LENGTH('dbo.nt_stock_movements', 'received_by_ecno') IS NULL
    ALTER TABLE dbo.nt_stock_movements ADD received_by_ecno VARCHAR(50) NULL;
GO

IF COL_LENGTH('dbo.nt_stock_movements', 'received_by_name') IS NULL
    ALTER TABLE dbo.nt_stock_movements ADD received_by_name VARCHAR(255) NULL;
GO

-- ============================================================
-- sp_nt_AutoCreateStockIssueFromGRN
-- Called by grn-service/src/inventory/inventory.service.js#receiveFromGRN
-- right after it posts the IN stock movement for a GRN line.
-- @jsonInput: { po_item_sno, item_sno, qty, grn_basic_sno, grn_no, created_by }
--
-- No-ops (returns an empty result set) unless the product's subcategory is
-- Non-Regular AND the GRN line traces back to a PR item — regular items and
-- any item with no PR linkage (e.g. a direct/Store PO) are left completely
-- alone, so the existing manual Store Requisition flow is unaffected.
-- Idempotent per (grn_basic_sno, po_item_sno) so a retried GRN post can't
-- double-create the request.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_AutoCreateStockIssueFromGRN', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_AutoCreateStockIssueFromGRN;
GO

CREATE PROCEDURE dbo.sp_nt_AutoCreateStockIssueFromGRN
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

    -- Not PR-traceable (e.g. a direct/Store PO line), or the item is Regular
    -- (or has no subcategory at all) -> leave the manual requisition flow as
    -- the only path, exactly as before this feature existed.
    IF @pr_item_sno IS NULL OR @stock_type IS NULL OR @stock_type <> 'Non-Regular'
        RETURN;

    -- Idempotency: this exact GRN line already produced a request.
    IF EXISTS (
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
            'Auto: GRN receipt for non-regular item, PR ' + ISNULL(@pr_no, ''), 'Pending',
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

    SELECT @request_sno AS request_sno, @request_no AS request_no;
END;
GO

-- ============================================================
-- sp_nt_IssueStockRequest — now requires @received_by_ecno
-- @jsonInput: { request_sno, issued_by, received_by_ecno,
--               items: [ { sr_item_sno, issue_qty } ] }
-- Everything else is unchanged from 04_stock_request.sql; only the receiver
-- capture/validation and its two write sites (header + each movement) are new.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_IssueStockRequest', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_IssueStockRequest;
GO

CREATE PROCEDURE dbo.sp_nt_IssueStockRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno     INT         = JSON_VALUE(@jsonInput, '$.request_sno');
    DECLARE @issued_by       VARCHAR(50) = JSON_VALUE(@jsonInput, '$.issued_by');
    DECLARE @received_by_ecno VARCHAR(50) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.received_by_ecno'))), '');

    IF @request_sno IS NULL OR @issued_by IS NULL
    BEGIN
        RAISERROR('request_sno and issued_by are required.', 16, 1);
        RETURN;
    END

    IF @received_by_ecno IS NULL
    BEGIN
        RAISERROR('received_by_ecno (the receiving employee''s ECNO) is required.', 16, 1);
        RETURN;
    END

    DECLARE @received_by_name VARCHAR(255);
    SELECT @received_by_name = ename FROM dbo.vw_verified_employees WHERE ecno = @received_by_ecno;

    IF @received_by_name IS NULL
    BEGIN
        RAISERROR('Receiving employee not found or not verified.', 16, 1);
        RETURN;
    END

    DECLARE @request_no VARCHAR(30), @req_status VARCHAR(30);
    DECLARE @requested_by VARCHAR(50);
    SELECT @request_no = request_no, @req_status = status, @requested_by = requested_by
    FROM dbo.nt_stock_requests
    WHERE request_sno = @request_sno;

    IF @request_no IS NULL
    BEGIN
        RAISERROR('Stock request not found.', 16, 1);
        RETURN;
    END

    IF @req_status NOT IN ('Pending', 'Partially Issued')
    BEGIN
        RAISERROR('Only Pending or Partially Issued requests can be issued (current status: %s).', 16, 1, @req_status);
        RETURN;
    END

    DECLARE @issue TABLE (
        sr_item_sno INT,
        issue_qty   DECIMAL(18,2)
    );

    INSERT INTO @issue (sr_item_sno, issue_qty)
    SELECT sr_item_sno, issue_qty
    FROM OPENJSON(@jsonInput, '$.items')
    WITH (
        sr_item_sno INT           '$.sr_item_sno',
        issue_qty   DECIMAL(18,2) '$.issue_qty'
    )
    WHERE issue_qty IS NOT NULL AND issue_qty > 0;

    IF NOT EXISTS (SELECT 1 FROM @issue)
    BEGIN
        RAISERROR('No issue quantities supplied.', 16, 1);
        RETURN;
    END

    -- Lines must belong to this request
    IF EXISTS (
        SELECT 1 FROM @issue x
        LEFT JOIN dbo.nt_stock_request_items l
               ON l.sr_item_sno = x.sr_item_sno AND l.request_sno = @request_sno
        WHERE l.sr_item_sno IS NULL
    )
    BEGIN
        RAISERROR('One or more lines do not belong to this request.', 16, 1);
        RETURN;
    END

    BEGIN TRANSACTION;
    BEGIN TRY
        -- Over-issue guard against the line's remaining quantity
        IF EXISTS (
            SELECT 1 FROM @issue x
            JOIN dbo.nt_stock_request_items l WITH (UPDLOCK, HOLDLOCK)
              ON l.sr_item_sno = x.sr_item_sno
            WHERE x.issue_qty > (l.requested_qty - l.issued_qty)
        )
        BEGIN
            RAISERROR('Issue quantity exceeds the pending quantity on a line.', 16, 1);
            RETURN;
        END

        -- Stock availability guard
        IF EXISTS (
            SELECT 1 FROM @issue x
            JOIN dbo.nt_stock_request_items l ON l.sr_item_sno = x.sr_item_sno
            JOIN dbo.nt_inventory_items i WITH (UPDLOCK, HOLDLOCK)
              ON i.item_sno = l.item_sno
            WHERE x.issue_qty > i.current_stock
        )
        BEGIN
            RAISERROR('Insufficient stock for one or more items.', 16, 1);
            RETURN;
        END

        DECLARE @movements TABLE (movement_sno INT);

        -- Reduce stock item by item so each movement records its own
        -- balance_after (set-based UPDATE could not capture that).
        DECLARE @sr_item_sno INT, @issue_qty DECIMAL(18,2);
        DECLARE issue_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT sr_item_sno, issue_qty FROM @issue;

        OPEN issue_cur;
        FETCH NEXT FROM issue_cur INTO @sr_item_sno, @issue_qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @item_sno INT, @new_stock DECIMAL(18,2);

            SELECT @item_sno = item_sno
            FROM dbo.nt_stock_request_items
            WHERE sr_item_sno = @sr_item_sno;

            UPDATE dbo.nt_inventory_items
            SET current_stock = current_stock - @issue_qty,
                updated_by    = @issued_by,
                updated_at    = GETDATE(),
                @new_stock    = current_stock - @issue_qty
            WHERE item_sno = @item_sno;

            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason,
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at,
                received_by_ecno, received_by_name
            )
            SELECT
                i.item_sno, i.item_code, i.item_name, 'OUT', @issue_qty,
                @new_stock, i.uom, @request_no, i.warehouse,
                'Stock Request Issue (' + @requested_by + ')',
                i.com_sno, i.div_sno, i.brn_sno, i.dept_sno, @issued_by, GETDATE(),
                @received_by_ecno, @received_by_name
            FROM dbo.nt_inventory_items i
            WHERE i.item_sno = @item_sno;

            INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());

            UPDATE dbo.nt_stock_request_items
            SET issued_qty  = issued_qty + @issue_qty,
                line_status = CASE WHEN issued_qty + @issue_qty >= requested_qty
                                   THEN 'Issued' ELSE 'Partially Issued' END
            WHERE sr_item_sno = @sr_item_sno;

            FETCH NEXT FROM issue_cur INTO @sr_item_sno, @issue_qty;
        END
        CLOSE issue_cur;
        DEALLOCATE issue_cur;

        DECLARE @new_status VARCHAR(30) =
            CASE WHEN EXISTS (
                    SELECT 1 FROM dbo.nt_stock_request_items
                    WHERE request_sno = @request_sno AND issued_qty < requested_qty
                 )
                 THEN 'Partially Issued' ELSE 'Issued' END;

        UPDATE dbo.nt_stock_requests
        SET status           = @new_status,
            issued_by        = @issued_by,
            issued_at        = GETDATE(),
            received_by_ecno = @received_by_ecno,
            received_by_name = @received_by_name,
            updated_at       = GETDATE()
        WHERE request_sno = @request_sno;

        COMMIT TRANSACTION;

        -- Recordset 1: updated header
        SELECT
            r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
            r.purpose, r.status, r.issued_by, r.received_by_ecno, r.received_by_name,
            (SELECT ISNULL(SUM(issued_qty), 0) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_issued_qty,
            CONVERT(VARCHAR(30), r.issued_at, 120) AS issued_at
        FROM dbo.nt_stock_requests r
        WHERE r.request_sno = @request_sno;

        -- Recordset 2: the movements this issue created
        SELECT
            m.movement_sno, m.item_sno, m.item_code, m.item_name, m.movement_type,
            m.quantity, m.balance_after, m.uom, m.reference_no, m.warehouse, m.reason,
            m.received_by_ecno, m.received_by_name,
            m.created_by, CONVERT(VARCHAR(30), m.created_at, 120) AS created_at
        FROM dbo.nt_stock_movements m
        JOIN @movements x ON x.movement_sno = m.movement_sno
        ORDER BY m.movement_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_GetStockRequests — now also returns source_type / pr_no / receiver
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetStockRequests', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetStockRequests;
GO

CREATE PROCEDURE dbo.sp_nt_GetStockRequests
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

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status       = JSON_VALUE(@jsonInput, '$.status');
        SET @requested_by = JSON_VALUE(@jsonInput, '$.requested_by');
        SET @com_sno      = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno      = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno      = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno     = JSON_VALUE(@jsonInput, '$.dept_sno');
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
    ORDER BY r.request_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetStockRequestItems — now also returns pr_item_sno
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetStockRequestItems', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetStockRequestItems;
GO

CREATE PROCEDURE dbo.sp_nt_GetStockRequestItems
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno INT = JSON_VALUE(@jsonInput, '$.request_sno');

    SELECT
        l.sr_item_sno, l.request_sno, l.item_sno, l.item_code, l.item_name, l.uom,
        l.requested_qty, l.issued_qty, (l.requested_qty - l.issued_qty) AS pending_qty,
        l.line_status, l.remarks, l.pr_item_sno, l.po_item_sno,
        i.current_stock, i.warehouse, i.location
    FROM dbo.nt_stock_request_items l
    JOIN dbo.nt_inventory_items i ON i.item_sno = l.item_sno
    WHERE l.request_sno = @request_sno
    ORDER BY l.sr_item_sno;
END;
GO

-- ============================================================
-- sp_nt_GetInventoryItems — now accepts @exclude_non_regular
-- @jsonInput optional: { category, warehouse, status, com_sno, div_sno,
--                        brn_sno, dept_sno, exclude_non_regular }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetInventoryItems', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetInventoryItems;
GO

CREATE PROCEDURE dbo.sp_nt_GetInventoryItems
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
        i.current_stock, i.min_stock, i.max_stock, i.reorder_qty, i.warehouse, i.location,
        i.cost_price, i.selling_price, i.status, i.hsn_code, i.description, i.prod_sno,
        i.com_sno, c.com_name,
        i.div_sno, dv.div_name,
        i.brn_sno, br.brn_name,
        i.dept_sno, dp.dept_name,
        CONVERT(VARCHAR(30), i.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), i.updated_at, 120) AS updated_at
    FROM dbo.nt_inventory_items i
    LEFT JOIN dbo.company_master c   ON c.com_sno  = i.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = i.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = i.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = i.dept_sno
    LEFT JOIN dbo.product_master pm      ON pm.prod_sno   = i.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    WHERE (@category  IS NULL OR i.category  = @category)
      AND (@warehouse IS NULL OR i.warehouse = @warehouse)
      AND (@status    IS NULL OR i.status    = @status)
      AND (@com_sno   IS NULL OR i.com_sno   = @com_sno)
      AND (@div_sno   IS NULL OR i.div_sno   = @div_sno)
      AND (@brn_sno   IS NULL OR i.brn_sno   = @brn_sno)
      AND (@dept_sno  IS NULL OR i.dept_sno  = @dept_sno)
      AND (@exclude_non_regular = 0 OR ISNULL(scm.subcat_stock_type, 'Regular') <> 'Non-Regular')
    ORDER BY i.item_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.procedures WHERE name IN (
--     'sp_nt_AutoCreateStockIssueFromGRN','sp_nt_IssueStockRequest',
--     'sp_nt_GetStockRequests','sp_nt_GetStockRequestItems','sp_nt_GetInventoryItems');
--   SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='nt_stock_requests';
--   SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='nt_stock_request_items';
--   SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='nt_stock_movements';
-- ============================================================
