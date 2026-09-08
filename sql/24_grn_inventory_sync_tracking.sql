-- =============================================================================
-- 24_grn_inventory_sync_tracking.sql
--
-- Why: receiveFromGRN (grn-service/src/inventory/inventory.service.js) posts
-- the stock-in movement for each GRN line right after the GRN itself commits.
-- That call can fail (transient DB hiccup, connection pool exhaustion, etc.)
-- and grn.service.js only console.error's it — the GRN still succeeds, the
-- user sees no error, and the item silently never reaches inventory. Found
-- 2026-09-05 investigating a Dell laptop GRN that never showed up in
-- inventory; auditing every historical GRN line turned up a second live gap
-- (a Pressure Cooker GRN from 2026-09-01) with the exact same signature.
-- Both were reconciled by hand in the DB; this migration adds the tracking
-- so the next occurrence is visible and fixable without a manual DB dive.
--
-- inventory_sync_status values:
--   Pending  -- default; set to something else immediately after the GRN's
--              inventory-posting loop runs. A row stuck on 'Pending' means
--              the Node process died before it could even record an outcome.
--   Synced   -- receiveFromGRN succeeded and posted the stock-in movement.
--   Skipped  -- receiveFromGRN intentionally did nothing (no prod_sno, i.e.
--              a free-text line, or net qty <= 0 after rejections) — not a
--              failure, nothing to reconcile.
--   Failed   -- receiveFromGRN threw. inventory_sync_error holds the message.
-- =============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.grn_item_details') AND name = 'inventory_sync_status'
)
BEGIN
    ALTER TABLE dbo.grn_item_details ADD
        inventory_sync_status VARCHAR(20) NOT NULL
            CONSTRAINT DF_grn_item_details_inventory_sync_status DEFAULT 'Pending',
        inventory_sync_error  VARCHAR(500) NULL,
        inventory_synced_at   DATETIME NULL;
END
GO

-- ── Backfill existing rows from actual current state ──────────────────────
-- Lines with no product link or a non-positive net qty were never meant to
-- post anything — mark them Skipped so they don't show up as false failures.
UPDATE gi
SET inventory_sync_status = 'Skipped',
    inventory_synced_at = GETDATE()
FROM dbo.grn_item_details gi
WHERE gi.inventory_sync_status = 'Pending'
  AND (gi.prod_sno IS NULL OR (ISNULL(gi.received_qty, 0) - ISNULL(gi.rejected_qty, 0)) <= 0);
GO

-- Lines where a matching IN movement already exists (reference_no + item
-- name uniquely identify a line within a GRN, since a GRN's reference_no is
-- shared across all its lines) — these genuinely posted, mark Synced.
UPDATE gi
SET inventory_sync_status = 'Synced',
    inventory_synced_at = GETDATE()
FROM dbo.grn_item_details gi
JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
WHERE gi.inventory_sync_status = 'Pending'
  AND EXISTS (
      SELECT 1 FROM dbo.nt_stock_movements sm
      WHERE sm.reference_no = 'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
              + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6)
        AND sm.item_name = gi.prod_name
  );
GO

-- Everything still Pending at this point should have posted but didn't —
-- real, pre-existing gaps between the GRN and inventory.
UPDATE dbo.grn_item_details
SET inventory_sync_status = 'Failed',
    inventory_sync_error = 'Backfilled 2026-09-05: gap discovered auditing GRN history, cause not reproduced from the row data itself'
WHERE inventory_sync_status = 'Pending';
GO

-- ── Procs ───────────────────────────────────────────────────────────────────

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNItemsForInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');

    SELECT
        gi.grn_item_sno, gi.grn_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name,
        gi.unit_name, gi.received_qty, gi.rejected_qty, gi.warehouse_location_sno,
        gi.inventory_sync_status,
        gb.com_sno, gb.div_sno, gb.brn_sno, gb.dept_sno, gb.created_by,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.grn_basic_sno = @grn_basic_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNItemForInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_item_sno INT = JSON_VALUE(@jsonInput, '$.grn_item_sno');

    SELECT
        gi.grn_item_sno, gi.grn_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name,
        gi.unit_name, gi.received_qty, gi.rejected_qty, gi.warehouse_location_sno,
        gi.inventory_sync_status,
        gb.com_sno, gb.div_sno, gb.brn_sno, gb.dept_sno, gb.created_by,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.grn_item_sno = @grn_item_sno;
END;
GO

-- Admin-facing worklist: every GRN line that threw when it tried to post to
-- inventory and hasn't been resynced since.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUnsyncedGRNInventoryItems
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        gi.grn_item_sno, gi.prod_sno, gi.prod_name, gi.received_qty, gi.rejected_qty,
        (ISNULL(gi.received_qty, 0) - ISNULL(gi.rejected_qty, 0)) AS net_qty,
        gi.inventory_sync_status, gi.inventory_sync_error, gi.created_date,
        gb.grn_basic_sno,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no,
        gb.com_sno, gb.div_sno, gb.brn_sno
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.inventory_sync_status = 'Failed'
    ORDER BY gi.grn_item_sno DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkGRNItemInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_item_sno   INT          = JSON_VALUE(@jsonInput, '$.grn_item_sno');
    DECLARE @status         VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @error_message  VARCHAR(500) = JSON_VALUE(@jsonInput, '$.error_message');

    IF @grn_item_sno IS NULL OR @status NOT IN ('Synced', 'Skipped', 'Failed')
    BEGIN
        RAISERROR('grn_item_sno and a valid status (Synced/Skipped/Failed) are required.', 16, 1);
        RETURN;
    END

    UPDATE dbo.grn_item_details
    SET inventory_sync_status = @status,
        inventory_sync_error = @error_message,
        inventory_synced_at = CASE WHEN @status IN ('Synced', 'Skipped') THEN GETDATE() ELSE NULL END
    WHERE grn_item_sno = @grn_item_sno;
END;
GO
