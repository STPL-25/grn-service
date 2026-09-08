-- ============================================================
-- Real-time notifications: PR requester on GRN receipt, receiver on Store Issue
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/inventory (receiveFromGRN),
--            grn-service/src/stockrequest (issueRequest)
--
-- Why this is needed
-- ------------------
-- Two events should notify a specific employee in real time, persisted so
-- they see it later if offline: (1) when GRN receives an item, the PR's
-- original requester should be told their item has arrived at the store —
-- for ANY PR-linked item, Regular or Non-Regular, not just the auto-issue
-- (Non-Regular) case; (2) when a Store Issue is completed, the employee who
-- received the goods (nt_stock_requests/nt_stock_movements.received_by_ecno,
-- added in 22_nonregular_direct_issue.sql) should be told what and how much
-- they received.
--
-- Delivery reuses the existing in-app "bell" pathway end to end — no new
-- table, no new Socket.IO plumbing, no new frontend: notification-service's
-- nt_notifications table + POST /api/notifications already persists and
-- broadcasts to the recipient's `user:<ecno>` Socket.IO room, and
-- NotificationBell.tsx already renders it live everywhere in the app. This
-- migration only touches the SQL side: sp_nt_AutoCreateStockIssueFromGRN is
-- widened to resolve+return PR-requester info for EVERY PR-traceable GRN
-- line (not only Non-Regular ones, where it already had this join for the
-- auto-create decision) so grn-service/src/inventory/inventory.service.js
-- can fire the "your item arrived" notification regardless of stock type.
-- The actual HTTP call to notification-service happens in Node
-- (grn-service/src/utils/notifyClient.js#createInAppNotification), same as
-- every existing notification trigger in this codebase — SQL never calls
-- out over HTTP itself.
-- ============================================================

-- ============================================================
-- sp_nt_AutoCreateStockIssueFromGRN — now always resolves+returns PR
-- requester info when the GRN line is PR-traceable, regardless of the
-- product's subcategory stock type. The Non-Regular auto-create side effect
-- (INSERT into nt_stock_requests/nt_stock_request_items) is unchanged and
-- still gated on stock_type = 'Non-Regular'; request_sno/request_no in the
-- result are NULL when that side effect didn't run (Regular item, or a
-- duplicate replay of an already-processed Non-Regular line).
-- @jsonInput: { po_item_sno, item_sno, qty, grn_basic_sno, grn_no, created_by }
-- Returns 0 rows if the GRN line isn't PR-traceable, or is a duplicate
-- replay of an already-auto-created Non-Regular line (nothing new to notify
-- or create either way). Otherwise 1 row: requester_ecno, requester_name,
-- pr_no, pr_basic_sno, stock_type, item_name, uom, qty, request_sno, request_no.
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

    -- Not PR-traceable (e.g. a direct/Store PO line) -> nothing to create,
    -- nothing to notify.
    IF @pr_item_sno IS NULL
        RETURN;

    -- Idempotency: this exact Non-Regular GRN line already produced a
    -- request (a retried GRN post). Nothing new to create or (re-)notify.
    IF @stock_type = 'Non-Regular' AND EXISTS (
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

    -- Non-Regular only: auto-create the directly-issuable Pending request so
    -- the requester never has to raise a manual Store Requisition.
    IF @stock_type = 'Non-Regular'
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
    END

    -- Always returned when PR-traceable, so the caller can notify the
    -- requester regardless of stock type. request_sno/request_no are only
    -- non-NULL when the Non-Regular auto-create above just ran.
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
-- After running, confirm:
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_AutoCreateStockIssueFromGRN'));
-- ============================================================
