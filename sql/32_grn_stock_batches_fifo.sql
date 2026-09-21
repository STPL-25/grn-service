-- ============================================================
-- GRN batch tracking + FIFO stock issuance ("issue first in stock")
-- Database: Non_trade_Dev (MSSQL)
--
-- This codebase previously had no batch/lot tracking at all — nt_stock_
-- movements is a flat running-balance ledger (see grn-service/sql/30_
-- perishable_expiry_stock.sql's comments, and [project-perishable-stock-
-- type-and-expiry] memory, which explicitly deferred this as too large a
-- change at the time). This migration adds it:
--
--   1. nt_stock_batches — one row per GRN line item received, carrying its
--      own remaining_qty. Created by sp_nt_AdjustStock's IN branch whenever
--      a GRN receipt (grn_basic_sno/grn_item_sno present) triggers it — not
--      for a plain manual stock-in adjustment, which has no batch concept.
--   2. nt_stock_movements gains a nullable batch_sno FK, so every OUT
--      movement records exactly which batch it drew from.
--   3. sp_nt_AdjustStock's OUT branch and sp_nt_IssueStockRequest (the only
--      two places stock is ever reduced) now consume nt_stock_batches in
--      FIFO order (oldest received_date, then oldest batch_sno) instead of
--      only decrementing the flat current_stock counter. A shortfall beyond
--      what tracked batches cover (stock that existed before this feature,
--      or was added via a non-GRN IN) is logged as one final movement row
--      with batch_sno = NULL, so the ledger still reconciles exactly to
--      current_stock — issuance never fails just because older stock
--      predates batch tracking.
--   4. sp_nt_GetGRNItemsForInventorySync additionally returns received_date
--      and received_unit_price so the batch can carry the GRN's actual
--      (possibly backdated) receipt date and a cost basis, not GETDATE().
--   5. sp_nt_GetStockBatches — new read SP backing a "view batches" screen,
--      FIFO-ordered with remaining_qty, for the traceability this feature
--      is actually for.
--
-- Every proc altered here was pulled fresh via OBJECT_DEFINITION() first,
-- per this repo's established convention (see reference-non-trade-
-- codebase-conventions memory) — the on-disk 02_inventory.sql/29_.../30_...
-- copies were not trusted as current.
-- ============================================================

CREATE TABLE dbo.nt_stock_batches (
    batch_sno       INT IDENTITY(1,1) PRIMARY KEY,
    batch_no        VARCHAR(60)   NOT NULL,
    item_sno        INT           NOT NULL,
    grn_basic_sno   INT           NULL,
    grn_item_sno    INT           NULL,
    grn_no          VARCHAR(30)   NULL,
    received_qty    DECIMAL(18,2) NOT NULL,
    remaining_qty   DECIMAL(18,2) NOT NULL,
    unit_cost       DECIMAL(18,2) NULL,
    received_date   DATE          NOT NULL,
    uom             VARCHAR(20)   NULL,
    com_sno         INT           NULL,
    div_sno         INT           NULL,
    brn_sno         INT           NULL,
    dept_sno        INT           NULL,
    status          VARCHAR(20)   NOT NULL DEFAULT 'Active',
    created_by      VARCHAR(50)   NULL,
    created_at      DATETIME      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT FK_nt_stock_batches_item FOREIGN KEY (item_sno) REFERENCES dbo.nt_inventory_items(item_sno)
);
GO

CREATE INDEX IX_nt_stock_batches_fifo ON dbo.nt_stock_batches (item_sno, received_date, batch_sno);
GO

ALTER TABLE dbo.nt_stock_movements ADD batch_sno INT NULL;
GO

ALTER TABLE dbo.nt_stock_movements
    ADD CONSTRAINT FK_nt_stock_movements_batch FOREIGN KEY (batch_sno) REFERENCES dbo.nt_stock_batches(batch_sno);
GO

-- ── sp_nt_GetGRNItemsForInventorySync — add received_date + received_unit_price ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNItemsForInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');

    SELECT
        gi.grn_item_sno, gi.grn_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name,
        gi.unit_name, gi.received_qty, gi.rejected_qty, gi.warehouse_location_sno,
        gi.inventory_sync_status, gi.received_unit_price,
        gb.com_sno, gb.div_sno, gb.brn_sno, gb.dept_sno, gb.created_by,
        gb.received_date,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.grn_basic_sno = @grn_basic_sno;
END;
GO

-- ── sp_nt_AdjustStock — IN creates a batch (GRN-sourced only); OUT/shortfall ──
-- ── consumes FIFO across nt_stock_batches ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_AdjustStock
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @movement_type VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.movement_type');
    DECLARE @quantity      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.quantity');
    DECLARE @reference_no  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.reference_no');
    DECLARE @to_warehouse  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.to_warehouse');
    DECLARE @reason        VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    -- Optional — present only for a GRN-receipt IN, to create its batch.
    DECLARE @grn_basic_sno INT           = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @grn_item_sno  INT           = JSON_VALUE(@jsonInput, '$.grn_item_sno');
    DECLARE @grn_no        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.grn_no');
    DECLARE @received_date DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @unit_cost     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.unit_cost');

    IF @item_sno IS NULL OR @movement_type IS NULL
    BEGIN
        RAISERROR('item_sno and movement_type are required.', 16, 1);
        RETURN;
    END

    DECLARE @current_stock DECIMAL(18,2),
            @warehouse     VARCHAR(100),
            @item_code     VARCHAR(50),
            @item_name     VARCHAR(255),
            @uom           VARCHAR(20);

    DECLARE @com_sno  INT, @div_sno  INT, @brn_sno  INT, @dept_sno INT;

    SELECT
        @current_stock = current_stock,
        @warehouse     = warehouse,
        @item_code     = item_code,
        @item_name     = item_name,
        @uom           = uom,
        @com_sno       = com_sno,
        @div_sno       = div_sno,
        @brn_sno       = brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;

    IF @current_stock IS NULL
    BEGIN
        RAISERROR('Inventory item not found.', 16, 1);
        RETURN;
    END

    IF @movement_type NOT IN ('IN', 'OUT', 'ADJUSTMENT', 'TRANSFER')
    BEGIN
        RAISERROR('Invalid movement_type ''%s''.', 16, 1, @movement_type);
        RETURN;
    END

    IF @movement_type = 'OUT' AND ISNULL(@quantity, 0) > @current_stock
    BEGIN
        RAISERROR('Insufficient stock for this item.', 16, 1);
        RETURN;
    END

    IF @movement_type = 'TRANSFER' AND @to_warehouse IS NULL
    BEGIN
        RAISERROR('to_warehouse is required for TRANSFER.', 16, 1);
        RETURN;
    END

    DECLARE @new_stock     DECIMAL(18,2) = @current_stock;
    DECLARE @new_warehouse VARCHAR(100)  = @warehouse;
    DECLARE @movements TABLE (movement_sno INT);
    DECLARE @movement_sno INT;

    IF @movement_type = 'IN'
        SET @new_stock = @current_stock + ISNULL(@quantity, 0);
    ELSE IF @movement_type = 'OUT'
        SET @new_stock = @current_stock - ISNULL(@quantity, 0);
    ELSE IF @movement_type = 'ADJUSTMENT'
        SET @new_stock = ISNULL(@quantity, @current_stock);
    ELSE IF @movement_type = 'TRANSFER'
        SET @new_warehouse = @to_warehouse;

    UPDATE dbo.nt_inventory_items
    SET current_stock = @new_stock,
        warehouse      = @new_warehouse,
        updated_by     = @created_by,
        updated_at     = GETDATE()
    WHERE item_sno = @item_sno;

    IF @movement_type = 'OUT'
    BEGIN
        -- FIFO: draw from the oldest non-exhausted batches first.
        DECLARE @remaining_to_issue DECIMAL(18,2) = ISNULL(@quantity, 0);
        DECLARE @b_batch_sno INT, @b_available DECIMAL(18,2), @draw_qty DECIMAL(18,2);

        DECLARE batch_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT batch_sno, remaining_qty
            FROM dbo.nt_stock_batches WITH (UPDLOCK, HOLDLOCK)
            WHERE item_sno = @item_sno AND remaining_qty > 0
            ORDER BY received_date ASC, batch_sno ASC;

        OPEN batch_cur;
        FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
        WHILE @@FETCH_STATUS = 0 AND @remaining_to_issue > 0
        BEGIN
            SET @draw_qty = CASE WHEN @b_available <= @remaining_to_issue THEN @b_available ELSE @remaining_to_issue END;

            UPDATE dbo.nt_stock_batches
            SET remaining_qty = remaining_qty - @draw_qty,
                status = CASE WHEN remaining_qty - @draw_qty <= 0 THEN 'Exhausted' ELSE 'Active' END
            WHERE batch_sno = @b_batch_sno;

            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason,
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at, batch_sno
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'OUT', @draw_qty,
                @new_stock, @uom, @reference_no, @new_warehouse, @reason,
                @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE(), @b_batch_sno
            );
            INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());

            SET @remaining_to_issue -= @draw_qty;
            FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
        END
        CLOSE batch_cur;
        DEALLOCATE batch_cur;

        -- Shortfall beyond tracked batches (pre-batch legacy stock, or a
        -- prior non-GRN IN) — one unbatched row so the ledger still adds up.
        IF @remaining_to_issue > 0
        BEGIN
            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason,
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at, batch_sno
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'OUT', @remaining_to_issue,
                @new_stock, @uom, @reference_no, @new_warehouse, @reason,
                @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE(), NULL
            );
            INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());
        END
    END
    ELSE
    BEGIN
        INSERT INTO dbo.nt_stock_movements (
            item_sno, item_code, item_name, movement_type, quantity,
            balance_after, uom, reference_no, warehouse, reason,
            com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
        )
        VALUES (
            @item_sno, @item_code, @item_name, @movement_type, ISNULL(@quantity, 0),
            @new_stock, @uom, @reference_no, @new_warehouse, @reason,
            @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE()
        );
        SET @movement_sno = SCOPE_IDENTITY();
        INSERT INTO @movements (movement_sno) VALUES (@movement_sno);

        -- One FIFO batch per GRN line item receipt only — a plain manual
        -- stock-in adjustment (no grn_item_sno) creates no batch.
        IF @movement_type = 'IN' AND @grn_item_sno IS NOT NULL AND ISNULL(@quantity, 0) > 0
        BEGIN
            DECLARE @batch_no VARCHAR(60) = ISNULL(@grn_no, 'ADJ') + '-B' + CAST(@grn_item_sno AS VARCHAR(10));
            DECLARE @new_batch_sno INT;

            INSERT INTO dbo.nt_stock_batches (
                batch_no, item_sno, grn_basic_sno, grn_item_sno, grn_no,
                received_qty, remaining_qty, unit_cost, received_date, uom,
                com_sno, div_sno, brn_sno, dept_sno, status, created_by, created_at
            )
            VALUES (
                @batch_no, @item_sno, @grn_basic_sno, @grn_item_sno, @grn_no,
                @quantity, @quantity, @unit_cost, ISNULL(@received_date, CAST(GETDATE() AS DATE)), @uom,
                @com_sno, @div_sno, @brn_sno, @dept_sno, 'Active', @created_by, GETDATE()
            );
            SET @new_batch_sno = SCOPE_IDENTITY();

            UPDATE dbo.nt_stock_movements SET batch_sno = @new_batch_sno WHERE movement_sno = @movement_sno;
        END
    END

    SELECT
        m.movement_sno, m.item_sno, m.item_code, m.item_name, m.movement_type, m.quantity,
        m.balance_after, m.uom, m.reference_no, m.warehouse, m.reason,
        m.com_sno, m.div_sno, m.brn_sno, m.batch_sno, m.created_by,
        CONVERT(VARCHAR(30), m.created_at, 120) AS created_at
    FROM dbo.nt_stock_movements m
    JOIN @movements x ON x.movement_sno = m.movement_sno
    ORDER BY m.movement_sno;
END;
GO

-- ── sp_nt_IssueStockRequest — issuance now draws FIFO across nt_stock_batches ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_IssueStockRequest
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

        DECLARE @sr_item_sno INT, @issue_qty DECIMAL(18,2);
        DECLARE issue_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT sr_item_sno, issue_qty FROM @issue;

        OPEN issue_cur;
        FETCH NEXT FROM issue_cur INTO @sr_item_sno, @issue_qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @item_sno INT, @new_stock DECIMAL(18,2);
            DECLARE @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20), @warehouse VARCHAR(100);
            DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;

            SELECT @item_sno = item_sno
            FROM dbo.nt_stock_request_items
            WHERE sr_item_sno = @sr_item_sno;

            UPDATE dbo.nt_inventory_items
            SET current_stock = current_stock - @issue_qty,
                updated_by    = @issued_by,
                updated_at    = GETDATE(),
                @new_stock    = current_stock - @issue_qty,
                @item_code    = item_code,
                @item_name    = item_name,
                @uom          = uom,
                @warehouse    = warehouse,
                @com_sno      = com_sno,
                @div_sno      = div_sno,
                @brn_sno      = brn_sno,
                @dept_sno     = dept_sno
            WHERE item_sno = @item_sno;

            -- FIFO: draw this line's issue_qty from the oldest non-exhausted
            -- batches for this item, one movement row per batch drawn.
            DECLARE @remaining_to_issue DECIMAL(18,2) = @issue_qty;
            DECLARE @b_batch_sno INT, @b_available DECIMAL(18,2), @draw_qty DECIMAL(18,2);

            DECLARE batch_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT batch_sno, remaining_qty
                FROM dbo.nt_stock_batches WITH (UPDLOCK, HOLDLOCK)
                WHERE item_sno = @item_sno AND remaining_qty > 0
                ORDER BY received_date ASC, batch_sno ASC;

            OPEN batch_cur;
            FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
            WHILE @@FETCH_STATUS = 0 AND @remaining_to_issue > 0
            BEGIN
                SET @draw_qty = CASE WHEN @b_available <= @remaining_to_issue THEN @b_available ELSE @remaining_to_issue END;

                UPDATE dbo.nt_stock_batches
                SET remaining_qty = remaining_qty - @draw_qty,
                    status = CASE WHEN remaining_qty - @draw_qty <= 0 THEN 'Exhausted' ELSE 'Active' END
                WHERE batch_sno = @b_batch_sno;

                INSERT INTO dbo.nt_stock_movements (
                    item_sno, item_code, item_name, movement_type, quantity,
                    balance_after, uom, reference_no, warehouse, reason,
                    com_sno, div_sno, brn_sno, dept_sno, created_by, created_at,
                    received_by_ecno, received_by_name, batch_sno
                )
                VALUES (
                    @item_sno, @item_code, @item_name, 'OUT', @draw_qty,
                    @new_stock, @uom, @request_no, @warehouse,
                    'Stock Request Issue (' + @requested_by + ')',
                    @com_sno, @div_sno, @brn_sno, @dept_sno, @issued_by, GETDATE(),
                    @received_by_ecno, @received_by_name, @b_batch_sno
                );
                INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());

                SET @remaining_to_issue -= @draw_qty;
                FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
            END
            CLOSE batch_cur;
            DEALLOCATE batch_cur;

            IF @remaining_to_issue > 0
            BEGIN
                INSERT INTO dbo.nt_stock_movements (
                    item_sno, item_code, item_name, movement_type, quantity,
                    balance_after, uom, reference_no, warehouse, reason,
                    com_sno, div_sno, brn_sno, dept_sno, created_by, created_at,
                    received_by_ecno, received_by_name, batch_sno
                )
                VALUES (
                    @item_sno, @item_code, @item_name, 'OUT', @remaining_to_issue,
                    @new_stock, @uom, @request_no, @warehouse,
                    'Stock Request Issue (' + @requested_by + ')',
                    @com_sno, @div_sno, @brn_sno, @dept_sno, @issued_by, GETDATE(),
                    @received_by_ecno, @received_by_name, NULL
                );
                INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());
            END

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
            m.received_by_ecno, m.received_by_name, m.batch_sno,
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

-- ── sp_nt_GetStockMovements — surface which batch each movement drew from ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockMovements
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno INT = JSON_VALUE(@jsonInput, '$.item_sno');

    SELECT
        movement_sno, item_sno, item_code, item_name, movement_type, quantity,
        balance_after, uom, reference_no, warehouse, reason, batch_sno, created_by,
        CONVERT(VARCHAR(30), created_at, 120) AS created_at
    FROM dbo.nt_stock_movements
    WHERE item_sno = @item_sno
    ORDER BY movement_sno DESC;
END;
GO

-- ── sp_nt_GetStockBatches — FIFO-ordered batch list for one item ─────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockBatches
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @item_sno INT = JSON_VALUE(@jsonInput, '$.item_sno');

    SELECT
        b.batch_sno, b.batch_no, b.item_sno, b.grn_basic_sno, b.grn_item_sno, b.grn_no,
        b.received_qty, b.remaining_qty, b.unit_cost,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.uom, b.status, b.created_by,
        CONVERT(VARCHAR(30), b.created_at, 120) AS created_at
    FROM dbo.nt_stock_batches b
    WHERE b.item_sno = @item_sno
    ORDER BY b.received_date ASC, b.batch_sno ASC;
END;
GO
