-- ============================================================
-- Stock Request module — user item requests + stock-incharge issue
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/stockrequest (port 8084, mounted at /api/stock_request)
--
-- NOT YET RUN on the live DB — review before executing on 10.0.21.8, then
-- run this whole file. Requires 02_inventory.sql (nt_inventory_items /
-- nt_stock_movements) to exist first.
--
-- Flow: a user picks in-stock items and raises a request (Pending). The
-- stock incharge issues quantities against it: sp_nt_IssueStockRequest
-- reduces nt_inventory_items.current_stock and writes an OUT row to
-- nt_stock_movements per issued line (reference_no = request_no), keeping
-- the "stock only changes through the movements ledger" invariant from
-- 02_inventory.sql intact.
--
-- Header status lifecycle:
--   Pending -> Issued | Partially Issued | Rejected
--   Pending -> Cancelled (by the requester)
--   Partially Issued -> Issued (a later issue completes the remainder)
--
-- All procedures follow this codebase's convention: a single optional
-- @jsonInput NVARCHAR(MAX) parameter, scalar fields via JSON_VALUE and
-- item arrays via OPENJSON.
-- ============================================================

-- ── Tables ────────────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.nt_stock_requests', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_stock_requests (
        request_sno     INT IDENTITY(1,1) PRIMARY KEY,
        request_no      VARCHAR(30)   NOT NULL UNIQUE,      -- SR-YYYY-0001
        requested_by    VARCHAR(50)   NOT NULL,             -- ecno
        requested_name  VARCHAR(255)  NULL,
        department      VARCHAR(100)  NULL,
        purpose         VARCHAR(500)  NULL,
        status          VARCHAR(30)   NOT NULL DEFAULT 'Pending',  -- Pending | Partially Issued | Issued | Rejected | Cancelled
        reject_reason   VARCHAR(500)  NULL,
        issued_by       VARCHAR(50)   NULL,                 -- last issuer / rejecter ecno
        issued_at       DATETIME      NULL,
        com_sno         INT           NULL,                 -- org hierarchy of the requester
        div_sno         INT           NULL,
        brn_sno         INT           NULL,
        dept_sno        INT           NULL,
        created_at      DATETIME      NOT NULL DEFAULT GETDATE(),
        updated_at      DATETIME      NULL
    );
END
GO

IF OBJECT_ID('dbo.nt_stock_request_items', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_stock_request_items (
        sr_item_sno     INT IDENTITY(1,1) PRIMARY KEY,
        request_sno     INT           NOT NULL,
        item_sno        INT           NOT NULL,
        item_code       VARCHAR(50)   NULL,
        item_name       VARCHAR(255)  NULL,
        uom             VARCHAR(20)   NULL,
        requested_qty   DECIMAL(18,2) NOT NULL,
        issued_qty      DECIMAL(18,2) NOT NULL DEFAULT 0,
        line_status     VARCHAR(30)   NOT NULL DEFAULT 'Pending',  -- Pending | Partially Issued | Issued | Rejected | Cancelled
        remarks         VARCHAR(255)  NULL,
        CONSTRAINT FK_nt_sr_items_request
            FOREIGN KEY (request_sno) REFERENCES dbo.nt_stock_requests (request_sno),
        CONSTRAINT FK_nt_sr_items_item
            FOREIGN KEY (item_sno) REFERENCES dbo.nt_inventory_items (item_sno)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_sr_items_request_sno' AND object_id = OBJECT_ID('dbo.nt_stock_request_items'))
    CREATE INDEX IX_nt_sr_items_request_sno ON dbo.nt_stock_request_items (request_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_stock_requests_status' AND object_id = OBJECT_ID('dbo.nt_stock_requests'))
    CREATE INDEX IX_nt_stock_requests_status ON dbo.nt_stock_requests (status);
GO

-- ============================================================
-- sp_nt_CreateStockRequest
-- @jsonInput: { requested_by, requested_name, department, purpose,
--               com_sno, div_sno, brn_sno, dept_sno,
--               items: [ { item_sno, quantity, remarks } ] }
-- Validates each item exists and is Active; snapshots code/name/uom onto
-- the line. Returns the created header row.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateStockRequest', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateStockRequest;
GO

CREATE PROCEDURE dbo.sp_nt_CreateStockRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @requested_by   VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.requested_by');
    DECLARE @requested_name VARCHAR(255) = JSON_VALUE(@jsonInput, '$.requested_name');
    DECLARE @department     VARCHAR(100) = JSON_VALUE(@jsonInput, '$.department');
    DECLARE @purpose        VARCHAR(500) = JSON_VALUE(@jsonInput, '$.purpose');
    DECLARE @com_sno        INT          = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno        INT          = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno        INT          = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno       INT          = JSON_VALUE(@jsonInput, '$.dept_sno');

    IF @requested_by IS NULL
    BEGIN
        RAISERROR('requested_by is required.', 16, 1);
        RETURN;
    END

    DECLARE @items TABLE (
        item_sno      INT,
        quantity      DECIMAL(18,2),
        remarks       VARCHAR(255)
    );

    INSERT INTO @items (item_sno, quantity, remarks)
    SELECT item_sno, quantity, remarks
    FROM OPENJSON(@jsonInput, '$.items')
    WITH (
        item_sno INT            '$.item_sno',
        quantity DECIMAL(18,2)  '$.quantity',
        remarks  VARCHAR(255)   '$.remarks'
    );

    IF NOT EXISTS (SELECT 1 FROM @items)
    BEGIN
        RAISERROR('At least one item is required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @items WHERE item_sno IS NULL OR quantity IS NULL OR quantity <= 0)
    BEGIN
        RAISERROR('Every item needs an item_sno and a quantity greater than zero.', 16, 1);
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM @items t
        LEFT JOIN dbo.nt_inventory_items i ON i.item_sno = t.item_sno
        WHERE i.item_sno IS NULL OR i.status <> 'Active'
    )
    BEGIN
        RAISERROR('One or more items do not exist or are not Active.', 16, 1);
        RETURN;
    END

    DECLARE @request_sno INT;
    DECLARE @request_no  VARCHAR(30);
    DECLARE @year        VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

    BEGIN TRANSACTION;
    BEGIN TRY
        -- Next sequence for the year (serialised by the transaction + UPDLOCK)
        DECLARE @seq INT;
        SELECT @seq = ISNULL(MAX(CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
        FROM dbo.nt_stock_requests WITH (UPDLOCK, HOLDLOCK)
        WHERE request_no LIKE 'SR-' + @year + '-%';

        SET @request_no = 'SR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.nt_stock_requests (
            request_no, requested_by, requested_name, department, purpose,
            status, com_sno, div_sno, brn_sno, dept_sno, created_at
        )
        VALUES (
            @request_no, @requested_by, @requested_name, @department, @purpose,
            'Pending', @com_sno, @div_sno, @brn_sno, @dept_sno, GETDATE()
        );

        SET @request_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.nt_stock_request_items (
            request_sno, item_sno, item_code, item_name, uom,
            requested_qty, issued_qty, line_status, remarks
        )
        SELECT
            @request_sno, t.item_sno, i.item_code, i.item_name, i.uom,
            t.quantity, 0, 'Pending', t.remarks
        FROM @items t
        JOIN dbo.nt_inventory_items i ON i.item_sno = t.item_sno;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
        r.purpose, r.status, r.com_sno, r.div_sno, r.brn_sno, r.dept_sno,
        (SELECT COUNT(*) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS item_count,
        CONVERT(VARCHAR(30), r.created_at, 120) AS created_at
    FROM dbo.nt_stock_requests r
    WHERE r.request_sno = @request_sno;
END;
GO

-- ============================================================
-- sp_nt_GetStockRequests
-- @jsonInput optional: { status, requested_by, com_sno, div_sno, brn_sno, dept_sno }
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
-- sp_nt_GetStockRequestItems
-- @jsonInput: { request_sno }
-- Lines joined with the item's live stock so the issue screen can cap
-- the issuable quantity.
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
        l.line_status, l.remarks,
        i.current_stock, i.warehouse, i.location
    FROM dbo.nt_stock_request_items l
    JOIN dbo.nt_inventory_items i ON i.item_sno = l.item_sno
    WHERE l.request_sno = @request_sno
    ORDER BY l.sr_item_sno;
END;
GO

-- ============================================================
-- sp_nt_IssueStockRequest — the stock-incharge action
-- @jsonInput: { request_sno, issued_by,
--               items: [ { sr_item_sno, issue_qty } ] }
-- For each line with issue_qty > 0:
--   - validates issue_qty <= pending on the line AND <= current_stock
--   - nt_inventory_items.current_stock -= issue_qty
--   - inserts an OUT row in nt_stock_movements (reference_no = request_no)
--   - line issued_qty += issue_qty, line_status Issued / Partially Issued
-- Header becomes Issued when every line is fully issued, else Partially
-- Issued. Whole call is one transaction — any bad line rolls back all.
-- Returns: recordset 1 = updated header, recordset 2 = created movements.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_IssueStockRequest', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_IssueStockRequest;
GO

CREATE PROCEDURE dbo.sp_nt_IssueStockRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno INT         = JSON_VALUE(@jsonInput, '$.request_sno');
    DECLARE @issued_by   VARCHAR(50) = JSON_VALUE(@jsonInput, '$.issued_by');

    IF @request_sno IS NULL OR @issued_by IS NULL
    BEGIN
        RAISERROR('request_sno and issued_by are required.', 16, 1);
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
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
            )
            SELECT
                i.item_sno, i.item_code, i.item_name, 'OUT', @issue_qty,
                @new_stock, i.uom, @request_no, i.warehouse,
                'Stock Request Issue (' + @requested_by + ')',
                i.com_sno, i.div_sno, i.brn_sno, i.dept_sno, @issued_by, GETDATE()
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
        SET status     = @new_status,
            issued_by  = @issued_by,
            issued_at  = GETDATE(),
            updated_at = GETDATE()
        WHERE request_sno = @request_sno;

        COMMIT TRANSACTION;

        -- Recordset 1: updated header
        SELECT
            r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
            r.purpose, r.status, r.issued_by,
            (SELECT ISNULL(SUM(issued_qty), 0) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_issued_qty,
            CONVERT(VARCHAR(30), r.issued_at, 120) AS issued_at
        FROM dbo.nt_stock_requests r
        WHERE r.request_sno = @request_sno;

        -- Recordset 2: the movements this issue created
        SELECT
            m.movement_sno, m.item_sno, m.item_code, m.item_name, m.movement_type,
            m.quantity, m.balance_after, m.uom, m.reference_no, m.warehouse, m.reason,
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
-- sp_nt_UpdateStockRequestStatus — reject (incharge) / cancel (requester)
-- @jsonInput: { request_sno, status ('Rejected' | 'Cancelled'),
--               reason, updated_by }
-- Only Pending requests can be rejected or cancelled; cancelling
-- requires updated_by to be the requester.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_UpdateStockRequestStatus', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateStockRequestStatus;
GO

CREATE PROCEDURE dbo.sp_nt_UpdateStockRequestStatus
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno INT          = JSON_VALUE(@jsonInput, '$.request_sno');
    DECLARE @status      VARCHAR(30)  = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @reason      VARCHAR(500) = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @updated_by  VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @request_sno IS NULL OR @status NOT IN ('Rejected', 'Cancelled')
    BEGIN
        RAISERROR('request_sno and a status of Rejected or Cancelled are required.', 16, 1);
        RETURN;
    END

    DECLARE @cur_status VARCHAR(30), @requested_by VARCHAR(50);
    SELECT @cur_status = status, @requested_by = requested_by
    FROM dbo.nt_stock_requests WHERE request_sno = @request_sno;

    IF @cur_status IS NULL
    BEGIN
        RAISERROR('Stock request not found.', 16, 1);
        RETURN;
    END

    IF @cur_status <> 'Pending'
    BEGIN
        RAISERROR('Only Pending requests can be rejected or cancelled (current status: %s).', 16, 1, @cur_status);
        RETURN;
    END

    IF @status = 'Cancelled' AND (@updated_by IS NULL OR @updated_by <> @requested_by)
    BEGIN
        RAISERROR('Only the requester can cancel a stock request.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_stock_requests
    SET status        = @status,
        reject_reason = @reason,
        issued_by     = CASE WHEN @status = 'Rejected' THEN @updated_by ELSE issued_by END,
        updated_at    = GETDATE()
    WHERE request_sno = @request_sno;

    UPDATE dbo.nt_stock_request_items
    SET line_status = @status
    WHERE request_sno = @request_sno AND line_status = 'Pending';

    SELECT request_sno, request_no, requested_by, status, reject_reason,
           CONVERT(VARCHAR(30), updated_at, 120) AS updated_at
    FROM dbo.nt_stock_requests
    WHERE request_sno = @request_sno;
END;
GO
