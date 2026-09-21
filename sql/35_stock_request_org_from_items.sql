-- ============================================================
-- Fix: Store Requisitions submitted from the Store Requisition page never
-- appeared on the Store Issue page (reported 2026-09-21).
-- Database: Non_Trade and Non_trade_Dev (MSSQL)
--
-- Root cause: the requisition form posts only { purpose, items }, so
-- sp_nt_CreateStockRequest inserted com_sno/div_sno/brn_sno/dept_sno = NULL.
-- sp_nt_GetStockRequests (since 31_hierarchy_scope_wiring.sql) only returns a
-- row when the caller's hierarchy contains a row with h.com_sno = r.com_sno,
-- and NULL never equals anything, so every Manual requisition was filtered out
-- for every store user. Auto-GRN requisitions were unaffected — they copy the
-- org from the GRN.
--
-- Fix: the requisition's org is the org of the stock being requested (stock is
-- bucketed per com/div/brn/dept on nt_inventory_items, and that bucket's store
-- is who issues it). A requisition whose items span more than one
-- company/division/branch is rejected — it could not be scoped to a single
-- store and would silently vanish from one of them. dept_sno is kept only when
-- every item agrees on it (Store Issue does not filter on dept).
--
-- Existing NULL-org rows are backfilled by 36_backfill_stock_request_org.sql.
-- Re-running 04_stock_request.sql would revert this procedure; run this file
-- after it.
-- ============================================================

-- The deployed procedure was created with QUOTED_IDENTIFIER OFF; keep that.
SET QUOTED_IDENTIFIER OFF;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateStockRequest
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

    -- Org scope comes from the stock being requested, not from the caller.
    IF (
        SELECT COUNT(*) FROM (
            SELECT DISTINCT i.com_sno, i.div_sno, i.brn_sno
            FROM @items t
            JOIN dbo.nt_inventory_items i ON i.item_sno = t.item_sno
        ) b
    ) > 1
    BEGIN
        RAISERROR('All items in one requisition must belong to the same company, division and branch. Raise a separate requisition for each.', 16, 1);
        RETURN;
    END

    SELECT
        @com_sno  = ISNULL(MAX(i.com_sno), @com_sno),
        @div_sno  = ISNULL(MAX(i.div_sno), @div_sno),
        @brn_sno  = ISNULL(MAX(i.brn_sno), @brn_sno),
        @dept_sno = ISNULL(
                        CASE WHEN COUNT(DISTINCT ISNULL(i.dept_sno, -1)) = 1 THEN MAX(i.dept_sno) END,
                        @dept_sno)
    FROM @items t
    JOIN dbo.nt_inventory_items i ON i.item_sno = t.item_sno;

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
