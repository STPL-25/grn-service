-- ============================================================
-- Vendor-Bill-Driven delivery verification
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new grn-service/src/invoice sp_nt_VerifyInvoiceDelivery, called
--            from the Invoice Allocation screen's "Verify" action on a
--            RETROSPECTIVE invoice before a requisition is raised from it.
--
-- Why this is needed
-- ------------------
-- Type-3 (Vendor-Bill-Driven, e.g. milk/groceries/local supplies) needs
-- "department/store verifies bill against delivery register or
-- acknowledgement log" before a retrospective PR/call-off PO is raised.
-- sp_nt_CreateGRN (grn-service/sql/07_grn_procs_v2.sql) hard-requires both
-- @gate_entry_sno and @po_basic_sno — it cannot represent a delivery
-- received before any PO exists, so it can't serve as this verification
-- step for retrospective bills. Rather than weaken GRN's guarantees (used
-- stably by the whole product flow) or build a parallel receiving workflow,
-- this adds a lightweight verification flag directly on invoice_info —
-- proportionate to "someone checked this bill against what was delivered,"
-- not a full receiving/acknowledgement-log data model.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.invoice_info') AND name = 'verification_status')
    ALTER TABLE dbo.invoice_info ADD verification_status VARCHAR(20) NOT NULL DEFAULT 'Pending'; -- Pending | Verified
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.invoice_info') AND name = 'verified_by')
    ALTER TABLE dbo.invoice_info ADD verified_by VARCHAR(20) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.invoice_info') AND name = 'verified_at')
    ALTER TABLE dbo.invoice_info ADD verified_at DATETIME NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.invoice_info') AND name = 'verification_remarks')
    ALTER TABLE dbo.invoice_info ADD verification_remarks VARCHAR(500) NULL;
GO

-- ============================================================
-- sp_nt_VerifyInvoiceDelivery
-- @jsonInput: { invoice_sno, verified_by, remarks? }
-- Only meaningful for RETROSPECTIVE invoices (a STANDARD invoice already has
-- GRN as its verification) — allowed on either source_type regardless, since
-- a department may still want to record an explicit check either way, but
-- the Invoice screen only surfaces the action for RETROSPECTIVE ones.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_VerifyInvoiceDelivery', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_VerifyInvoiceDelivery;
GO
CREATE PROCEDURE dbo.sp_nt_VerifyInvoiceDelivery
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @invoice_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
    DECLARE @verified_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.verified_by');
    DECLARE @remarks     VARCHAR(500)= JSON_VALUE(@jsonInput, '$.remarks');

    IF @invoice_sno IS NULL OR @verified_by IS NULL
    BEGIN
        RAISERROR('invoice_sno and verified_by are required.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.invoice_info WHERE invoice_sno = @invoice_sno AND is_active = 'Y')
    BEGIN
        RAISERROR('Invoice not found or inactive.', 16, 1);
        RETURN;
    END

    UPDATE dbo.invoice_info
    SET verification_status = 'Verified',
        verified_by         = @verified_by,
        verified_at          = GETDATE(),
        verification_remarks  = @remarks,
        modified_date          = GETDATE()
    WHERE invoice_sno = @invoice_sno;

    SELECT invoice_sno, verification_status, verified_by, verified_at, 'SUCCESS' AS result
    FROM dbo.invoice_info WHERE invoice_sno = @invoice_sno;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.invoice_info') AND name LIKE 'verif%';
-- ============================================================
