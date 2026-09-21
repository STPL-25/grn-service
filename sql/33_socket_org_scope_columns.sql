-- ============================================================
-- Additive: surface com_sno/div_sno/brn_sno on write-SP return rows that
-- didn't have them, so the Node layer can compute which org-scoped Socket.IO
-- room(s) to broadcast an event to (see backend-stpl/index.js's new
-- orgRoomsForHierarchy/[domain]:live:com:X[:div:Y[:brn:Z]] room scheme, and
-- grn-service/src/utils/socketBroadcast.js). No behavior change to any
-- existing caller — every change here only ADDS columns to a SELECT.
--
-- Note: sp_nt_CreateInventoryItem's manual "Create Inventory Item" screen
-- has never captured com_sno/div_sno/brn_sno on the INSERT at all (a
-- pre-existing gap, not introduced here) — items created that way will
-- return NULL org columns, which the broadcast helper treats as "fall back
-- to the old unscoped room" rather than silently dropping the event.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_code     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.item_code');
    DECLARE @item_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @current_stock DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.current_stock');
    DECLARE @min_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @hsn_code      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description   VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @prod_sno      INT           = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @item_code IS NULL OR @item_name IS NULL
    BEGIN
        RAISERROR('item_code and item_name are required.', 16, 1);
        RETURN;
    END

    DECLARE @item_sno INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, sub_category, uom, current_stock,
            min_stock, max_stock, reorder_qty, warehouse, location, cost_price,
            selling_price, status, hsn_code, description, prod_sno, created_by, created_at
        )
        VALUES (
            @item_code, @item_name, @category, @sub_category, @uom, @current_stock,
            ISNULL(@min_stock, 0), ISNULL(@max_stock, 0), ISNULL(@reorder_qty, 0),
            @warehouse, @location, ISNULL(@cost_price, 0),
            ISNULL(@selling_price, 0), @status, @hsn_code, @description, @prod_sno, @created_by, GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();

        IF @current_stock > 0
        BEGIN
            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason, created_by, created_at
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'IN', @current_stock,
                @current_stock, @uom, NULL, @warehouse, 'Opening Stock', @created_by, GETDATE()
            );
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status,
           com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @item_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @min_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @hsn_code      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description   VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @updated_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @item_sno IS NULL
    BEGIN
        RAISERROR('item_sno is required.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_inventory_items
    SET item_name     = ISNULL(@item_name, item_name),
        category      = ISNULL(@category, category),
        sub_category  = @sub_category,
        uom           = ISNULL(@uom, uom),
        min_stock     = ISNULL(@min_stock, min_stock),
        max_stock     = ISNULL(@max_stock, max_stock),
        reorder_qty   = ISNULL(@reorder_qty, reorder_qty),
        warehouse     = ISNULL(@warehouse, warehouse),
        location      = @location,
        cost_price    = ISNULL(@cost_price, cost_price),
        selling_price = ISNULL(@selling_price, selling_price),
        status        = ISNULL(@status, status),
        hsn_code      = @hsn_code,
        description   = @description,
        updated_by    = @updated_by,
        updated_at    = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status,
           com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno   INT         = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @updated_by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.updated_by');

    UPDATE dbo.nt_inventory_items
    SET status     = 'Discontinued',
        updated_by = @updated_by,
        updated_at = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, status, com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateStockRequestStatus
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

    SELECT request_sno, request_no, requested_by, status, reject_reason, com_sno, div_sno, brn_sno,
           CONVERT(VARCHAR(30), updated_at, 120) AS updated_at
    FROM dbo.nt_stock_requests
    WHERE request_sno = @request_sno;
END;
GO

-- sp_nt_IssueStockRequest's Recordset 1 (header) — add com/div/brn so the
-- issue broadcast can be org-scoped too (Recordset 2/movements already had
-- them from the FIFO migration in 32_grn_stock_batches_fifo.sql).
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

        -- Recordset 1: updated header (now includes com/div/brn)
        SELECT
            r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
            r.purpose, r.status, r.issued_by, r.received_by_ecno, r.received_by_name,
            r.com_sno, r.div_sno, r.brn_sno,
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

-- sp_nt_CreateGRN's final SELECT — add com/div/brn so the grn:created
-- broadcast can be org-scoped.
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

    SELECT
        @com_sno  = com_sno,
        @div_sno  = div_sno,
        @brn_sno  = brn_sno,
        @dept_sno = dept_sno
    FROM dbo.po_request_info
    WHERE po_basic_sno = @po_basic_sno;

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

        INSERT INTO dbo.grn_item_details (
            grn_basic_sno, po_item_sno, prod_sno, prod_name, specification,
            po_qty, received_qty, diff_qty, rejected_qty, unit_name,
            condition, hsn_code, remarks,
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
            po_item_sno            INT           '$.po_item_sno',
            prod_sno                INT           '$.prod_sno',
            prod_name               VARCHAR(255)  '$.prod_name',
            specification           VARCHAR(500)  '$.specification',
            ordered_qty             DECIMAL(18,2) '$.ordered_qty',
            received_qty            DECIMAL(18,2) '$.received_qty',
            rejected_qty            DECIMAL(18,2) '$.rejected_qty',
            unit_name               VARCHAR(50)   '$.unit_name',
            condition               VARCHAR(20)   '$.condition',
            hsn_code                VARCHAR(10)   '$.hsn_code',
            remarks                 VARCHAR(500)  '$.remarks',
            warehouse_location_sno  INT           '$.warehouse_location_sno'
        ) j
        LEFT JOIN dbo.warehouse_location_master wl
            ON wl.location_sno = j.warehouse_location_sno;

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

        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, grn_basic_sno, gate_entry_sno,
            to_status, status_by, remarks
        )
        VALUES (
            'GRN Created', @po_basic_sno, @grn_basic_sno, @gate_entry_sno,
            'Received', @created_by, @remarks
        );

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
        b.gate_entry_sno,
        b.po_basic_sno,
        b.vendor_sno,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        CONVERT(VARCHAR(30), b.created_date, 120) AS created_at
    FROM dbo.grn_basic_info b
    WHERE b.grn_basic_sno = @grn_basic_sno;
END;
GO
